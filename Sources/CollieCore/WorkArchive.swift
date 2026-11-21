import Foundation

/// A closed work's immutable summary (`work.history --id`). Decoding is tolerant: a field that is missing or has the
/// wrong type becomes its empty value, never an error. Text comes from the work as it is; whoever renders it escapes it.
/// T6.1: the daemon writes it once when the work closes (`WorkArchiveFiles`); `paddockId`/`terminalId` scope `work.history`.
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
    public struct Event: Codable, Sendable, Equatable, Hashable {
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
    /// T6.1: the work's paddock (nil: the pasture) and terminal, lowercased UUIDs: what `work.history` scopes by.
    public var paddockId: String?, terminalId: String?

    public init(id: String, title: String = "", paddock: String = "", branch: String = "", terminal: String = "",
                openedAt: Date? = nil, closedAt: Date? = nil, stopReason: String? = nil, tasks: [Task] = [],
                timeline: [Event] = [], notes: [String] = [], loopSummary: String = "", reconstructed: Bool = false, truncated: Bool = false,
                paddockId: String? = nil, terminalId: String? = nil) {
        version = 1; self.id = id; self.title = title; self.paddock = paddock; self.branch = branch; self.terminal = terminal
        self.openedAt = openedAt; self.closedAt = closedAt; self.stopReason = stopReason; self.tasks = tasks
        self.timeline = timeline; self.notes = notes; self.loopSummary = loopSummary
        self.reconstructed = reconstructed; self.truncated = truncated
        self.paddockId = paddockId; self.terminalId = terminalId
    }
    private enum K: String, CodingKey { case version, id, title, paddock, branch, terminal, openedAt, closedAt, stopReason, tasks, timeline, notes, loopSummary, reconstructed, truncated, paddockId, terminalId }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""; paddock = (try? c.decode(String.self, forKey: .paddock)) ?? ""
        branch = (try? c.decode(String.self, forKey: .branch)) ?? ""; terminal = (try? c.decode(String.self, forKey: .terminal)) ?? ""
        openedAt = try? c.decode(Date.self, forKey: .openedAt); closedAt = try? c.decode(Date.self, forKey: .closedAt)
        stopReason = try? c.decode(String.self, forKey: .stopReason)
        // one malformed task or event is dropped, the rest stand
        tasks = ((try? c.decode([Lossy<Task>].self, forKey: .tasks)) ?? []).compactMap(\.value)
        timeline = ((try? c.decode([Lossy<Event>].self, forKey: .timeline)) ?? []).compactMap(\.value)
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []; loopSummary = (try? c.decode(String.self, forKey: .loopSummary)) ?? ""
        reconstructed = (try? c.decode(Bool.self, forKey: .reconstructed)) ?? false; truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        paddockId = try? c.decode(String.self, forKey: .paddockId); terminalId = try? c.decode(String.self, forKey: .terminalId)
    }
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from d: Decoder) { value = try? T(from: d) }
    }
}

/// T6.1: making one from a closed `Work`, and its file's bytes.
extension WorkArchive {
    /// The most events `timeline` keeps (the oldest go, behind one `truncated` event), the newest notes kept, the file's size.
    public static let timelineMax = 500, notesMax = 20, maxBytes = 1_000_000

    public var done: Int { tasks.filter { $0.state == TaskState.done.rawValue }.count }
    public var deferred: Int { tasks.filter { $0.state == TaskState.deferred.rawValue }.count }
    public var durationSeconds: Int { max(0, Int((closedAt ?? .distantPast).timeIntervalSince(openedAt ?? closedAt ?? .distantPast))) }

    /// What `w` (closed) leaves: `previous` (the timeline of this work's last archive) then its loop's journal, no event
    /// twice, cut to `timelineMax` behind a `truncated` event (never when `reconstructed`), then `fitted`.
    public static func make(_ w: Work, paddock: String?, terminal: String?, loopSummary: String,
                            previous: [Event] = [], reconstructed: Bool = false) -> WorkArchive {
        // whole seconds: what the file keeps (ISO 8601), so an event read back equals the same one in the journal
        let fresh = (w.loop?.events ?? []).map {
            Event(at: Date(timeIntervalSince1970: $0.at.timeIntervalSince1970.rounded(.down)), task: $0.task, kind: $0.kind.rawValue, detail: $0.detail ?? "")
        }
        let old = previous.filter { $0.kind != "truncated" }, seen = Set(old)
        var timeline = (old + fresh.filter { !seen.contains($0) }).enumerated()
            .sorted { ($0.element.at ?? .distantPast, $0.offset) < ($1.element.at ?? .distantPast, $1.offset) }.map(\.element)
        var truncated = false
        if !reconstructed, timeline.count > timelineMax {
            let keep = Array(timeline.suffix(timelineMax - 1))
            timeline = [Event(at: keep[0].at, kind: "truncated", detail: "\(timeline.count - keep.count) eventos mais antigos cortados")] + keep
            truncated = true
        }
        let tasks = w.tasks.map { t in
            Task(id: t.id, title: t.title, state: t.state.rawValue, tries: t.tries ?? 0,
                 failure: t.lastFailure ?? (t.state == .done ? nil : t.reason),
                 commits: (t.evidence?.commits ?? []).prefix(20).map { String($0.prefix { $0 != " " }) },
                 evidenceNote: t.evidence?.summary)
        }
        return WorkArchive(id: w.id.uuidString.lowercased(), title: w.title, paddock: paddock ?? "", branch: w.branch ?? "",
                           terminal: terminal ?? "", openedAt: w.openedAt, closedAt: w.closedAt ?? Date(),
                           stopReason: w.loop?.stopReason?.code.rawValue, tasks: tasks, timeline: timeline,
                           notes: w.notes.suffix(notesMax).map(\.text), loopSummary: loopSummary,
                           reconstructed: reconstructed, truncated: truncated,
                           paddockId: w.paddockId?.uuidString.lowercased(), terminalId: w.terminalId.uuidString.lowercased()).fitted()
    }

    /// Within `maxBytes` encoded: every text clipped (4000 characters, then half again, down to 125), then the oldest
    /// half of the timeline, of the notes, the last half of the tasks, until it fits.
    public func fitted(maxBytes: Int = WorkArchive.maxBytes) -> WorkArchive {
        var a = self, cap = 4000
        func size() -> Int { (try? a.encoded().count) ?? .max }
        while size() > maxBytes {
            if cap >= 100 { a.clip(cap); cap /= 2 }
            else if !a.timeline.isEmpty { a.timeline.removeFirst(Swift.max(1, a.timeline.count / 2)); a.truncated = true }
            else if !a.notes.isEmpty { a.notes.removeFirst(Swift.max(1, a.notes.count / 2)) }
            else if !a.tasks.isEmpty { a.tasks.removeLast(Swift.max(1, a.tasks.count / 2)) }
            else { break }
        }
        return a
    }

    private mutating func clip(_ n: Int) {
        func c(_ s: String) -> String { String(s.prefix(n)) }
        title = c(title); loopSummary = c(loopSummary); paddock = c(paddock); terminal = c(terminal); branch = c(branch)
        notes = notes.map(c)
        for i in tasks.indices {
            tasks[i].id = c(tasks[i].id); tasks[i].title = c(tasks[i].title); tasks[i].commits = tasks[i].commits.map(c)
            tasks[i].failure = tasks[i].failure.map(c); tasks[i].evidenceNote = tasks[i].evidenceNote.map(c)
        }
        for i in timeline.indices { timeline[i].detail = c(timeline[i].detail); timeline[i].task = timeline[i].task.map(c) }
    }

    /// The file's bytes: keys sorted, ISO 8601 dates (stable for the same archive).
    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
    /// nil: not an archive (not JSON, or no `id`).
    public static func decoded(_ data: Data) -> WorkArchive? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(WorkArchive.self, from: data)
    }
}
