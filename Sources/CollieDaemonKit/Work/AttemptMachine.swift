import Foundation
import CollieCore

/// One attempt of the loop as a state machine. `reduce` is pure (no host, store, git or clock): it takes what
/// `WorkLoop.attempt()` observed (an `Event`, never the agent's words) and says what to do next (`Effect`s, in order).
/// `attempt()` is the interpreter: it carries each effect out and hands the resulting event back, until `finished`.
/// In every list `reduce` returns, only the last effect answers with an event (`Effect.answers`).
enum AttemptMachine {
    enum Phase: Sendable, Equatable, CaseIterable { case summoning, turn, waitingCommit, checking, gating, deciding, finished }

    /// What `measureFacts` read from the tree once the agent is gone.
    struct Measured: Sendable, Equatable {
        var committed: Bool, dirty: Bool
        /// The commit the agent left: what the check and the gate judge.
        var judged: String
    }

    enum Event: Sendable, Equatable {
        case started
        case summoned(UUID), summonFailed(String)
        case turnEnded(source: AskResult.Source), turnTimedOut, turnFailed(String)
        /// A new commit is there (its short hash, for the journal) / there is none.
        case commitSeen(String?), waitExpired
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
    }

    enum Effect: Sendable, Equatable {
        case summon, ask
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
        /// `AttemptDecision.decide` on the state's facts: `decided`.
        case decide
        case discard, markDone
        case markOpenOrDeferred(reason: String, last: Bool)
        /// No verdict. `uncount`: the task reopens and the attempt is not counted (cancelled). `reopen`: the task
        /// reopens and its job ends with this result.
        case uncount, reopen(job: String)
        case note(String)
        case journal(LoopEvent.Kind, String?)
        case stopLoop(WorkLoopState.Stop)

        /// Carrying it out answers with an event.
        var answers: Bool {
            switch self {
            case .summon, .ask, .waitForCommit, .lookForCommit, .measureFacts, .runCheck, .guardGate, .runGate, .awaitOthers, .settle, .decide: true
            case .dismiss, .show, .discard, .markDone, .markOpenOrDeferred, .uncount, .reopen, .note, .journal, .stopLoop: false
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
        var name: String { "loop-\(task)-\(n)" }

        init(task: String, n: Int, tries: Int, hasGate: Bool, before: String) {
            self.task = task; self.n = n; self.before = before; judged = before
            facts = .init(attempt: n, tries: tries, hasGate: hasGate)
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
        case (.summoning, .summoned(let id)):
            s.agent = id; s.phase = .turn
            return (s, [.journal(.agentSummoned, s.name), .ask])
        case (.summoning, .summonFailed(let message)):
            s.facts.failure = message
            return (s, [.measureFacts])

        case (.turn, .turnEnded(let source)):
            s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, source.rawValue), source == .idle ? .waitForCommit : .lookForCommit])
        case (.turn, .turnTimedOut):
            // a turn past its timeout is not a failure by itself: the check decides
            s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, "timeout"), .lookForCommit])
        case (.turn, .turnFailed(let message)):
            s.facts.failure = message; s.phase = .waitingCommit
            return (s, [.journal(.turnEnded, "erro: \(message)"), .lookForCommit])

        // before the check: nothing edits the tree while it is judged (a turn past its timeout may still be working)
        case (.waitingCommit, .commitSeen(let short)) where s.agent != nil:
            s.agent = nil
            return (s, [.journal(.commitSeen, short), .dismiss, .journal(.agentDismissed, nil), .measureFacts])
        case (.waitingCommit, .waitExpired) where s.agent != nil:
            s.agent = nil
            return (s, [.dismiss, .journal(.agentDismissed, nil), .measureFacts])

        case (.summoning, .measured(let m)), (.waitingCommit, .measured(let m)):
            if s.facts.failure != nil { return verdict(&s) }   // failed before its check: straight to the verdict
            guard s.phase == .waitingCommit, s.agent == nil, let m else { return (s, []) }
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

        case (.deciding, .blocked(let who)):
            s.facts.blockedBy = who
            return (s, [.decide])
        case (.deciding, .decided(let outcome)):
            s.phase = .finished
            let patch: [Effect] = [.discard, .journal(.discarded, "\(s.task)-\(s.n).patch")]
            switch outcome {
            case .pass:
                // the task passed and another terminal works: nothing to discard, the loop stops after it
                guard let who = s.facts.blockedBy else { return (s, [.markDone]) }
                return (s, [.markDone, .note(WorkLoop.blockedNote(who)), .stopLoop(.init(.othersWorking, detail: who))])
            case .retry(let reason, let discards):
                return (s, (discards ? patch : []) + [.markOpenOrDeferred(reason: reason, last: false)])
            case .defer(let reason, let discards):
                return (s, (discards ? patch : []) + [.markOpenOrDeferred(reason: reason, last: true)])
            case .stopLoop(let stop, let reason):
                return (s, [.markOpenOrDeferred(reason: reason, last: false), .note(WorkLoop.blockedNote(s.facts.blockedBy ?? "")), .stopLoop(stop)])
            }

        default:
            return (s, [])   // not this phase's event: nothing changes
        }
    }

    /// Out with no verdict; a terminal still open is dismissed first.
    private static func leave(_ s: inout State, _ fx: [Effect]) -> (State, [Effect]) {
        let open: [Effect] = s.agent == nil ? [] : [.dismiss, .journal(.agentDismissed, nil)]
        s.agent = nil; s.phase = .finished
        return (s, open + fx)
    }

    /// Into `deciding`, after `fx`. A failed attempt that did not ask yet (it failed before its check, or its tree was
    /// dirty) asks about other terminals now: the discard is a reset too.
    private static func verdict(_ s: inout State, _ fx: [Effect] = []) -> (State, [Effect]) {
        s.phase = .deciding
        let failed = AttemptDecision.reason(s.facts)
        return (s, fx + [.show(nil), .journal(.verdict, failed ?? "passou"), failed != nil && s.facts.blockedBy == nil ? .awaitOthers : .decide])
    }

    /// The journal's word for how the check or the gate ran.
    private static func ran(_ status: Int32?, _ broken: String?) -> String {
        broken != nil ? "não rodou" : status.map { "exit \($0)" } ?? "timeout"
    }

    private static func resetLine(_ moved: Bool, _ reset: Bool) -> [Effect] {
        reset ? [.journal(.treeReset, moved ? "moveu o HEAD" : nil)] : []
    }
}
