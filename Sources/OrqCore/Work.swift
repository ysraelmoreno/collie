import Foundation

public enum TaskState: String, Codable, Sendable { case open, inProgress, done, deferred, abandoned }

/// One task of a work: `id` is the agent's own, else generated.
public struct WorkTask: Codable, Sendable, Equatable {
    public var id: String; public var title: String; public var state: TaskState; public var reason: String?; public var updatedAt: Date
    public init(id: String, title: String, state: TaskState = .open, reason: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.state = state; self.reason = reason; self.updatedAt = updatedAt
    }
}

public enum JobKind: String, Codable, Sendable { case subagent, shell }
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
/// `commits`: short sha and subject, at most 200.
public struct Work: Codable, Sendable, Equatable {
    public var id: UUID; public var title: String; public var terminalId: UUID; public var floorId: UUID?; public var branch: String?
    public var openedAt: Date; public var closedAt: Date?; public var closedBy: String?
    public var tasks: [WorkTask]; public var jobs: [WorkJob]; public var notes: [WorkNote]; public var commits: [String]
    public init(id: UUID = UUID(), title: String, terminalId: UUID, floorId: UUID? = nil, branch: String? = nil, openedAt: Date = Date(),
                closedAt: Date? = nil, closedBy: String? = nil, tasks: [WorkTask] = [], jobs: [WorkJob] = [], notes: [WorkNote] = [],
                commits: [String] = []) {
        self.id = id; self.title = title; self.terminalId = terminalId; self.floorId = floorId; self.branch = branch
        self.openedAt = openedAt; self.closedAt = closedAt; self.closedBy = closedBy
        self.tasks = tasks; self.jobs = jobs; self.notes = notes; self.commits = commits
    }
}
