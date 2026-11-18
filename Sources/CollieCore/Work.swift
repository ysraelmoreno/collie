import Foundation

public enum TaskState: String, Codable, Sendable { case open, inProgress, done, deferred, abandoned }

/// One task of a work: `id` is the agent's own, else generated. `spec` (absolute path of a Markdown file) and `check`
/// (a shell command, exit 0 = passes) matter only to `collie work run`; `tries` is the attempts a loop used and
/// `lastFailure` one line on why the last one failed.
public struct WorkTask: Codable, Sendable, Equatable {
    public var id: String; public var title: String; public var state: TaskState; public var reason: String?; public var updatedAt: Date
    public var spec: String?; public var check: String?; public var tries: Int?; public var lastFailure: String?
    public init(id: String, title: String, state: TaskState = .open, reason: String? = nil, updatedAt: Date = Date(),
                spec: String? = nil, check: String? = nil, tries: Int? = nil, lastFailure: String? = nil) {
        self.id = id; self.title = title; self.state = state; self.reason = reason; self.updatedAt = updatedAt
        self.spec = spec; self.check = check; self.tries = tries; self.lastFailure = lastFailure
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
    public var startedAt: Date; public var endedAt: Date?
    public init(state: State = .running, task: String? = nil, attempt: Int = 0, tries: Int = 3, timeout: Int = 3600,
                preset: String? = nil, model: String? = nil, command: String? = nil, max: Int? = nil, used: Int = 0,
                budget: Int? = nil, spent: Int? = nil, tasks: [String]? = nil, gate: String? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil) {
        self.state = state; self.task = task; self.attempt = attempt; self.tries = tries; self.timeout = timeout
        self.preset = preset; self.model = model; self.command = command; self.max = max; self.used = used
        self.budget = budget; self.spent = spent; self.tasks = tasks; self.gate = gate
        self.startedAt = startedAt; self.endedAt = endedAt
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
    public init(id: UUID = UUID(), title: String, terminalId: UUID, paddockId: UUID? = nil, branch: String? = nil, openedAt: Date = Date(),
                closedAt: Date? = nil, closedBy: String? = nil, tasks: [WorkTask] = [], jobs: [WorkJob] = [], notes: [WorkNote] = [],
                commits: [String] = []) {
        self.id = id; self.title = title; self.terminalId = terminalId; self.paddockId = paddockId; self.branch = branch
        self.openedAt = openedAt; self.closedAt = closedAt; self.closedBy = closedBy
        self.tasks = tasks; self.jobs = jobs; self.notes = notes; self.commits = commits
    }
    private enum CodingKeys: String, CodingKey { case id, title, terminalId, paddockId, branch, openedAt, closedAt, closedBy, tasks, jobs, notes, commits, capturedAt, capturedCommit, proposedAt, proposedCommit, lotId, loop }
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
    }
}
