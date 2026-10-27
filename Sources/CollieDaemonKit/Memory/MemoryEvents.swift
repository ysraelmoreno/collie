import Foundation

/// One line of the memory event log: what was injected, searched, learned, maintained and spent. Never memory or
/// transcript text — ids, kinds, counts and tokens only. Fields a type doesn't use are left out of the line.
/// `project` is the repo root path, `lot` the lot id: what `memory.stats` filters (and scopes an agent) by.
struct MemoryEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case injected, searched, noHit, created, merged, superseded, retracted, archived, undone, asked, curatorRun, correction
        case sessionUsage, workClosed
    }
    var at = Date.distantPast   // stamped by the log
    var type: Kind
    var terminal: UUID? = nil, session: String? = nil, work: UUID? = nil, lot: UUID? = nil, project: String? = nil
    var ids: [UUID]? = nil, kinds: [String]? = nil, scopes: [String]? = nil
    /// `injected`: the text's UTF-8 bytes and its estimate (`bytes / 4` rounded up); start|prompt|rule|compact|checklist|retraction.
    var bytes: Int? = nil, tokens: Int? = nil, `where`: String? = nil
    /// `searched`: results returned.
    var hits: Int? = nil
    /// Lifecycle events: correction|conversation|proposal|review|consolidation|agent|user.
    var source: String? = nil
    /// `curatorRun`: job kind, outcome, the failure's reason, usage from `claude -p`, how long the call took.
    var job: String? = nil, ok: Bool? = nil, reason: String? = nil
    var inputTokens: Int? = nil, outputTokens: Int? = nil, cacheRead: Int? = nil, cacheCreation: Int? = nil
    var costUSD: Double? = nil, durationMs: Int? = nil
    /// `sessionUsage`: the model and how many assistant messages the totals cover.
    var model: String? = nil, messages: Int? = nil
    /// `correction`: active|proposed and the subject key repeats are matched on. `workClosed`: merged.
    var mode: String? = nil, subject: String? = nil, merged: Bool? = nil

    static func estimate(bytes: Int) -> Int { (bytes + 3) / 4 }

    /// A store key (`RepoMemory.key`) as the event's lot or project.
    mutating func place(store key: String) {
        if key.hasPrefix("lot:") { lot = UUID(uuidString: String(key.dropFirst(4))) } else if key.hasPrefix("/") { project = key }
    }
}

/// `<root>/metrics/memory-YYYY-MM-DD.jsonl` (local day, 0600 in a 0700 dir), one event per line, the last `keepDays` days
/// kept. `emit` only enqueues: the append runs on the log's own serial queue, never in the caller (a hook) — the caller
/// pays one `async` dispatch. A failed write is a log line; the event is lost (metrics never fail a command).
final class MemoryEventLog: @unchecked Sendable {   // `lastDay` is touched only on `queue`
    static let keepDays = 90
    /// The lifecycle source of digest rows written by the current task (a curator job, the consolidation); nil: the user's.
    @TaskLocal static var source: String?

    let dir: URL
    private let now: @Sendable () -> Date
    private let queue: DispatchQueue
    private var lastDay: String?

    /// `queue`: tests pass one they suspend (the append must not run in `emit`).
    init(dir: URL, now: @escaping @Sendable () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "collie.memory.events", qos: .utility)) {
        self.dir = dir; self.now = now; self.queue = queue
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func day(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func emit(_ e: MemoryEvent) {
        var e = e
        e.at = now()
        queue.async { self.append(e) }
    }

    /// Waits for every event emitted so far to be on disk (tests, and `read`).
    func flush() { queue.sync {} }

    /// Events at or after `since`, oldest first (a damaged line is skipped).
    func read(since: Date) -> [MemoryEvent] {
        queue.sync {
            let first = "memory-\(Self.day(since)).jsonl"
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("memory-") && $0.hasSuffix(".jsonl") && $0 >= first }.sorted()
            return names.flatMap { n -> [MemoryEvent] in
                guard let text = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap { try? Self.decoder.decode(MemoryEvent.self, from: Data($0.utf8)) }
            }.filter { $0.at >= since }
        }
    }

    /// Queue only.
    private func append(_ e: MemoryEvent) {
        let day = Self.day(e.at)
        do {
            if lastDay != day {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                chmod(dir.path, 0o700)
                prune(before: e.at)
                lastDay = day
            }
            var line = try Self.encoder.encode(e)
            line.append(10)
            let fd = open(dir.appendingPathComponent("memory-\(day).jsonl").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            // ponytail: one write(2) per line with O_APPEND; lines stay whole (one writer: this queue)
            guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == line.count else { throw POSIXError(.EIO) }
        } catch {
            memoryLog("events: \(error)")
        }
    }

    /// Queue only: files of days older than `keepDays` before `now` go.
    private func prune(before now: Date) {
        let oldest = "memory-\(Self.day(now.addingTimeInterval(-Double(Self.keepDays) * 86_400))).jsonl"
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasPrefix("memory-") && n.hasSuffix(".jsonl") && n < oldest {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}
