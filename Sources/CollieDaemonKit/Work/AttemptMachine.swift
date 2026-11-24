import Foundation
import CollieCore

/// One attempt of the loop as a state machine. `reduce` is pure (no host, store, git or clock): it takes what
/// `WorkLoop.attempt()` observed (an `Event`, never the agent's words) and says what to do next (`Effect`s, in order).
/// `attempt()` is the interpreter: it carries each effect out and hands the resulting event back, until `finished`.
/// In every list `reduce` returns, only the last effect answers with an event (`Effect.answers`).
enum AttemptMachine {
    enum Phase: Sendable, Equatable, CaseIterable { case summoning, turn, waitingCommit, checking, gating, reviewing, deciding, finished }

    /// What `measureFacts` read from the tree once the agent is gone.
    struct Measured: Sendable, Equatable {
        var committed: Bool, dirty: Bool
        /// The commit the agent left: what the check and the gate judge.
        var judged: String
    }

    enum Event: Sendable, Equatable {
        case started
        /// M2.2a: the attempt starts on a commit that is already there (a fallen daemon's agent made it): no agent.
        case adopted
        case summoned(UUID), summonFailed(String)
        /// P2: `turnTimedOut` carries the error's message (the journal's detail).
        case turnEnded(source: AskResult.Source), turnTimedOut(String), turnFailed(String)
        /// P2: the ask timed out before its prompt reached the agent (`AskCoordinator.promptNotDelivered`): the message,
        /// and the machine's load average then (for the owner's note when the free retries are spent).
        /// C1 (P2-a): `fits`: what is left of the budget holds another try of the same attempt (the interpreter's sum).
        case promptNotDelivered(String, load: Double, fits: Bool = true)
        /// M5.3: the agent sits in the model's usage-limit dialog (its text, short: `UsageLimit.excerpt`).
        case usageLimit(String)
        /// A new commit is there (its short hash, for the journal) / there is none.
        case commitSeen(String?), waitExpired
        /// M10.2: the pre-check ran with the agent still there (`status` nil: timed out or could not run; a failure
        /// either way). `tail`: the end of its output, what the agent is told when it failed.
        case precheckDone(status: Int32?, tail: String)
        /// The daemon stops / the work closed / the Shepherd that started the loop is gone: no verdict.
        case cancelled, workClosed, starterGone
        /// nil: the attempt failed before its check (summon or ask), nothing was measured.
        case measured(Measured?)
        /// `status` nil: timed out. `broken`: it could not even start (the whole reason).
        case checkDone(status: Int32?, broken: String?)
        /// The attempt did not change a script the gate runs / it did (why): `WorkLoop.tampered`.
        case gateClear, gateSkipped(String)
        case gateDone(status: Int32?, broken: String?)
        /// After the check or the gate: it `moved` HEAD; `reset`: there was something to put back (journal only).
        case settled(moved: Bool, reset: Bool)
        /// Another terminal of the paddock still working (its name), or none.
        case blocked(String?)
        case decided(AttemptDecision.Outcome)
        /// F2 R3: what the personas said (`ReviewVerdict.aggregate`).
        case reviewDone(ReviewOutcome)
        /// F2 X3: less than `WorkLoop.reviewMinTurn` of the budget is left for the reviewers: no review, no verdict.
        case reviewBudgetOut
        /// F2 Y2a: a reviewer touched the tree: the attempt fails, but nobody judged it, so it is no refusal.
        case reviewerTouched
    }

    enum Effect: Sendable, Equatable {
        case summon, ask
        /// M2.1: the turn ended by hook with no new commit: the agent is told once to commit and end, in what is left
        /// of the turn. Answers like `ask`, or `waitExpired` when it does not go (no time left, the loop stopping).
        case nudge
        /// M10.2: the pre-check failed (its output's tail): the agent is told once, in what is left of the turn. Answers
        /// like `nudge`.
        case precheckNudge(String)
        /// M10.2: the work's `--precheck`, its own time limit: `precheckDone`.
        case runPrecheck
        /// P2: the initial prompt was not delivered: the attempt is redone with a new agent, not counted. Waits the
        /// retry's back-off and adds one to the TASK's free retries (`detail`: the journal's `promptRetry`). No event.
        case promptRetry(String)
        /// `waitForCommit` waits for a commit first (an `.idle` end); both then look once: `commitSeen` or `waitExpired`.
        case waitForCommit, lookForCommit
        case dismiss
        /// Cancelled, closed, starter gone? Else the tree's facts (`measured`).
        case measureFacts
        /// `loop.phase`, what `work status` and the app read.
        case show(WorkLoopState.Phase?)
        case runCheck, guardGate, runGate
        /// Gives another working terminal `othersWait` to finish: `blocked`.
        case awaitOthers
        case settle(reset: Bool)
        /// F2 R3: the personas judge the attempt (spec and personas from the attempt's BASE commit): `reviewDone`.
        case runReview
        /// `AttemptDecision.decide` on the state's facts: `decided`.
        case decide
        case discard, markDone
        /// M2b.1: an adopted commit failed its check or the gate: the task reopens with nothing to resume, a note says
        /// so and nothing is discarded or reset (`reason`: the verdict's).
        case adoptionFailed(reason: String)
        case markOpenOrDeferred(reason: String, last: Bool)
        /// No verdict. `uncount`: the task reopens, the attempt is not counted and `resumeFrom` stays (cancelled). `reopen`: the task
        /// reopens and its job ends with this result.
        case uncount, reopen(job: String)
        case note(String)
        case journal(LoopEvent.Kind, String?)
        case stopLoop(WorkLoopState.Stop)
        /// An event that can never arrive in this phase did (a bug of the interpreter or of this table): which pair.
        /// The state stays; `WorkLoop.attempt()`'s safety net reopens the task and stops the loop.
        case fault(String)

        /// Carrying it out answers with an event.
        var answers: Bool {
            switch self {
            case .summon, .ask, .nudge, .precheckNudge, .runPrecheck, .waitForCommit, .lookForCommit, .measureFacts, .runCheck, .guardGate, .runGate, .awaitOthers, .settle, .runReview, .decide: true
            case .dismiss, .show, .promptRetry, .discard, .markDone, .adoptionFailed, .markOpenOrDeferred, .uncount, .reopen, .note, .journal, .stopLoop, .fault: false
            }
        }
    }

    struct State: Sendable, Equatable {
        var phase = Phase.summoning
        let task: String, n: Int
        /// HEAD when the attempt began.
        let before: String
        var judged: String
        /// The attempt's terminal while it is open.
        var agent: UUID?
        var facts: AttemptDecision.Facts
        /// M2.1: the last turn ended by hook and no nudge went yet / one went (at most one per attempt).
        var nudgeable = false, nudged = false
        /// M10.2: the work has a `--precheck` / its failure was told to the agent (at most once per attempt).
        let hasPrecheck: Bool
        var prechecked = false
        /// M2b.1: the attempt judges a commit it did not see being made: when it fails, nothing is discarded.
        var adopted = false
        /// M3.8: the agent's name, for the journal (`AgentNaming`; the interpreter passes the one it summons with).
        let name: String
        /// F2 R3: the review by personas is on: an attempt that would pass goes to `reviewing` first.
        let reviewer: Bool
        /// P2: the free retries the TASK already spent (a prompt not delivered), across its attempts: at most
        /// `maxPromptRetries`; past them a prompt not delivered is a turn timed out, as before.
        var promptRetries: Int

        init(task: String, n: Int, tries: Int, hasGate: Bool, before: String, name: String? = nil, precheck: Bool = false,
             reviewer: Bool = false, reviewRejectsInRow: Int = 0, promptRetries: Int = 0) {
            self.task = task; self.n = n; self.before = before; judged = before; hasPrecheck = precheck; self.reviewer = reviewer
            self.promptRetries = promptRetries
            self.name = name ?? AgentNaming.name(work: "", task: "", taskId: task, attempt: n, lane: nil)
            facts = .init(attempt: n, tries: tries, hasGate: hasGate)
            facts.reviewRejectsInRow = reviewRejectsInRow
        }
    }

    static func reduce(_ s: State, _ e: Event) -> (State, [Effect]) {
        var s = s
        if s.phase == .finished { return (s, []) }
        switch (s.phase, e) {
        // no verdict, whatever the phase: nothing is judged, discarded or (when cancelled) counted
        case (_, .cancelled): return leave(&s, [.uncount, .stopLoop(.init(.cancelled))])
        case (_, .workClosed): return leave(&s, [.reopen(job: "work closed"), .stopLoop(.init(.workGone))])
        case (_, .starterGone): return leave(&s, [.reopen(job: "starter gone"), .stopLoop(.init(.starterGone))])

        case (.summoning, .started):
            return (s, [.journal(.attemptStarted, nil), .summon])
        // M2.2a: no agent to summon, ask or dismiss: the commit is judged as if its agent had just been dismissed
        case (.summoning, .adopted) where s.agent == nil && s.facts.failure == nil:
            s.phase = .waitingCommit; s.adopted = true
            return (s, [.journal(.attemptStarted, nil), .journal(.adopted, String(s.before.prefix(7))), .measureFacts])
        case (.summoning, .summoned(let id)):
            s.agent = id; s.phase = .turn
            return (s, [.journal(.agentSummoned, s.name), .ask])
        case (.summoning, .summonFailed(let message)):
            s.facts.failure = message
            return (s, [.measureFacts])

        case (.turn, .turnEnded(let source)):
            s.phase = .waitingCommit; s.nudgeable = source == .hook && !s.nudged
            return (s, [.journal(.turnEnded, source.rawValue), source == .idle ? .waitForCommit : .lookForCommit])
        case (.turn, .turnTimedOut(let message)):
            // a turn past its timeout is not a failure by itself: the check decides
            s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, timeoutDetail(message)), .lookForCommit])
        // P2: the attempt's INITIAL prompt never reached the agent: nothing was tried, so the agent goes and the same
        // attempt starts over with a new one, not counted, at most `maxPromptRetries` times per task. A nudge's prompt
        // not delivered is not this: its agent already worked a turn, the check decides as for any timeout
        case (.turn, .promptNotDelivered(let message, let load, let fits)) where s.agent != nil && !s.nudged && !s.prechecked:
            guard s.promptRetries < maxPromptRetries else {
                s.phase = .waitingCommit
                return (s, [.journal(.turnEnded, timeoutDetail(message)), .note(overloadNote(s, load)), .lookForCommit])
            }
            // C1 (P2-a): a free retry with no budget to run in is no retry: the loop stops on the budget, the attempt
            // not counted, the free retries kept and the load not blamed
            guard fits else {
                s.agent = nil; s.phase = .finished
                return (s, [.journal(.turnEnded, timeoutDetail(message)), .dismiss, .journal(.agentDismissed, nil), .uncount,
                            .note(promptRetryBudgetNote(s)), .stopLoop(.init(.budgetSpent))])
            }
            s.promptRetries += 1; s.agent = nil; s.phase = .summoning
            return (s, [.journal(.turnEnded, timeoutDetail(message)), .dismiss, .journal(.agentDismissed, nil),
                        .journal(.promptRetry, "\(s.promptRetries)/\(maxPromptRetries)"), .promptRetry("\(s.promptRetries)/\(maxPromptRetries)"), .summon])
        case (.turn, .promptNotDelivered(let message, _, _)):
            s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, timeoutDetail(message)), .lookForCommit])
        // M5.3: the turn would only end at its timeout and the next attempts would hit the same limit: not counted,
        // nothing discarded (as a cancel), the loop stops and says what to do
        case (.turn, .usageLimit(let text)) where s.agent != nil:
            s.agent = nil; s.phase = .finished
            return (s, [.journal(.turnEnded, "limite de uso"), .dismiss, .journal(.agentDismissed, nil), .uncount, .stopLoop(.init(.usageLimit, detail: text))])
        case (.turn, .turnFailed(let message)):
            // a nudge that could not be asked fails nothing: the attempt is judged as if it had not gone
            if !s.nudged && !s.prechecked { s.facts.failure = message }
            s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, "erro: \(message)"), .lookForCommit])

        // before the check: nothing edits the tree while it is judged (a turn past its timeout may still be working)
        // M10.2: with a pre-check, it runs first, with the agent still there to be told
        case (.waitingCommit, .commitSeen(let short)) where s.agent != nil && s.hasPrecheck:
            return (s, [.journal(.commitSeen, short), .runPrecheck])
        case (.waitingCommit, .commitSeen(let short)) where s.agent != nil:
            s.agent = nil
            return (s, [.journal(.commitSeen, short), .dismiss, .journal(.agentDismissed, nil), .measureFacts])
        case (.waitingCommit, .precheckDone(let status, let tail)) where s.agent != nil && s.hasPrecheck:
            let ran = ran(status, nil)
            if status == 0 || s.prechecked {   // passed, or failed after its one nudge: the check, as without it
                s.agent = nil
                return (s, [.journal(status == 0 ? .precheckPassed : .precheckFailed, ran), .dismiss, .journal(.agentDismissed, nil), .measureFacts])
            }
            s.prechecked = true; s.phase = .turn
            return (s, [.journal(.precheckFailed, ran), .precheckNudge(tail)])
        // M2.1: a hook is a frail sign that the work is over (a question, a permission dialog, a compaction): with no
        // commit the agent is nudged once, in the same attempt; `.idle` already waits for the commit, a timeout has no
        // time left and a failed ask has no one to tell
        case (.waitingCommit, .waitExpired) where s.agent != nil && s.nudgeable:
            s.nudgeable = false; s.nudged = true; s.phase = .turn
            return (s, [.nudge])
        // `.turn`: the nudge did not go
        case (.waitingCommit, .waitExpired) where s.agent != nil, (.turn, .waitExpired) where s.agent != nil && (s.nudged || s.prechecked):
            s.agent = nil; s.phase = .waitingCommit
            return (s, [.dismiss, .journal(.agentDismissed, nil), .measureFacts])

        case (.summoning, .measured(let m)), (.waitingCommit, .measured(let m)):
            if s.facts.failure != nil { return verdict(&s) }   // failed before its check: straight to the verdict
            guard s.phase == .waitingCommit, s.agent == nil, let m else { return stray(s, e) }
            s.facts.committed = m.committed; s.facts.dirty = m.dirty; s.judged = m.judged; s.phase = .checking
            return (s, [.show(.check), .journal(.checkStarted, nil), .runCheck])

        case (.checking, .checkDone(let status, let broken)):
            s.facts.broken = broken; s.facts.checkStatus = status
            // the tree goes back to exactly `judged`: not when dirty (the agent's uncommitted work is the patch's) nor
            // while another terminal works (asked only when there would be a reset)
            return (s, [.journal(.checkFinished, ran(status, broken)), s.facts.dirty ? .settle(reset: false) : .awaitOthers])
        case (.checking, .blocked(let who)), (.gating, .blocked(let who)):
            s.facts.blockedBy = who
            return (s, [.settle(reset: who == nil)])
        case (.checking, .settled(let moved, let reset)):
            if moved { s.facts.moves.append("o check moveu o HEAD") }
            let fx = resetLine(moved, reset), f = s.facts
            // the gate: only when nothing else already fails the attempt (no budget spent on a lost one)
            guard f.hasGate, f.broken == nil, f.checkStatus == 0, f.committed, !f.dirty, f.moves.isEmpty else { return verdict(&s, fx) }
            if f.blockedBy != nil {
                s.facts.gate = "gate did not run (tree not reset)"
                return verdict(&s, fx + [.journal(.gateFinished, "não rodou")])
            }
            // the agent may not rewrite the script that judges it: the gate does not run on a tree that changed it
            return (s, fx + [.guardGate])
        case (.checking, .gateSkipped(let why)):
            s.facts.gate = why
            return verdict(&s, [.journal(.gateFinished, "não rodou")])
        case (.checking, .gateClear):
            s.phase = .gating
            return (s, [.show(.gate), .journal(.gateStarted, nil), .runGate])

        case (.gating, .gateDone(let status, let broken)):
            s.facts.gate = broken ?? WorkLoop.failure("gate", status)
            return (s, [.journal(.gateFinished, ran(status, broken)), .awaitOthers])
        case (.gating, .settled(let moved, let reset)):
            if moved { s.facts.moves.append("o portão moveu o HEAD") }
            return verdict(&s, resetLine(moved, reset))

        // F2 R3: a veto is a failure as any other (retry, defer on the last try or after two in a row)
        // A1 (reviewAdvisory): only a veto; approve, mute, invalid and minor-only reject are notes ('sem parecer: ...')
        case (.reviewing, .reviewDone(let outcome)):
            if outcome.approved { s.facts.reviewNotes = outcome.notes } else { s.facts.review = outcome.reason ?? "revisor recusou" }
            return verdict(&s)
        // F2 X3: the budget ran out, not the attempt: like a cancel it is not counted (nor as a refusal), the loop stops
        // F2 Y2a: the attempt fails on it (a move, not `review`): it is not counted in reviewRejects nor "in a row"
        case (.reviewing, .reviewerTouched):
            s.facts.moves.append(WorkLoop.reviewerTouched)
            return verdict(&s)
        case (.reviewing, .reviewBudgetOut):
            return leave(&s, [.uncount, .note(WorkLoop.reviewBudgetNote), .stopLoop(.init(.budgetSpent))])

        case (.deciding, .blocked(let who)):
            s.facts.blockedBy = who
            return (s, [.decide])
        case (.deciding, .decided(let outcome)):
            s.phase = .finished
            // the interpreter journals the patch's name only when `discard` wrote one (else `WorkLoop.noPatch`)
            let patch: [Effect] = [.discard, .journal(.discarded, "\(s.task)-\(s.n).patch")]
            // M2b.1: an adoption that fails never goes back to `before`: between it and HEAD there may be commits the
            // loop did not see being made. The tree stays, the loop stops and the owner decides
            if s.adopted, outcome != .pass {
                return (s, [.adoptionFailed(reason: AttemptDecision.reason(s.facts) ?? ""), .stopLoop(.init(.adoptionFailed))])
            }
            switch outcome {
            case .pass:
                // the task passed and another terminal works: nothing to discard, the loop stops after it
                let notes = s.facts.reviewNotes
                let done: [Effect] = [.markDone] + (notes.isEmpty ? [] : [.note("[loop \(s.task)] parecer: " + notes.joined(separator: "; "))])
                guard let who = s.facts.blockedBy else { return (s, done) }
                return (s, done + [.note(WorkLoop.blockedNote(who)), .stopLoop(.init(.othersWorking, detail: who))])
            case .retry(let reason, let discards):
                return (s, (discards ? patch : []) + [.markOpenOrDeferred(reason: reason, last: false)])
            case .defer(let reason, let discards):
                return (s, (discards ? patch : []) + [.markOpenOrDeferred(reason: reason, last: true)])
            case .stopLoop(let stop, let reason):
                return (s, [.markOpenOrDeferred(reason: reason, last: false), .note(WorkLoop.blockedNote(s.facts.blockedBy ?? "")), .stopLoop(stop)])
            }

        default:
            return stray(s, e)   // not this phase's event: it never should have come
        }
    }

    /// P2: free retries (a prompt not delivered) per task; the next one counts as a normal attempt.
    static let maxPromptRetries = 2

    /// P2: the journal's `turnEnded` detail of a timeout: its message, clean, at most 120 characters.
    static func timeoutDetail(_ message: String) -> String {
        message.isEmpty ? "timeout" : "timeout: " + String(WorkLoop.eventDetail(message).prefix(120))
    }

    /// C1 (P2-a): the prompt was not delivered and the budget left holds no other try.
    static func promptRetryBudgetNote(_ s: State) -> String {
        "[loop] tarefa \(s.task), tentativa \(s.n): prompt não entregue e o orçamento de tempo que resta não cabe outra tentativa: tentativa não contada; laço parado"
    }

    /// P2: the task spent its free retries and its prompt was not delivered again: load is the likely cause.
    static func overloadNote(_ s: State, _ load: Double) -> String {
        "[loop] tarefa \(s.task), tentativa \(s.n): prompt não entregue \(maxPromptRetries + 1) vezes seguidas; a máquina está sobrecarregada? (load average \(String(format: "%.2f", load)))"
    }

    /// Nothing changes and the interpreter is told (`fault`): the pair, without the event's payload (it may be the
    /// agent's text).
    private static func stray(_ s: State, _ e: Event) -> (State, [Effect]) {
        (s, [.fault("\(s.phase) × \(String(describing: e).prefix { $0 != "(" })")])
    }

    /// Out with no verdict; a terminal still open is dismissed first.
    private static func leave(_ s: inout State, _ fx: [Effect]) -> (State, [Effect]) {
        let open: [Effect] = s.agent == nil ? [] : [.dismiss, .journal(.agentDismissed, nil)]
        s.agent = nil; s.phase = .finished
        return (s, open + fx)
    }

    /// Into `deciding`, after `fx`. A failed attempt that did not ask yet (it failed before its check, or its tree was
    /// dirty) asks about other terminals now: the discard is a reset too. Not a failed adoption: it discards nothing.
    /// F2 R3: with the review on, an attempt that would pass is reviewed first (once: `reviewing` comes back here).
    private static func verdict(_ s: inout State, _ fx: [Effect] = []) -> (State, [Effect]) {
        let failed = AttemptDecision.reason(s.facts)
        if s.reviewer, s.phase != .reviewing, failed == nil {
            s.phase = .reviewing
            return (s, fx + [.show(.review), .runReview])
        }
        s.phase = .deciding
        return (s, fx + [.show(nil), .journal(.verdict, failed ?? "passou"), failed != nil && s.facts.blockedBy == nil && !s.adopted ? .awaitOthers : .decide])
    }

    /// The journal's word for how the check or the gate ran.
    private static func ran(_ status: Int32?, _ broken: String?) -> String {
        broken != nil ? "não rodou" : status.map { "exit \($0)" } ?? "timeout"
    }

    private static func resetLine(_ moved: Bool, _ reset: Bool) -> [Effect] {
        reset ? [.journal(.treeReset, moved ? "moveu o HEAD" : nil)] : []
    }
}
