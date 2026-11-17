import Foundation
import CryptoKit
import CollieCore

/// The provenance ledger (spec 2026-11-17 cursor memory, P1): for every memory the daemon wrote, the sha256 of the text it
/// wrote and the `origin`/`curatedBy` it wrote with it. It lives in Collie's data (`<root>/learning/provenance.json`, 0600
/// in a 0700 dir), which no terminal can write; a memory's `.md` and the store's index live in the repo, which an agent
/// can. A record is *verified* when its text, as Collie reads it, is the text the daemon wrote: a hand edit, a planted
/// file, a clone's or an edited index row is not. The file's `origin`/`curatedBy` stay as readable history; a decision
/// that trusts them reads `entry(id)` of a verified record.
/// Not tied to a store: ids are unique, and a paddock's memory merged into its pasture keeps the same text.
/// ponytail: one JSON file rewritten on each write (like `lifecycle.json`); a store with tens of thousands of writes a day
/// would want an append log.
final class MemoryProvenance: @unchecked Sendable {   // `state` is touched only under `lock`
    struct Entry: Codable, Sendable, Equatable {
        var sha256: String
        var origin: String
        var curatedBy: CuratedBy?
        var at: Date
    }
    private struct State: Codable {
        /// When this ledger was born: a store's first read adopts the files older than this (C3), once.
        var createdAt: Date
        /// Store dirs already adopted (their first read happened).
        var adopted: Set<String> = []
        var entries: [UUID: Entry] = [:]
    }

    let file: URL
    private let lock = NSLock()
    private var state: State

    /// `now`: when a missing ledger is born (tests move it).
    init(file: URL, now: Date = Date()) {
        self.file = file
        if let data = try? Data(contentsOf: file), let s = try? Self.decoder.decode(State.self, from: data) {
            state = s
        } else {
            // ponytail: an unreadable ledger starts over (re-adopts only files older than now); nothing becomes trusted
            // that a fresh install wouldn't trust
            state = State(createdAt: now)
        }
    }

    static func digest(_ r: MemoryRecord) -> String {
        SHA256.hash(data: Data(MemoryFile.render(r).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The daemon wrote `r` (every `MemoryStore.write`), or the user trusted it as it is ("Confiar").
    func record(_ r: MemoryRecord, now: Date = Date()) {
        let e = Entry(sha256: Self.digest(r), origin: r.origin, curatedBy: r.curatedBy, at: now)
        lock.withLock { state.entries[r.id] = e; save() }
    }

    func forget(_ id: UUID) {
        lock.withLock { if state.entries.removeValue(forKey: id) != nil { save() } }
    }

    func entry(_ id: UUID) -> Entry? { lock.withLock { state.entries[id] } }

    /// `r` (from its file or from the index) is the text the daemon last wrote for its id.
    func isVerified(_ r: MemoryRecord) -> Bool { trustedEntry(r) != nil }

    /// The daemon's own copy of `r`'s origin and curation, when `r` is verified; nil otherwise (callers treat an
    /// unverified record as the least trusted: never the user's, curated with limited trust).
    func trustedEntry(_ r: MemoryRecord) -> Entry? {
        guard let e = entry(r.id), e.sha256 == Self.digest(r) else { return nil }
        return e
    }

    func hasAdopted(_ store: String) -> Bool { lock.withLock { state.adopted.contains(store) } }

    /// A store's first read: the records whose file is older than the ledger are taken as the daemon's (C3); later
    /// files, and every file after this, are not. Returns how many were adopted.
    @discardableResult
    func adoptOnce(store: String, _ files: [(record: MemoryRecord, mtime: Date)], now: Date = Date()) -> Int {
        lock.withLock {
            guard state.adopted.insert(store).inserted else { return 0 }
            var n = 0
            for f in files where f.mtime < state.createdAt && state.entries[f.record.id] == nil {
                state.entries[f.record.id] = Entry(sha256: Self.digest(f.record), origin: f.record.origin, curatedBy: f.record.curatedBy, at: now)
                n += 1
            }
            save()
            return n
        }
    }

    /// Under `lock`. Atomic, 0600 in a 0700 dir. A failed write is a log line (the next write retries).
    private func save() {
        do {
            let dir = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir.path, 0o700)
            let tmp = dir.appendingPathComponent(".provenance-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: try Self.encoder.encode(state), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(tmp.path, file.path) != 0 { try? FileManager.default.removeItem(at: tmp); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { memoryLog("provenance: \(error)") }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
