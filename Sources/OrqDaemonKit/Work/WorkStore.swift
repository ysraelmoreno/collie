import Foundation
import OrqCore
import OrqProtocol

/// `<dir>/work.json` (0600): the active works and the 200 most recently closed; older closed works and anything past
/// a work's limits (500 tasks, 200 jobs, 200 notes, 200 commits) go to `<dir>/work-archive.jsonl`, append-only (only `clearHistory` empties it), one object per line
/// `{kind: work|task|job|note|commit, workId, at, ...}`. Overflow evicts first the finished (tasks: `done`; jobs: not
/// running), then the oldest of any state. Disk work runs on one serial queue, off the cooperative pool.
actor WorkStore {
    static let maxClosed = 200, maxTasks = 500, maxJobs = 200, maxNotes = 200, maxCommits = 200
    let dir: URL
    private var all: [Work]?   // loaded on first use
    private var saving = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let io = DispatchQueue(label: "orq.work")
    /// Called with each work id added, changed or removed, once the change is on disk.
    let onChange: (@Sendable (UUID) -> Void)?

    init(dir: URL, onChange: (@Sendable (UUID) -> Void)? = nil) { self.dir = dir; self.onChange = onChange }

    private var file: URL { dir.appendingPathComponent("work.json") }
    private var archive: URL { dir.appendingPathComponent("work-archive.jsonl") }

    func active(terminal: UUID) async throws -> Work? { try await load().first { $0.terminalId == terminal && $0.closedAt == nil } }
    func list(includeClosed: Bool) async throws -> [Work] { try await load().filter { includeClosed || $0.closedAt == nil } }
    func get(_ id: UUID) async throws -> Work? { try await load().first { $0.id == id } }

    func start(title: String, terminal: UUID, floorId: UUID?, branch: String?) async throws -> Work {
        let w = Work(title: title, terminalId: terminal, floorId: floorId, branch: branch)
        try await mutate { list in
            if let a = list.first(where: { $0.terminalId == terminal && $0.closedAt == nil }) {
                throw ProtocolError(code: .invalidArgs, message: "work already open: \(a.title)")
            }
            list.append(w)
        }
        return w
    }

    /// `change` applied to work `id`, then the limits enforced (overflow archived).
    func update(_ id: UUID, _ change: (inout Work) -> Void) async throws {
        try await mutate { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw Self.missing(id) }
            change(&list[i])
        }
    }

    /// Open tasks stay as they are: the summary reads them as not done.
    func close(_ id: UUID, by: String) async throws {
        try await update(id) { $0.closedAt = Date(); $0.closedBy = by }
    }

    func reopen(_ id: UUID) async throws {
        try await mutate { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw Self.missing(id) }
            if let a = list.first(where: { $0.terminalId == list[i].terminalId && $0.closedAt == nil && $0.id != id }) {
                throw ProtocolError(code: .invalidArgs, message: "work already open: \(a.title)")
            }
            list[i].closedAt = nil; list[i].closedBy = nil
        }
    }

    /// Closed works deleted and the archive emptied (admin only: the one way anything is deleted).
    func clearHistory() async throws { try await mutate(emptyArchive: true) { $0.removeAll { $0.closedAt != nil } } }

    private static func missing(_ id: UUID) -> ProtocolError { ProtocolError(code: .notFound, message: "no work \(id.uuidString.lowercased())") }

    // MARK: disk

    private func load() async throws -> [Work] {
        if let all { return all }
        let f = file
        let loaded = try await onIO { () throws -> [Work] in
            let d: Data
            do { d = try Data(contentsOf: f) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile { return [] }   // only a missing file is an empty store
            catch { throw ProtocolError(code: .internal, message: "work: cannot read \(f.path)") }
            guard let v = try? Self.decoder.decode([Work].self, from: d) else {
                throw ProtocolError(code: .internal, message: "work: \(f.path) is unreadable")
            }
            return v
        }
        if all == nil { all = loaded }
        return all ?? loaded
    }

    /// The works changed by `change` (it may throw: nothing is written), limits enforced, archive appended, then
    /// work.json written and kept in memory; one change at a time (a later one waits).
    private func mutate(emptyArchive: Bool = false, _ change: (inout [Work]) throws -> Void) async throws {
        await lock(); defer { unlock() }
        var list = try await load()
        let before = list
        try change(&list)
        var lines: [[String: Any]] = []
        Self.enforce(&list, &lines)
        let data = try Self.encode(list), f = file, a = archive
        let out = try lines.map { try Self.line($0) }
        try await onIO {
            // archive first: append-only, so a failure after it only duplicates a line on retry
            if !out.isEmpty { try Self.append(out, to: a) }
            try DesignService.writePrivate(data, to: f)
            if emptyArchive { try Self.truncate(a) }
        }
        all = list
        guard let onChange else { return }
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for w in list where was[w.id] != w { onChange(w.id) }
        for id in Set(was.keys).subtracting(list.map(\.id)) { onChange(id) }
    }

    /// `body` on the disk queue while no change is written: work.json and the archive read together are consistent (a backup).
    func withPaused<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        await lock(); defer { unlock() }
        return try await onIO(body)
    }

    private func lock() async {
        while saving { await withCheckedContinuation { waiters.append($0) } }
        saving = true
    }
    private func unlock() { saving = false; if !waiters.isEmpty { waiters.removeFirst().resume() } }

    /// Past the limits, evicted records are added to `lines`. ponytail: whole list scanned per change; fine at this scale.
    private static func enforce(_ list: inout [Work], _ lines: inout [[String: Any]]) {
        let iso = ISO8601DateFormatter()
        func tag(_ kind: String, _ w: Work, _ key: String, _ v: some Encodable) -> [String: Any] {
            let obj = (try? JSONSerialization.jsonObject(with: encoder.encode(v))) ?? NSNull()
            return ["kind": kind, "workId": w.id.uuidString.lowercased(), "at": iso.string(from: Date()), key: obj]
        }
        for i in list.indices {
            let w = list[i]
            let t = evict(w.tasks, max: maxTasks, done: { $0.state == .done }, when: \.updatedAt)
            let j = evict(w.jobs, max: maxJobs, done: { $0.state != .running }, when: \.startedAt)
            for x in t { lines.append(tag("task", w, "task", w.tasks[x])) }
            for x in j { lines.append(tag("job", w, "job", w.jobs[x])) }
            let n = max(0, w.notes.count - maxNotes)
            for x in w.notes.prefix(n) { lines.append(tag("note", w, "note", x)) }
            let c = max(0, w.commits.count - maxCommits)
            for x in w.commits.prefix(c) { lines.append(tag("commit", w, "commit", x)) }
            list[i].commits = Array(w.commits.dropFirst(c))
            list[i].tasks = w.tasks.enumerated().filter { !t.contains($0.offset) }.map(\.element)
            list[i].jobs = w.jobs.enumerated().filter { !j.contains($0.offset) }.map(\.element)
            list[i].notes = Array(w.notes.dropFirst(n))
        }
        // closed works: the newest 200 stay (ties by position)
        let closed = list.enumerated().filter { $0.element.closedAt != nil }
            .sorted { ($0.element.closedAt!, $0.offset) < ($1.element.closedAt!, $1.offset) }
        let gone = Set(closed.prefix(max(0, closed.count - maxClosed)).map(\.offset))
        for x in gone.sorted() { lines.append(tag("work", list[x], "work", list[x])) }
        list = list.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
    }

    /// Indices to evict from `items` beyond `max`: finished ones first, then the rest, each oldest first.
    private static func evict<T>(_ items: [T], max: Int, done: (T) -> Bool, when: (T) -> Date) -> Set<Int> {
        guard items.count > max else { return [] }
        let order = items.indices.sorted { a, b in
            let (da, db) = (done(items[a]), done(items[b]))
            return da != db ? da : (when(items[a]), a) < (when(items[b]), b)
        }
        return Set(order.prefix(items.count - max))
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func encode(_ list: [Work]) throws(ProtocolError) -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { return try e.encode(list) } catch { throw ProtocolError(code: .internal, message: "work: cannot encode") }
    }

    private static func line(_ o: [String: Any]) throws(ProtocolError) -> Data {
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else {
            throw ProtocolError(code: .internal, message: "work: cannot encode archive line")
        }
        d.append(0x0A); return d
    }

    static func truncate(_ url: URL) throws(ProtocolError) {
        let fd = open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        if fd >= 0 { Darwin.close(fd) }
        else if errno != ENOENT { throw ProtocolError(code: .internal, message: "work: cannot empty \(url.path)") }
    }

    static func append(_ lines: [Data], to url: URL) throws(ProtocolError) {
        let fail = ProtocolError(code: .internal, message: "work: cannot write \(url.path)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fail }
        defer { Darwin.close(fd) }
        _ = fchmod(fd, 0o600)
        let all = lines.reduce(into: Data()) { $0.append($1) }
        let ok = all.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
        guard ok else { throw fail }
    }

    /// `body` on the serial queue; enqueued before this returns to the actor, so calls run in the order made.
    private func onIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await withCheckedThrowingContinuation { c in io.async { c.resume(with: Result { try body() }) } }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }
}
