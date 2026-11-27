import Foundation

public enum TaskState: String, Codable, Sendable { case open, inProgress, done, deferred, abandoned }

/// What the loop held when it approved a task: `commits` (`<short sha> <subject>`, newest first, at most 20) and
/// `shortstat` of the attempt, `checkTail` (the last lines of the check's and the gate's output, secrets hidden, at
/// most 2000 characters), `seconds` the attempt took and `attempt` (1-based) that passed. `files`: the names of the
/// files the task's `evidenceGlob` matched, copied into `filesDir` (absolute, on the daemon's machine); nil: the task
/// declared none.
public struct TaskEvidence: Codable, Sendable, Equatable {
    public var commits: [String]; public var shortstat: String; public var checkTail: String
    public var seconds: Int; public var attempt: Int
    public var files: [String]?; public var filesDir: String?
    /// F3: the runtime acceptance's whole output (`WorkLoop.acceptOutput`: scrubbed, head and tail, at most 64 KB); nil:
    /// the task has no `--accept`.
    public var acceptOutput: String?
    public init(commits: [String], shortstat: String, checkTail: String, seconds: Int, attempt: Int,
                files: [String]? = nil, filesDir: String? = nil) {
        self.commits = commits; self.shortstat = shortstat; self.checkTail = checkTail; self.seconds = seconds; self.attempt = attempt
        self.files = files; self.filesDir = filesDir
    }
    /// What the owner reads beside a done task (status, panel, the loop's end notice):
    /// "tentativa 2 · 3 commits · 4 files changed, 10 insertions(+)"; an empty shortstat is left out.
    public var summary: String {
        (["tentativa \(attempt)", "\(commits.count) " + (commits.count == 1 ? "commit" : "commits")] + (shortstat.isEmpty ? [] : [shortstat]))
            .joined(separator: " · ")
    }
}

/// One task of a work: `id` is the agent's own, else generated. `spec` (absolute path of a Markdown file) and `check`
/// (a shell command, exit 0 = passes) matter only to `collie work run`; `tries` is the attempts a loop used and
/// `lastFailure` one line on why the last one failed. `evidence`: set by the loop when it approves the task; a task
/// that leaves `done` (reopened, run again) loses it. `evidenceGlob`: relative to the worktree, the files the loop
/// copies as evidence when it approves the task. `needs` (M3.1): ids of tasks of the same work that must be `done`
/// (and integrated) before this one starts. `scope` (M3.1): globs relative to the worktree's root, the paths the task
/// may touch; nil: it may touch anything, so it runs alone (`TaskScheduler`).
public struct WorkTask: Codable, Sendable, Equatable {
    public var id: String; public var title: String; public var reason: String?; public var updatedAt: Date
    public var state: TaskState {
        didSet {
            if state != .done { evidence = nil }
            // M2b.1: only a task of the loop (open, in an attempt) has something to resume
            if state != .open && state != .inProgress { forgetResume() }
        }
    }
    public var spec: String?; public var check: String?; public var tries: Int?; public var lastFailure: String?
    public var evidence: TaskEvidence?
    public var evidenceGlob: String?
    public var needs: [String]?; public var scope: [String]?
    /// C2: `--green-ok`: the check may already pass before the task (a refactoring): `work run` does not refuse it for that. nil: it may not.
    public var greenOk: Bool?
    /// M5.4: the token counts of every attempt of the loop on this task, summed (nil: none read). Counts only.
    public var tokens: TokenCount?
    /// F2 R1, `work task add --agent --model`: the agent (claude|cursor|codex) and model of WHO WORKS on the task (nil:
    /// the loop's). Only recorded and shown for now; R4 uses them.
    public var agent: String?; public var model: String?
    /// F2 R4: the last review of the task, as the summary shows it ("parecer: sem veto (personas: a, b; 2 achados)"),
    /// and the review's refusals in a row (between attempts; an approval zeroes it). nil: no review ran.
    public var review: String?; public var reviewRejects: Int?
    /// A4: the task's last attempt was reviewed and every persona answered with no veto (no mute or invalid one, the tree
    /// as judged). nil: not so, or no review ran in it (cleared as each attempt starts). What `--auto-land` requires.
    public var reviewClean: Bool?
    /// C3a: the HEAD the clean review judged (set with `reviewClean`): a land whose HEAD is past it is no approval.
    public var reviewedHead: String?
    /// F3, `work task add --accept`: a shell command that judges the RESULT running (exit 0 = accepted), run by the loop
    /// after the check and the gate, in the check's conditions; `acceptTimeout` its seconds (nil: `acceptTimeoutDefault`,
    /// at most `acceptTimeoutMax`). The owner's, kept in the work's state: the loop never reads it from the worktree.
    public var accept: String?; public var acceptTimeout: Int?
    public static let acceptTimeoutDefault = 600, acceptTimeoutMax = 1800
    /// F3: the acceptance of the task's LAST attempt passed (true) / failed or did not run (false); nil: it never ran
    /// in that attempt (cleared as each attempt starts). What `--auto-land` requires of a task with `accept`.
    public var acceptPassed: Bool?
    /// F3: one line on that last acceptance ("passou (exit 0)", "falhou (exit 1)", "não rodou: ..."), for the owner.
    public var acceptResult: String?
    /// P2: the free retries the loop spent on this task because an attempt's prompt was not delivered (nil: none).
    public var promptRetries: Int?
    /// M2.2a: set while an attempt of the loop runs: the HEAD sha it started from and the branch it ran on. Cleared when
    /// the attempt ends; a daemon that fell mid-attempt leaves them, and the next run may adopt the commit already made.
    /// Read back from the work's file: never trusted as a git argument before `WorkLoop.isSha`.
    public var resumeFrom: String?; public var resumeBranch: String?
    /// M2b.1: when the attempt was left (the daemon's stop, or the start sweep that found it): only commits made up to
    /// then can be the fallen attempt's. nil while the attempt runs; without it nothing is adopted.
    public var resumeAt: Date?
    /// M2b.1: nothing to resume: the three go together.
    public mutating func forgetResume() { resumeFrom = nil; resumeBranch = nil; resumeAt = nil }
    /// C4a: the loop's verdicts on the task (a clean review, the HEAD it judged, a passed acceptance) dropped: what the
    /// auto-land trusts is only ever an attempt's own (`work task done` by hand, `work task reopen`).
    public mutating func clearVerdicts() { reviewClean = nil; reviewedHead = nil; acceptPassed = nil }
    public init(id: String, title: String, state: TaskState = .open, reason: String? = nil, updatedAt: Date = Date(),
                spec: String? = nil, check: String? = nil, tries: Int? = nil, lastFailure: String? = nil,
                evidence: TaskEvidence? = nil, evidenceGlob: String? = nil, needs: [String]? = nil, scope: [String]? = nil, greenOk: Bool? = nil) {
        self.greenOk = greenOk
        self.id = id; self.title = title; self.state = state; self.reason = reason; self.updatedAt = updatedAt
        self.spec = spec; self.check = check; self.tries = tries; self.lastFailure = lastFailure; self.evidence = evidence
        self.evidenceGlob = evidenceGlob; self.needs = needs; self.scope = scope
    }
    /// As the synthesized one, but `resumeFrom`, `resumeBranch` and `resumeAt` (M2b.1) only say where a fallen attempt
    /// may resume: one of the wrong type is nil (nothing is adopted) and the task survives. What is written does not change.
    /// M3.1: `needs` and `scope` of the wrong type are nil too (no `scope` is the safe side: the task runs alone).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        reason = try c.decodeIfPresent(String.self, forKey: .reason); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        state = try c.decode(TaskState.self, forKey: .state)
        spec = try c.decodeIfPresent(String.self, forKey: .spec); check = try c.decodeIfPresent(String.self, forKey: .check)
        tries = try c.decodeIfPresent(Int.self, forKey: .tries); lastFailure = try c.decodeIfPresent(String.self, forKey: .lastFailure)
        evidence = try c.decodeIfPresent(TaskEvidence.self, forKey: .evidence)
        evidenceGlob = try c.decodeIfPresent(String.self, forKey: .evidenceGlob)
        resumeFrom = (try? c.decodeIfPresent(String.self, forKey: .resumeFrom)) ?? nil
        resumeBranch = (try? c.decodeIfPresent(String.self, forKey: .resumeBranch)) ?? nil
        resumeAt = (try? c.decodeIfPresent(Date.self, forKey: .resumeAt)) ?? nil
        needs = (try? c.decodeIfPresent([String].self, forKey: .needs)) ?? nil
        scope = (try? c.decodeIfPresent([String].self, forKey: .scope)) ?? nil
        greenOk = (try? c.decodeIfPresent(Bool.self, forKey: .greenOk)) ?? nil
        tokens = (try? c.decodeIfPresent(TokenCount.self, forKey: .tokens)) ?? nil   // M5.4: tolerant, like resume
        agent = (try? c.decodeIfPresent(String.self, forKey: .agent)) ?? nil   // F2 R1: tolerant too
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        review = (try? c.decodeIfPresent(String.self, forKey: .review)) ?? nil   // F2 R4: tolerant too
        reviewRejects = (try? c.decodeIfPresent(Int.self, forKey: .reviewRejects)) ?? nil
        promptRetries = (try? c.decodeIfPresent(Int.self, forKey: .promptRetries)) ?? nil   // P2: tolerant too
        reviewClean = (try? c.decodeIfPresent(Bool.self, forKey: .reviewClean)) ?? nil   // A4: tolerant too
        reviewedHead = (try? c.decodeIfPresent(String.self, forKey: .reviewedHead)) ?? nil   // C3a: tolerant too
        accept = (try? c.decodeIfPresent(String.self, forKey: .accept)) ?? nil   // F3: tolerant too
        acceptTimeout = (try? c.decodeIfPresent(Int.self, forKey: .acceptTimeout)) ?? nil
        acceptPassed = (try? c.decodeIfPresent(Bool.self, forKey: .acceptPassed)) ?? nil
        acceptResult = (try? c.decodeIfPresent(String.self, forKey: .acceptResult)) ?? nil
    }
}

/// M5.4: what one attempt's agent (or a sum of them) used, from its transcript's assistant messages: counts only, never
/// content. `index` is a *relative* weight of the counts (`weights`), never a cost in money.
public struct TokenCount: Codable, Sendable, Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, messages = 0
    /// The model of the last counted message (a sum: the latest one's).
    public var model: String?
    /// The relative index's weights: input 1, cache write 1.25, output 5, cache read 0.1 (Claude's relative price per
    /// token). ponytail: constants; change them here if the ratios change.
    public static let inputWeight = 1.0, cacheWriteWeight = 1.25, outputWeight = 5.0, cacheReadWeight = 0.1
    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, messages: Int = 0, model: String? = nil) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead; self.messages = messages; self.model = model
    }
    /// Every field tolerant: one of the wrong type is 0 (nil for `model`).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func n(_ k: CodingKeys) -> Int { max(0, ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? 0) }
        input = n(.input); output = n(.output); cacheWrite = n(.cacheWrite); cacheRead = n(.cacheRead); messages = n(.messages)
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
    }
    public var index: Double {
        Double(input) * Self.inputWeight + Double(cacheWrite) * Self.cacheWriteWeight
            + Double(output) * Self.outputWeight + Double(cacheRead) * Self.cacheReadWeight
    }
    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                   cacheRead: a.cacheRead + b.cacheRead, messages: a.messages + b.messages, model: b.model ?? a.model)
    }
    /// "1,2 M (índice relativo) · 14 msgs": decimal comma; "mil" and "M" past a thousand and a million.
    public var label: String {
        let i = index
        let en = L10n.current == .en
        let n = i >= 1e6 ? String(format: "%.1f M", i / 1e6) : i >= 1e3 ? String(format: en ? "%.1f k" : "%.1f mil", i / 1e3) : String(Int(i.rounded()))
        return (en ? n : n.replacingOccurrences(of: ".", with: ",")) + tr(" (índice relativo) · \(messages) ", " (relative index) · \(messages) ") + (messages == 1 ? "msg" : "msgs")
    }
}

/// One line of a loop's journal (`WorkLoopState.events`): what the loop did at `at`, on which `task` and `attempt`
/// (nil: the loop itself), and `detail` (at most 200 characters) what the kind alone does not say.
public struct LoopEvent: Codable, Sendable, Equatable {
    /// `unknown` is a reserve (a kind written by a newer daemon decodes as it): this daemon never records it.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case attemptStarted, agentSummoned, turnEnded, commitSeen, agentDismissed, checkStarted, checkFinished
        case gateStarted, gateFinished, treeReset, othersWaiting, verdict, discarded, stopRequested, stopped, unknown
        /// M2.0: the attempt's prompt was not submitted and its Enter was sent again (detail: the terminal's name).
        case resubmitted
        /// M2.1: the turn ended with no new commit and the agent was told once to commit and end (detail: how the turn ended).
        case nudged
        /// M2.2a: the attempt judged a commit a fallen daemon's agent left, with no agent of its own (detail: the sha it resumed from).
        case adopted
        /// M3.5: a lane that passed was joined to the paddock's branch (detail: the paddock's new HEAD) / its merge was
        /// undone and the task redoes its attempt from the paddock's new HEAD (detail: why).
        case integrated, integrationRetry
        /// M10.2: the work's `--precheck` failed / passed at the end of a turn (detail: `exit n` or `timeout`).
        case precheckFailed, precheckPassed
        /// P1: a persona gave no review answer (detail: why) / every persona did and the review ran once more (detail: that).
        case reviewerMute, reviewRetried
        /// P2: the attempt's prompt was not delivered and the attempt starts over with a new agent, not counted (detail:
        /// the task's free retries used, `n/2`).
        case promptRetry
        /// A4, `--auto-land`: the paddock was landed (merge) once every task was done (detail: "<base before> -> <after>").
        case landed
        /// F3: the task's runtime acceptance (`--accept`) started / passed / failed or did not run (detail: `exit n`,
        /// `timeout` or `não rodou`).
        case acceptStarted, acceptPassed, acceptFailed
        /// C5c: the loop's first phase, the open tasks' checks run once at the paddock's HEAD (`checkAlreadyGreen`)
        /// started / finished (detail: how many passed).
        case preCheckStarted, preCheckFinished
        /// C6, `--auto-land`: the land's gate and its local CI started / finished (detail: `exit n em s s`, `timeout em s s`
        /// or `não rodou`).
        case landGateStarted, landGateFinished, landCiStarted, landCiFinished
        public init(from d: Decoder) throws { self = Kind(rawValue: try d.singleValueContainer().decode(String.self)) ?? .unknown }
    }
    public static let detailMax = 200
    public var at: Date; public var kind: Kind; public var task: String?; public var attempt: Int?; public var detail: String?
    /// M3.5: the lane the event happened in (its folder's name); nil: the paddock's worktree (always, without `--parallel`).
    public var lane: String?
    /// M5.4: on `agentDismissed`, what that attempt's agent used (nil: not read: no transcript, refused or too big).
    public var tokens: TokenCount?
    public init(at: Date = Date(), kind: Kind, task: String? = nil, attempt: Int? = nil, detail: String? = nil, lane: String? = nil, tokens: TokenCount? = nil) {
        self.at = at; self.kind = kind; self.task = task; self.attempt = attempt; self.lane = lane; self.tokens = tokens
        self.detail = detail.map { String($0.prefix(Self.detailMax)) }
    }
}

/// A work run by `collie work run`: `task` is the current task's id, `attempt` (1-based) its attempt; `tries` and
/// `timeout` (seconds, a turn) are per task; `max` caps and `used` counts attempts across tasks; `budget` caps and
/// `spent` counts the seconds of all attempts (turns and checks); `tasks`: the ids the owner approved (a task added
/// later waits for the next run; nil: every open task); `gate`: a command run after every task's check, in the same
/// conditions, that must also exit 0 (nil: none).
public struct WorkLoopState: Codable, Sendable, Equatable {
    /// A5: `queued`, a `work run --auto-land --queue` the owner approved on the card (its tasks, checks, gate and limits)
    /// that waits in its paddock's queue: no engine runs it until an auto-land chain activates it (`running`).
    public enum State: String, Codable, Sendable { case running, stopped, finished, queued }
    public var state: State
    public var task: String?
    public var attempt: Int
    public var tries: Int; public var timeout: Int
    public var preset: String?; public var model: String?; public var command: String?
    public var max: Int?; public var used: Int
    public var budget: Int?; public var spent: Int?; public var tasks: [String]?
    public var gate: String?
    /// M10.2: a command run at the end of each turn, before the check, with the agent still there: when it fails the
    /// agent is told its output's tail once (nil: none, the loop as before).
    public var precheck: String?
    /// C5c: set by `work run`: the loop's first phase runs every open task's check once (not `--green-ok`) and stops
    /// with `checkAlreadyGreen` when one already passes. nil: none (a loop from before, or a test's).
    public var greenPreCheck: Bool?
    /// C3, `work run --escalate agent:model,…`: the agent of attempt `n` of a task is entry `min(n, count) - 1`; with it
    /// set, `preset`/`model`/`command` are nil. nil: every attempt runs the same agent, as before.
    public var escalate: [String]?
    /// The preset and model of the task's attempt `n` (1-based) under `escalate`; nil without it.
    public func escalation(attempt n: Int) -> (preset: String, model: String)? {
        guard let list = escalate, !list.isEmpty else { return nil }
        let parts = list[Swift.min(Swift.max(n, 1), list.count) - 1].split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    /// F2 R1, `work run --review`: the review by personas is on (nil/false: off, the loop as before); `personas` the
    /// names chosen (nil: auto, R5's router picks); `reviewerModel` the model that overrides every persona's (nil: each
    /// persona's own, else the loop's). Only recorded and shown for now.
    public var review: Bool?; public var personas: [String]?; public var reviewerModel: String?
    /// A1: from `factory.review` of the base's `collie-work.json`. `reviewOnly`: the profile's personas, which restrict
    /// the "auto" choice (nil: no restriction); `reviewThreshold`: "blocker" (only a blocker vetoes) or "major" (nil: major).
    public var reviewOnly: [String]?; public var reviewThreshold: String?
    /// A1: where review, budget and tries came from: key ("review", "budget", "tries") → "perfil", "flag" or "padrão".
    /// nil: the base has no `factory` (the loop as before).
    public var origins: [String: String]?
    /// A1: how many `factory.guardrails.destructive` patterns the profile has; shown as a warning only, never enforced.
    public var destructive: Int?
    /// F2 U1 (`--review`): `~/.claude.json` as the loop began, before its first judged agent: its hash
    /// (`reviewGlobalConfigHash`) and its `env`/`autoConnectIde` (`reviewGlobalConfigRisky`). Every attempt of the run is
    /// compared with these, never with a base taken after an agent ran. nil: not taken (no review, or a loop from before).
    public var reviewConfigBase: String?, reviewConfigBaseRisky: String?
    /// R1: what `node_modules/.bin`, `.venv/bin` and `venv/bin` held (name, size, date; never the content) before the
    /// work's first attempt, or since the last task passed. Ignored by git, a failed attempt's rewrite there survives the
    /// reset: every later attempt is compared with this, never with a base taken after it. nil: not taken yet.
    public var bins: [String]?
    /// What a running loop is doing right now: its terminal is only open during `agent`, so without this a loop in its
    /// check or gate looks idle (no terminal, no signal).
    public enum Phase: String, Codable, Sendable {
        /// F2 R3: `review`, the personas judging the attempt.
        /// C5c: `preCheck`, the loop's first phase (the open tasks' checks before any attempt).
        case agent, check, gate, review, preCheck
        public var label: String {
            switch self { case .agent: tr("agente trabalhando", "agent working"); case .check: tr("rodando o check", "running the check"); case .gate: tr("rodando o portão", "running the gate"); case .review: tr("revisão", "review")
            case .preCheck: tr("verificando checks que já passam", "verifying checks that already pass") }
        }
    }
    public var phase: Phase?
    /// When `phase` last changed (`show`); nil: no phase, or a loop written before this existed.
    public var phaseSince: Date?
    /// Sets `phase`; a phase that changes starts counting at `at` (the same phase again keeps its time).
    public mutating func show(_ p: Phase?, at: Date = Date()) {
        if p != phase { phaseSince = p == nil ? nil : at }
        phase = p
    }
    /// Why a loop that did not finish stopped: one `code` per way out of the engine, `detail` (at most 200 characters)
    /// what the code alone does not say (`othersWorking`: the terminal's name).
    public struct Stop: Codable, Sendable, Equatable {
        /// `unknown` is a reserve (a code written by a newer daemon decodes as it): no path of this daemon produces it.
        public enum Code: String, Codable, Sendable, CaseIterable {
            case requested, workGone, starterGone, maxReached, budgetSpent, gitFailed, dirtyTree, othersWorking, cancelled, daemonRestart, `internal`, unknown
                /// M2b.1: an adopted commit did not pass its check or the gate: nothing was reset, the owner decides.
                case adoptionFailed
                /// M5.3: the attempt's agent hit the model's usage limit (detail: the dialog's text, short): not counted.
                case usageLimit
                /// A4, `--auto-land`: every task done and the paddock landed (merge; detail: "<base before> -> <base after>").
                /// The loop `finished`; the others stop it before any land: the gate red, a veto or no clean review, the
                /// local CI red, a dirty tree or another agent busy, the land refused (a conflict or any failure), the
                /// paddock no longer a factory's.
                case landed, landGateRed, landReviewVeto, landCiRed, landDirty, landConflict, landNotFactory
                /// A5, after a land: no approved work left in the paddock's queue (no error: the loop finished); the
                /// paddock's lands in the last 24 h reached `factory.guardrails.autoLandPerDay`; the factory doctor of
                /// the paddock no longer passes the minimum (static and judge at least 1). `maxReached` with a detail:
                /// `--auto-land-max` lands made while approved works still wait.
                case queueEmpty, landDailyCap, landDoctorRegressed
                /// C3a: the merge made no commit (the paddock had nothing new, or was integrated already): no land, not
                /// counted in the daily cap nor in the chain.
                case landNothing
                /// F3: a task of the work has `--accept` and its last acceptance did not pass in the winning attempt.
                case landAcceptRed
                /// C3b: the base branch is not the commit it was when the last attempt began (`AutoLand.baseHead`), or no
                /// such commit is known: the merge would integrate a tree nobody judged on that base. The owner redoes it.
                case landBaseMoved
                /// C4a: the merge was made but the paddock's land record (`Paddock.autoLands`, what the daily cap counts)
                /// could not be written: the loop stops rather than land on uncounted; the owner is told.
                case landRegistryFailed
                /// C5a: `--auto-land` and a task of the run not done (deferred by a red gate or acceptance, or still open):
                /// nothing integrated (detail: the tasks' titles). Not a finish.
                case landTasksNotDone
                /// C5c: the loop's pre-check found an open task (not `--green-ok`) whose check already passes at the
                /// paddock's HEAD: no attempt ran (detail: the tasks' titles). Not a finish.
                case checkAlreadyGreen
            public init(from d: Decoder) throws { self = Code(rawValue: try d.singleValueContainer().decode(String.self)) ?? .unknown }
        }
        public var code: Code; public var detail: String?
        public init(_ code: Code, detail: String? = nil) { self.code = code; self.detail = detail.map { String($0.prefix(200)) } }
        /// For the owner, short.
        public var label: String {
            switch code {
            case .requested: tr("pedido pelo dono (work stop)", "requested by the owner (work stop)")
            case .workGone: tr("trabalho fechado ou parado por fora", "work closed or stopped from outside")
            case .starterGone: tr("o Pastor que iniciou sumiu", "the Shepherd that started it is gone")
            case .maxReached: detail.map { tr("teto do auto-land atingido (\($0))", "auto-land cap reached (\($0))") } ?? tr("limite de tentativas (--max) atingido", "attempt limit (--max) reached")
            case .budgetSpent: tr("orçamento de tempo esgotado", "time budget spent")
            case .gitFailed: tr("git falhou", "git failed")
            case .dirtyTree: tr("arquivos rastreados modificados fora do laço", "tracked files modified outside the loop")
            case .othersWorking: tr("'\(detail ?? "outro terminal")' trabalhando no cercado", "'\(detail ?? "another terminal")' is working in the paddock")
            case .cancelled: tr("o daemon parou", "the daemon stopped")
            case .daemonRestart: tr("o daemon reiniciou durante o laço", "the daemon restarted during the loop")
            case .internal: tr("estado inesperado do motor (bug); a tarefa foi reaberta", "unexpected engine state (bug); the task was reopened")
            case .adoptionFailed: tr("a adoção do commit interrompido falhou; a árvore ficou intocada para você decidir", "adopting the interrupted commit failed; the tree was left untouched for you to decide")
            case .usageLimit: tr("o agente atingiu o limite de uso do modelo (\(detail ?? "sem texto")); relance com work run --model <outro>", "the agent hit the model usage limit (\(detail ?? "no text")); relaunch with work run --model <other>")
            case .landed: tr("integrado (auto-land, merge local; sem push)", "landed (auto-land, local merge; no push)") + (detail.map { ": \($0)" } ?? "")
            case .landGateRed: tr("auto-land: portão vermelho no HEAD do cercado; nada integrado", "auto-land: gate red at the paddock HEAD; nothing landed")
            case .landReviewVeto: tr("auto-land: revisão com veto ou sem parecer em \(detail ?? "uma tarefa"); nada integrado", "auto-land: review vetoed or missing for \(detail ?? "a task"); nothing landed")
            case .landCiRed: tr("auto-land: CI local vermelho; nada integrado", "auto-land: local CI red; nothing landed")
            case .landDirty: tr("auto-land: árvore suja ou outro agente trabalhando (\(detail ?? "cercado")); nada integrado", "auto-land: dirty tree or another agent working (\(detail ?? "paddock")); nothing landed")
            case .landConflict: tr("auto-land: o land (merge) falhou (\(detail ?? "conflito")); nada integrado", "auto-land: the land (merge) failed (\(detail ?? "conflict")); nothing landed")
            case .landNotFactory: tr("auto-land: o cercado não está marcado como fábrica; nada integrado", "auto-land: the paddock is not marked as a factory; nothing landed")
            case .queueEmpty: tr("auto-land: nenhum outro trabalho aprovado na fila do cercado", "auto-land: no other approved work in the paddock queue")
            case .landDailyCap: tr("auto-land: teto diário do cercado atingido (\(detail ?? "factory.guardrails.autoLandPerDay")); chame o dono", "auto-land: paddock daily cap reached (\(detail ?? "factory.guardrails.autoLandPerDay")); call the owner")
            case .landAcceptRed: tr("auto-land: aceite em runtime sem passar em \(detail ?? "uma tarefa"); nada integrado", "auto-land: runtime acceptance not passing for \(detail ?? "a task"); nothing landed")
            case .landNothing: tr("auto-land: nada a integrar (o cercado não tem commits novos ou já foi integrado)", "auto-land: nothing to land (the paddock has no new commits or was already landed)")
            case .landBaseMoved: tr("auto-land: a base mudou desde o início da tentativa (\(detail ?? "base")); nada integrado; refaça sobre a base nova", "auto-land: the base moved since the attempt began (\(detail ?? "base")); nothing landed; redo it on the new base")
            case .landRegistryFailed: tr("auto-land: merge feito, mas o registro do teto diário não foi gravado (\(detail ?? "erro de gravação")); o laço parou; chame o dono", "auto-land: merge done, but the daily cap record was not written (\(detail ?? "write error")); the loop stopped; call the owner")
            case .landTasksNotDone: tr("auto-land: tarefa(s) não feitas (\(detail ?? "alguma tarefa")); nada integrado", "auto-land: task(s) not done (\(detail ?? "some task")); nothing landed")
            case .landDoctorRegressed: tr("auto-land: o factory doctor do cercado não passa mais o mínimo (\(detail ?? "static e judge ≥ 1")); a corrente parou", "auto-land: the paddock's factory doctor no longer meets the minimum (\(detail ?? "static and judge ≥ 1")); the chain stopped")
            case .checkAlreadyGreen: tr("o check já passa antes da tarefa (\(detail ?? "uma tarefa")); nenhuma tentativa; reescreva o check ou marque --green-ok", "the check already passes before the task (\(detail ?? "a task")); no attempt made; rewrite the check or mark --green-ok")
            case .unknown: tr("motivo desconhecido", "unknown reason")
            }
        }
        /// The note every stopped loop leaves (A4: a landed one is no stop).
        /// A5: nor is the end of a chain (`queueEmpty`, `maxReached` of the auto-land).
        public var note: String { finishes ? tr("[loop] laço terminou: \(label)", "[loop] loop finished: \(label)") : tr("[loop] laço parado: \(label)", "[loop] loop stopped: \(label)") }
        /// A4/A5: the codes a loop `finished` with (a land made, nothing failed).
        public var finishes: Bool { Self.finishes(code: code.rawValue, detail: detail) }
        /// The one rule of "finished" over a stop's two raw fields (the app's history rows have only those): `landed`,
        /// `queueEmpty`, and `maxReached` with a detail (only the auto-land's chain gives it one).
        public static func finishes(code: String?, detail: String?) -> Bool {
            switch code.flatMap(Code.init(rawValue:)) {
            case .landed?, .queueEmpty?: true
            case .maxReached?: detail != nil
            default: false
            }
        }
    }
    /// Set when the loop ends `stopped`; nil while it runs and when it `finished`.
    public var stopReason: Stop?
    /// A4, `work run --auto-land`: what the land runs, all from the profile committed at the loop's base: its `gate`,
    /// the local CI (`factory.autoland.ci`, else `scripts/ci/run-tests.sh`) and its timeout (seconds). `before`/`after`:
    /// the base branch's commit before and after the land (nil: no land yet). nil: no auto-land (the loop as before).
    public struct AutoLand: Codable, Sendable, Equatable {
        public static let defaultCI = "scripts/ci/run-tests.sh", defaultTimeout = 1800
        public var gate: String; public var ci: String; public var timeout: Int
        public var before: String?, after: String?
        /// A6: the absolute path of the run's summary (`<daemon root>/work-loops/<work>/autoland/<stamp>.md`, 0444);
        /// nil: none written yet.
        public var summary: String?
        /// A5: `--auto-land-max` (nil: 1, at most `maxMax`), `factory.guardrails.autoLandPerDay` (nil: 3) and the lands
        /// earlier works of the same execution made (nil: none; carried to the next work the chain activates).
        public static let maxMax = 5, defaultPerDay = 3
        public var max: Int?, perDay: Int?, chained: Int?
        /// C3b: when the owner approved the queued work (its card answered, or the trusted paddock's `work run`): the
        /// queue's order, oldest approval first. nil: a loop from before (its `startedAt` stands in).
        public var approvedAt: Date?
        /// C3b: `work stop` took the approved work out of the queue: the loop stays `queued` (not terminal) and
        /// `approvedAt` stays, but no chain activates it while this is set; the work's next `work run` makes a new loop
        /// (none set: back in the queue). nil: in the queue.
        public var dequeuedAt: Date?
        /// C3b: the base branch's commit when the last attempt of a task began (what the agent worked on): the land
        /// needs the base to be exactly this. Written only at an attempt's start (never with nil over a value), carried
        /// to the work's next `work run`, taken again when a chain activates the work. nil: unknown, the land fails closed.
        public var baseHead: String?
        /// C5c: the paddock's HEAD when the work began (`work run`, or the engine's start when unknown): a land that does
        /// not integrate resets the paddock back to it. Carried to the work's next `work run` only when that loop did not
        /// land; cleared by a land that integrated. nil: unknown (the engine takes HEAD when it starts).
        public var startHead: String?
        public init(gate: String, ci: String = defaultCI, timeout: Int = defaultTimeout, max: Int? = nil, perDay: Int? = nil) {
            self.gate = gate; self.ci = ci; self.timeout = timeout; self.max = max; self.perDay = perDay
        }
    }
    public var autoLand: AutoLand?
    /// The loop's journal, oldest first: a ring of the `eventsMax` newest (`record`). nil: none yet, or a loop written
    /// before the journal existed. A new `work run` is a new `WorkLoopState`: it starts empty.
    public var events: [LoopEvent]?
    public static let eventsMax = 100
    /// M6.4: the ring while the work is closed under its running loop: the summary written when the loop ends keeps
    /// up to `WorkArchive.timelineMax` of them, and twice that lets it count what it cut (`truncated`).
    public static let closedEventsMax = 2 * WorkArchive.timelineMax
    /// Adds `e` to the journal; past `max`, the oldest go. A work's loop records through `Work.record`.
    public mutating func record(_ e: LoopEvent, max: Int = eventsMax) { events = Array(((events ?? []) + [e]).suffix(max)) }
    /// M3.5, `work run --parallel N`: how many tasks may run at once, each in its lane. nil or 1: one at a time, in the
    /// paddock's worktree, as always.
    public var parallel: Int?
    /// M3c.4, `work run --notify task|end`: `task` (or nil, a loop from before): the Shepherd hears of every task as
    /// it ends, as always. `end`: not of a task done (each notice wakes a turn); a deferred task, a stop and the end
    /// still reach it.
    public enum Notify: String, Codable, Sendable, CaseIterable { case task, end }
    public var notify: Notify?
    /// M3.5: one lane of a parallel loop: its folder's name, the `task` and `attempt` running in it, its `phase` (nil:
    /// between phases, or being integrated with no gate) and `since` when that phase holds.
    public struct LaneState: Codable, Sendable, Equatable {
        public var lane: String; public var task: String; public var attempt: Int?; public var phase: Phase?; public var since: Date
        /// M3b.4: when the lane began. `since` moves with every phase, so it cannot say how long the lane has run.
        /// nil (a file from before): `since` stands in.
        public var started: Date?
        public init(lane: String, task: String, attempt: Int? = nil, phase: Phase? = nil, since: Date = Date(), started: Date? = nil) {
            self.lane = lane; self.task = task; self.attempt = attempt; self.phase = phase; self.since = since; self.started = started
        }
        /// A phase or an attempt this daemon cannot read is nil: the lane still decodes.
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            lane = try c.decode(String.self, forKey: .lane); task = try c.decode(String.self, forKey: .task)
            since = try c.decode(Date.self, forKey: .since)
            attempt = (try? c.decodeIfPresent(Int.self, forKey: .attempt)) ?? nil
            phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? nil
            started = (try? c.decodeIfPresent(Date.self, forKey: .started)) ?? nil
        }
    }
    /// M3.5: the lanes running now, oldest first; nil: none (always, without `--parallel`).
    public var lanes: [LaneState]?
    /// Sets the phase of `lane` (an unknown lane: nothing), then `mirror`.
    public mutating func showLane(_ lane: String, _ p: Phase?, at: Date = Date()) {
        if let i = lanes?.firstIndex(where: { $0.lane == lane }), lanes?[i].phase != p { lanes?[i].phase = p; lanes?[i].since = at }
        mirror()
    }
    /// For the readers that know one phase only: `task`, `attempt` and `phase` are the oldest lane's (none: no phase).
    public mutating func mirror() {
        guard let first = lanes?.first else { task = nil; show(nil); return }
        task = first.task; attempt = first.attempt ?? attempt
        phase = first.phase; phaseSince = first.phase == nil ? nil : first.since
    }
    public var startedAt: Date; public var endedAt: Date?
    public init(state: State = .running, task: String? = nil, attempt: Int = 0, tries: Int = 3, timeout: Int = 3600,
                preset: String? = nil, model: String? = nil, command: String? = nil, max: Int? = nil, used: Int = 0,
                budget: Int? = nil, spent: Int? = nil, tasks: [String]? = nil, gate: String? = nil, phase: Phase? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil, parallel: Int? = nil, notify: Notify? = nil, precheck: String? = nil,
                review: Bool? = nil, personas: [String]? = nil, reviewerModel: String? = nil, escalate: [String]? = nil) {
        self.escalate = escalate
        self.parallel = parallel; self.notify = notify; self.precheck = precheck
        self.review = review; self.personas = personas; self.reviewerModel = reviewerModel
        self.state = state; self.task = task; self.attempt = attempt; self.tries = tries; self.timeout = timeout
        self.preset = preset; self.model = model; self.command = command; self.max = max; self.used = used
        self.budget = budget; self.spent = spent; self.tasks = tasks; self.gate = gate; self.phase = phase
        self.startedAt = startedAt; self.endedAt = endedAt
    }
    /// The older fields decode as always (a required one missing, or one of the wrong shape, is no loop). The newer
    /// ones (`phase`, `phaseSince`, `stopReason`, `events`, `parallel`, `lanes`, `notify`, `precheck`) only record: a malformed one is nil, a malformed event is dropped, and
    /// the loop survives. What is written (the synthesized `encode`) does not change.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state); task = try c.decodeIfPresent(String.self, forKey: .task)
        attempt = try c.decode(Int.self, forKey: .attempt)
        tries = try c.decode(Int.self, forKey: .tries); timeout = try c.decode(Int.self, forKey: .timeout)
        preset = try c.decodeIfPresent(String.self, forKey: .preset); model = try c.decodeIfPresent(String.self, forKey: .model)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        max = try c.decodeIfPresent(Int.self, forKey: .max); used = try c.decode(Int.self, forKey: .used)
        budget = try c.decodeIfPresent(Int.self, forKey: .budget); spent = try c.decodeIfPresent(Int.self, forKey: .spent)
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks); gate = try c.decodeIfPresent(String.self, forKey: .gate)
        startedAt = try c.decode(Date.self, forKey: .startedAt); endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? nil
        phaseSince = (try? c.decodeIfPresent(Date.self, forKey: .phaseSince)) ?? nil
        stopReason = (try? c.decodeIfPresent(Stop.self, forKey: .stopReason)) ?? nil
        events = ((try? c.decodeIfPresent([Lossy].self, forKey: .events)) ?? nil)?.compactMap(\.event)
        parallel = (try? c.decodeIfPresent(Int.self, forKey: .parallel)) ?? nil
        lanes = (try? c.decodeIfPresent([LaneState].self, forKey: .lanes)) ?? nil
        notify = (try? c.decodeIfPresent(Notify.self, forKey: .notify)) ?? nil
        precheck = (try? c.decodeIfPresent(String.self, forKey: .precheck)) ?? nil
        greenPreCheck = (try? c.decodeIfPresent(Bool.self, forKey: .greenPreCheck)) ?? nil   // C5c: tolerant too
        escalate = (try? c.decodeIfPresent([String].self, forKey: .escalate)) ?? nil
        review = (try? c.decodeIfPresent(Bool.self, forKey: .review)) ?? nil   // F2 R1: tolerant, like the newer ones
        personas = (try? c.decodeIfPresent([String].self, forKey: .personas)) ?? nil
        reviewerModel = (try? c.decodeIfPresent(String.self, forKey: .reviewerModel)) ?? nil
        reviewOnly = (try? c.decodeIfPresent([String].self, forKey: .reviewOnly)) ?? nil   // A1: tolerant too
        reviewThreshold = (try? c.decodeIfPresent(String.self, forKey: .reviewThreshold)) ?? nil
        origins = (try? c.decodeIfPresent([String: String].self, forKey: .origins)) ?? nil
        destructive = (try? c.decodeIfPresent(Int.self, forKey: .destructive)) ?? nil
        autoLand = (try? c.decodeIfPresent(AutoLand.self, forKey: .autoLand)) ?? nil   // A4: tolerant too
        bins = (try? c.decodeIfPresent([String].self, forKey: .bins)) ?? nil   // R1: tolerant too
    }
    /// One element of `events`: nil when malformed, so the list still decodes.
    private struct Lossy: Decodable {
        let event: LoopEvent?
        init(from d: Decoder) { event = try? LoopEvent(from: d) }
    }
}

/// `loop`: an attempt of `collie work run`, ended only by the loop (never by the job sweeps).
public enum JobKind: String, Codable, Sendable { case subagent, shell, loop }
public enum JobState: String, Codable, Sendable { case running, finished, gone, unknown }

/// A subagent or background shell. `id` is the tool_use_id; `alias`: the agent's own id for a background subagent
/// (SubagentStop and TaskOutput/TaskStop name it); `result` is at most 280 characters.
public struct WorkJob: Codable, Sendable, Equatable {
    public var id: String; public var kind: JobKind; public var label: String; public var state: JobState
    public var startedAt: Date; public var endedAt: Date?; public var result: String?; public var pid: Int32?; public var alias: String?
    /// M3.8, a loop's attempt (`kind == .loop`, `id` its agent's name): the id of the terminal the loop summoned for
    /// it. It is how the loop's agent is recognised (the start sweep), never its name. nil: none was summoned, or the
    /// work was written before this field.
    public var terminal: UUID?
    public init(id: String, kind: JobKind, label: String, state: JobState = .running, startedAt: Date = Date(),
                endedAt: Date? = nil, result: String? = nil, pid: Int32? = nil, alias: String? = nil, terminal: UUID? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.state = state; self.startedAt = startedAt
        self.endedAt = endedAt; self.result = result; self.pid = pid; self.alias = alias; self.terminal = terminal
    }
    /// As the synthesized one, but a `terminal` this daemon cannot read is nil: the job (and its work) still decodes.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); kind = try c.decode(JobKind.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label); state = try c.decode(JobState.self, forKey: .state)
        startedAt = try c.decode(Date.self, forKey: .startedAt); endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        result = try c.decodeIfPresent(String.self, forKey: .result); pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        terminal = (try? c.decodeIfPresent(UUID.self, forKey: .terminal)) ?? nil
    }
}

public struct WorkNote: Codable, Sendable, Equatable {
    public var at: Date; public var text: String; public var decision: Bool
    public init(at: Date = Date(), text: String, decision: Bool = false) { self.at = at; self.text = text; self.decision = decision }
}

/// What a terminal's agent is doing: tasks, jobs, notes and commits. `closedBy`: "merge", "agent:<name>" or "app".
/// `commits`: short sha and subject, at most 200. `capturedAt`/`capturedCommit`: when Claude's Stop last asked about its
/// learnings (MemoryCapture) and the newest commit then; `proposedAt`/`proposedCommit`: the same for the proposals
/// written from it. What came after each is that one's next chunk. `askedAt` (M5.2): when the Stop last really asked
/// (`capturedAt` also moves when it did not); nil: never, or a work from before.
public struct Work: Codable, Sendable, Equatable {
    public var id: UUID; public var title: String; public var terminalId: UUID; public var paddockId: UUID?; public var branch: String?
    public var openedAt: Date; public var closedAt: Date?; public var closedBy: String?
    public var tasks: [WorkTask]; public var jobs: [WorkJob]; public var notes: [WorkNote]; public var commits: [String]
    public var capturedAt: Date?; public var capturedCommit: String?; public var askedAt: Date?
    public var proposedAt: Date?; public var proposedCommit: String?
    /// The lot its terminal was in when it closed (nil: none, or unknown): a lot's works never feed project learning.
    public var lotId: UUID?
    /// Set while (and after) `collie work run` runs it; nil = a sequential work.
    public var loop: WorkLoopState?
    /// How many times the store wrote a change of this work (`WorkStore`: +1 per write that changes it; kept on disk,
    /// so it never goes back across a daemon restart). `work wait --since` waits for it to pass a value. nil: never
    /// written by a store that counts.
    public var version: Int?
    /// F5: the PRDs kept for this work (`collie work prd add`), oldest first: the last is the current one, the ones
    /// before it were replaced (`--replace`; their files stay). nil: none.
    public var prd: [WorkPrd]?
    /// F5: the plan package applied to it (`collie work plan apply`). nil: none.
    public var plan: WorkPlan?
    public init(id: UUID = UUID(), title: String, terminalId: UUID, paddockId: UUID? = nil, branch: String? = nil, openedAt: Date = Date(),
                closedAt: Date? = nil, closedBy: String? = nil, tasks: [WorkTask] = [], jobs: [WorkJob] = [], notes: [WorkNote] = [],
                commits: [String] = []) {
        self.id = id; self.title = title; self.terminalId = terminalId; self.paddockId = paddockId; self.branch = branch
        self.openedAt = openedAt; self.closedAt = closedAt; self.closedBy = closedBy
        self.tasks = tasks; self.jobs = jobs; self.notes = notes; self.commits = commits
    }
    private enum CodingKeys: String, CodingKey { case id, title, terminalId, paddockId, branch, openedAt, closedAt, closedBy, tasks, jobs, notes, commits, capturedAt, capturedCommit, askedAt, proposedAt, proposedCommit, lotId, loop, version, prd, plan }
    private enum Legacy: String, CodingKey { case floorId }   // before the herding vocabulary
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        terminalId = try c.decode(UUID.self, forKey: .terminalId)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? d.container(keyedBy: Legacy.self).decodeIfPresent(UUID.self, forKey: .floorId)
        branch = try c.decodeIfPresent(String.self, forKey: .branch); openedAt = try c.decode(Date.self, forKey: .openedAt)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt); closedBy = try c.decodeIfPresent(String.self, forKey: .closedBy)
        tasks = try c.decode([WorkTask].self, forKey: .tasks); jobs = try c.decode([WorkJob].self, forKey: .jobs)
        notes = try c.decode([WorkNote].self, forKey: .notes); commits = try c.decode([String].self, forKey: .commits)
        // R2: a malformed capture mark only means "never captured"
        capturedAt = (try? c.decodeIfPresent(Date.self, forKey: .capturedAt)) ?? nil
        capturedCommit = (try? c.decodeIfPresent(String.self, forKey: .capturedCommit)) ?? nil
        askedAt = (try? c.decodeIfPresent(Date.self, forKey: .askedAt)) ?? nil
        proposedAt = (try? c.decodeIfPresent(Date.self, forKey: .proposedAt)) ?? nil
        proposedCommit = (try? c.decodeIfPresent(String.self, forKey: .proposedCommit)) ?? nil
        lotId = (try? c.decodeIfPresent(UUID.self, forKey: .lotId)) ?? nil
        loop = (try? c.decodeIfPresent(WorkLoopState.self, forKey: .loop)) ?? nil   // malformed = no loop
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil
        prd = (try? c.decodeIfPresent([WorkPrd].self, forKey: .prd)) ?? nil   // F5: tolerant, like the newer ones
        plan = (try? c.decodeIfPresent(WorkPlan.self, forKey: .plan)) ?? nil
    }
}

/// F5: a PRD kept for a work: the markdown the owner's CLI read, immutable in the work's own folder
/// (`<root>/work-loops/<work>/prd/<sha256>.md`, 0444). `origin`: where it came from, opaque text (never fetched).
public struct WorkPrd: Codable, Sendable, Equatable {
    public var sha256: String; public var origin: String?; public var addedAt: Date; public var bytes: Int
    public init(sha256: String, origin: String? = nil, addedAt: Date = Date(), bytes: Int) {
        self.sha256 = sha256; self.origin = origin; self.addedAt = addedAt; self.bytes = bytes
    }
}

/// F5: the plan package (`waves.md`, `tasks/*.md`) applied to a work: its folder, the sha256 the owner approved and
/// the ids of the tasks it created. `work run` lints the folder again and refuses when its hash is no longer this one.
public struct WorkPlan: Codable, Sendable, Equatable {
    public var dir: String; public var sha256: String; public var appliedAt: Date; public var tasks: [String]
    public init(dir: String, sha256: String, appliedAt: Date = Date(), tasks: [String]) {
        self.dir = dir; self.sha256 = sha256; self.appliedAt = appliedAt; self.tasks = tasks
    }
}

extension Work {
    /// M6.4: one event in the loop's journal: a ring of `eventsMax`, or of `closedEventsMax` once the work is closed
    /// (its loop may still run: `WorkStore` keeps the journal whole until the loop ends and the summary is written).
    public mutating func record(_ e: LoopEvent) {
        loop?.record(e, max: closedAt != nil ? WorkLoopState.closedEventsMax : WorkLoopState.eventsMax)
    }
}
