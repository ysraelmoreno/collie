import Foundation

/// A closed work's immutable summary (`work.history --id`). Decoding is tolerant: a field that is missing or has the
/// wrong type becomes its empty value, never an error. Text comes from the work as it is; whoever renders it escapes it.
/// ponytail: the T6.1 daemon side (writing, retention) lands separately; this is the shape the app reads.
public struct WorkArchive: Codable, Sendable, Equatable {
    public struct Task: Codable, Sendable, Equatable {
        public var id: String, title: String, state: String, tries: Int
        public var failure: String?, evidenceNote: String?
        public var commits: [String]
        public init(id: String = "", title: String = "", state: String = "", tries: Int = 0, failure: String? = nil,
                    commits: [String] = [], evidenceNote: String? = nil) {
            self.id = id; self.title = title; self.state = state; self.tries = tries; self.failure = failure
            self.commits = commits; self.evidenceNote = evidenceNote
        }
        private enum K: String, CodingKey { case id, title, state, tries, failure, commits, evidenceNote }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""; title = (try? c.decode(String.self, forKey: .title)) ?? ""
            state = (try? c.decode(String.self, forKey: .state)) ?? ""; tries = (try? c.decode(Int.self, forKey: .tries)) ?? 0
            failure = try? c.decode(String.self, forKey: .failure); evidenceNote = try? c.decode(String.self, forKey: .evidenceNote)
            commits = (try? c.decode([String].self, forKey: .commits)) ?? []
        }
    }
    public struct Event: Codable, Sendable, Equatable {
        public var at: Date?, task: String?, kind: String, detail: String
        public init(at: Date? = nil, task: String? = nil, kind: String = "", detail: String = "") {
            self.at = at; self.task = task; self.kind = kind; self.detail = detail
        }
        private enum K: String, CodingKey { case at, task, kind, detail }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            at = try? c.decode(Date.self, forKey: .at); task = try? c.decode(String.self, forKey: .task)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""; detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        }
    }
    public var version: Int
    public var id: String, title: String, paddock: String, branch: String, terminal: String
    public var openedAt: Date?, closedAt: Date?
    /// The daemon's raw stop code (`Stop.Code`), kept as text so a newer code is still shown.
    public var stopReason: String?
    public var tasks: [Task], timeline: [Event], notes: [String]
    public var loopSummary: String
    public var reconstructed: Bool, truncated: Bool

    public init(id: String, title: String = "", paddock: String = "", branch: String = "", terminal: String = "",
                openedAt: Date? = nil, closedAt: Date? = nil, stopReason: String? = nil, tasks: [Task] = [],
                timeline: [Event] = [], notes: [String] = [], loopSummary: String = "", reconstructed: Bool = false, truncated: Bool = false) {
        version = 1; self.id = id; self.title = title; self.paddock = paddock; self.branch = branch; self.terminal = terminal
        self.openedAt = openedAt; self.closedAt = closedAt; self.stopReason = stopReason; self.tasks = tasks
        self.timeline = timeline; self.notes = notes; self.loopSummary = loopSummary
        self.reconstructed = reconstructed; self.truncated = truncated
    }
    private enum K: String, CodingKey { case version, id, title, paddock, branch, terminal, openedAt, closedAt, stopReason, tasks, timeline, notes, loopSummary, reconstructed, truncated }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""; paddock = (try? c.decode(String.self, forKey: .paddock)) ?? ""
        branch = (try? c.decode(String.self, forKey: .branch)) ?? ""; terminal = (try? c.decode(String.self, forKey: .terminal)) ?? ""
        openedAt = try? c.decode(Date.self, forKey: .openedAt); closedAt = try? c.decode(Date.self, forKey: .closedAt)
        stopReason = try? c.decode(String.self, forKey: .stopReason)
        tasks = (try? c.decode([Task].self, forKey: .tasks)) ?? []; timeline = (try? c.decode([Event].self, forKey: .timeline)) ?? []
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []; loopSummary = (try? c.decode(String.self, forKey: .loopSummary)) ?? ""
        reconstructed = (try? c.decode(Bool.self, forKey: .reconstructed)) ?? false; truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
    }
}
