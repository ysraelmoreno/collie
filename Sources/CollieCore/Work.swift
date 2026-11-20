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
    /// M2.2a: set while an attempt of the loop runs: the HEAD sha it started from and the branch it ran on. Cleared when
    /// the attempt ends; a daemon that fell mid-attempt leaves them, and the next run may adopt the commit already made.
    /// Read back from the work's file: never trusted as a git argument before `WorkLoop.isSha`.
    public var resumeFrom: String?; public var resumeBranch: String?
    /// M2b.1: when the attempt was left (the daemon's stop, or the start sweep that found it): only commits made up to
    /// then can be the fallen attempt's. nil while the attempt runs; without it nothing is adopted.
    public var resumeAt: Date?
    /// M2b.1: nothing to resume: the three go together.
    public mutating func forgetResume() { resumeFrom = nil; resumeBranch = nil; resumeAt = nil }
    public init(id: String, title: String, state: TaskState = .open, reason: String? = nil, updatedAt: Date = Date(),
                spec: String? = nil, check: String? = nil, tries: Int? = nil, lastFailure: String? = nil,
                evidence: TaskEvidence? = nil, evidenceGlob: String? = nil, needs: [String]? = nil, scope: [String]? = nil) {
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
        public init(from d: Decoder) throws { self = Kind(rawValue: try d.singleValueContainer().decode(String.self)) ?? .unknown }
    }
    public static let detailMax = 200
    public var at: Date; public var kind: Kind; public var task: String?; public var attempt: Int?; public var detail: String?
    /// M3.5: the lane the event happened in (its folder's name); nil: the paddock's worktree (always, without `--parallel`).
    public var lane: String?
    public init(at: Date = Date(), kind: Kind, task: String? = nil, attempt: Int? = nil, detail: String? = nil, lane: String? = nil) {
        self.at = at; self.kind = kind; self.task = task; self.attempt = attempt; self.lane = lane
        self.detail = detail.map { String($0.prefix(Self.detailMax)) }
    }
}

/// A work run by `collie work run`: `task` is the current task's id, `attempt` (1-based) its attempt; `tries` and
/// `timeout` (seconds, a turn) are per task; `max` caps and `used` counts attempts across tasks; `budget` caps and
/// `spent` counts the seconds of all attempts (turns and checks); `tasks`: the ids the owner approved (a task added
/// later waits for the next run; nil: every open task); `gate`: a command run after every task's check, in the same
/// conditions, that must also exit 0 (nil: none).
public struct WorkLoopState: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, stopped, finished }
    public var state: State
    public var task: String?
    public var attempt: Int
    public var tries: Int; public var timeout: Int
    public var preset: String?; public var model: String?; public var command: String?
    public var max: Int?; public var used: Int
    public var budget: Int?; public var spent: Int?; public var tasks: [String]?
    public var gate: String?
    /// What a running loop is doing right now: its terminal is only open during `agent`, so without this a loop in its
    /// check or gate looks idle (no terminal, no signal).
    public enum Phase: String, Codable, Sendable {
        case agent, check, gate
        public var label: String { switch self { case .agent: "agente trabalhando"; case .check: "rodando o check"; case .gate: "rodando o portão" } }
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
            public init(from d: Decoder) throws { self = Code(rawValue: try d.singleValueContainer().decode(String.self)) ?? .unknown }
        }
        public var code: Code; public var detail: String?
        public init(_ code: Code, detail: String? = nil) { self.code = code; self.detail = detail.map { String($0.prefix(200)) } }
        /// For the owner, short.
        public var label: String {
            switch code {
            case .requested: "pedido pelo dono (work stop)"
            case .workGone: "trabalho fechado ou parado por fora"
            case .starterGone: "o Pastor que iniciou sumiu"
            case .maxReached: "limite de tentativas (--max) atingido"
            case .budgetSpent: "orçamento de tempo esgotado"
            case .gitFailed: "git falhou"
            case .dirtyTree: "arquivos rastreados modificados fora do laço"
            case .othersWorking: "'\(detail ?? "outro terminal")' trabalhando no cercado"
            case .cancelled: "o daemon parou"
            case .daemonRestart: "o daemon reiniciou durante o laço"
            case .internal: "estado inesperado do motor (bug); a tarefa foi reaberta"
            case .adoptionFailed: "a adoção do commit interrompido falhou; a árvore ficou intocada para você decidir"
            case .unknown: "motivo desconhecido"
            }
        }
        /// The note every stopped loop leaves.
        public var note: String { "[loop] laço parado: \(label)" }
    }
    /// Set when the loop ends `stopped`; nil while it runs and when it `finished`.
    public var stopReason: Stop?
    /// The loop's journal, oldest first: a ring of the `eventsMax` newest (`record`). nil: none yet, or a loop written
    /// before the journal existed. A new `work run` is a new `WorkLoopState`: it starts empty.
    public var events: [LoopEvent]?
    public static let eventsMax = 100
    /// Adds `e` to the journal; past `eventsMax`, the oldest go.
    public mutating func record(_ e: LoopEvent) { events = Array(((events ?? []) + [e]).suffix(Self.eventsMax)) }
    /// M3.5, `work run --parallel N`: how many tasks may run at once, each in its lane. nil or 1: one at a time, in the
    /// paddock's worktree, as always.
    public var parallel: Int?
    /// M3.5: one lane of a parallel loop: its folder's name, the `task` and `attempt` running in it, its `phase` (nil:
    /// between phases, or being integrated with no gate) and `since` when that phase holds.
    public struct LaneState: Codable, Sendable, Equatable {
        public var lane: String; public var task: String; public var attempt: Int?; public var phase: Phase?; public var since: Date
        public init(lane: String, task: String, attempt: Int? = nil, phase: Phase? = nil, since: Date = Date()) {
            self.lane = lane; self.task = task; self.attempt = attempt; self.phase = phase; self.since = since
        }
        /// A phase or an attempt this daemon cannot read is nil: the lane still decodes.
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            lane = try c.decode(String.self, forKey: .lane); task = try c.decode(String.self, forKey: .task)
            since = try c.decode(Date.self, forKey: .since)
            attempt = (try? c.decodeIfPresent(Int.self, forKey: .attempt)) ?? nil
            phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? nil
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
                startedAt: Date = Date(), endedAt: Date? = nil, parallel: Int? = nil) {
        self.parallel = parallel
        self.state = state; self.task = task; self.attempt = attempt; self.tries = tries; self.timeout = timeout
        self.preset = preset; self.model = model; self.command = command; self.max = max; self.used = used
        self.budget = budget; self.spent = spent; self.tasks = tasks; self.gate = gate; self.phase = phase
        self.startedAt = startedAt; self.endedAt = endedAt
    }
    /// The older fields decode as always (a required one missing, or one of the wrong shape, is no loop). The newer
    /// ones (`phase`, `phaseSince`, `stopReason`, `events`, `parallel`, `lanes`) only record: a malformed one is nil, a malformed event is dropped, and
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
    public init(id: String, kind: JobKind, label: String, state: JobState = .running, startedAt: Date = Date(),
                endedAt: Date? = nil, result: String? = nil, pid: Int32? = nil, alias: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.state = state; self.startedAt = startedAt
        self.endedAt = endedAt; self.result = result; self.pid = pid; self.alias = alias
    }
}

public struct WorkNote: Codable, Sendable, Equatable {
    public var at: Date; public var text: String; public var decision: Bool
    public init(at: Date = Date(), text: String, decision: Bool = false) { self.at = at; self.text = text; self.decision = decision }
}

/// What a terminal's agent is doing: tasks, jobs, notes and commits. `closedBy`: "merge", "agent:<name>" or "app".
/// `commits`: short sha and subject, at most 200. `capturedAt`/`capturedCommit`: when Claude's Stop last asked about its
/// learnings (MemoryCapture) and the newest commit then; `proposedAt`/`proposedCommit`: the same for the proposals
/// written from it. What came after each is that one's next chunk.
public struct Work: Codable, Sendable, Equatable {
    public var id: UUID; public var title: String; public var terminalId: UUID; public var paddockId: UUID?; public var branch: String?
    public var openedAt: Date; public var closedAt: Date?; public var closedBy: String?
    public var tasks: [WorkTask]; public var jobs: [WorkJob]; public var notes: [WorkNote]; public var commits: [String]
    public var capturedAt: Date?; public var capturedCommit: String?
    public var proposedAt: Date?; public var proposedCommit: String?
    /// The lot its terminal was in when it closed (nil: none, or unknown): a lot's works never feed project learning.
    public var lotId: UUID?
    /// Set while (and after) `collie work run` runs it; nil = a sequential work.
    public var loop: WorkLoopState?
    /// How many times the store wrote a change of this work (`WorkStore`: +1 per write that changes it; kept on disk,
    /// so it never goes back across a daemon restart). `work wait --since` waits for it to pass a value. nil: never
    /// written by a store that counts.
    public var version: Int?
    public init(id: UUID = UUID(), title: String, terminalId: UUID, paddockId: UUID? = nil, branch: String? = nil, openedAt: Date = Date(),
                closedAt: Date? = nil, closedBy: String? = nil, tasks: [WorkTask] = [], jobs: [WorkJob] = [], notes: [WorkNote] = [],
                commits: [String] = []) {
        self.id = id; self.title = title; self.terminalId = terminalId; self.paddockId = paddockId; self.branch = branch
        self.openedAt = openedAt; self.closedAt = closedAt; self.closedBy = closedBy
        self.tasks = tasks; self.jobs = jobs; self.notes = notes; self.commits = commits
    }
    private enum CodingKeys: String, CodingKey { case id, title, terminalId, paddockId, branch, openedAt, closedAt, closedBy, tasks, jobs, notes, commits, capturedAt, capturedCommit, proposedAt, proposedCommit, lotId, loop, version }
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
        proposedAt = (try? c.decodeIfPresent(Date.self, forKey: .proposedAt)) ?? nil
        proposedCommit = (try? c.decodeIfPresent(String.self, forKey: .proposedCommit)) ?? nil
        lotId = (try? c.decodeIfPresent(UUID.self, forKey: .lotId)) ?? nil
        loop = (try? c.decodeIfPresent(WorkLoopState.self, forKey: .loop)) ?? nil   // malformed = no loop
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil
    }
}
