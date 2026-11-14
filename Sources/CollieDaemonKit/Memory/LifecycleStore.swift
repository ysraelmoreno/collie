import Foundation

enum LifecycleTier: String, Codable, Sendable { case provisional, earned, longTerm }
enum FlagVerdict: String, Codable, Sendable { case useful, wrong, outdated }

struct LifecycleFlag: Codable, Sendable, Equatable { var verdict: FlagVerdict; var session: String; var day: String; var reason: String }
/// `day` = `yyyy-MM-dd`, UTC.
struct UseKey: Codable, Sendable, Hashable { var day: String; var session: String }

struct LifecycleEntry: Codable, Sendable, Equatable {
    var tier: LifecycleTier = .provisional
    var usefulUses: Set<UseKey> = []
    var flags: [LifecycleFlag] = []
    var contestedNow = false
    var lastContestedAt: Date?
    var recheckedAt: Date?
    var tierSince: Date
}

/// Usage-based lifecycle state per memory id (`<root>/learning/lifecycle.json`, 0600), never in the repo's memory files.
actor LifecycleStore {
    static let sessionTTL: TimeInterval = 7 * 86_400, missingTTL: TimeInterval = 30 * 86_400

    private struct State: Codable {
        var entries: [UUID: LifecycleEntry] = [:]
        var injectedBySession: [String: Set<UUID>] = [:]
        var lastEvent: [String: Date] = [:]
        var pending: [String: [UUID]] = [:]
        var missingSince: [UUID: Date] = [:]
    }
    nonisolated let file: URL
    private var state: State?

    init(file: URL) { self.file = file }

    func entry(_ id: UUID) -> LifecycleEntry? { load().entries[id] }
    func all() -> [UUID: LifecycleEntry] { load().entries }

    func update(_ id: UUID, now: Date, _ change: (inout LifecycleEntry) -> Void) {
        mutate { s in
            var e = s.entries[id] ?? LifecycleEntry(tierSince: now)
            change(&e)
            s.entries[id] = e
        }
    }

    /// One useful use `key` for each id, in one write; skips an id `key.session` flagged wrong/outdated.
    func addUse(_ ids: [UUID], key: UseKey, now: Date) {
        mutate { s in
            for id in ids {
                var e = s.entries[id] ?? LifecycleEntry(tierSince: now)
                guard !e.flags.contains(where: { $0.session == key.session && $0.verdict != .useful }) else { continue }
                e.usefulUses.insert(key)
                s.entries[id] = e
            }
        }
    }

    func noteInjected(session: String, ids: [UUID], now: Date) {
        mutate { s in
            s.injectedBySession[session, default: []].formUnion(ids)
            s.lastEvent[session] = now
            Self.expireSessions(&s, now: now)
        }
    }

    func injected(session: String) -> Set<UUID> { load().injectedBySession[session] ?? [] }

    func setPending(session: String, ids: [UUID]) { mutate { $0.pending[session] = ids } }

    func takePending(session: String) -> [UUID] {
        guard let ids = load().pending[session] else { return [] }
        mutate { $0.pending[session] = nil }
        return ids
    }

    /// Ids gone from the memory files for 30 days lose their entry; one that comes back starts its clock over.
    func prune(knownIds: Set<UUID>, now: Date) {
        mutate { s in
            for id in s.entries.keys where !knownIds.contains(id) {
                if let since = s.missingSince[id], now.timeIntervalSince(since) >= Self.missingTTL {
                    s.entries[id] = nil; s.missingSince[id] = nil
                } else if s.missingSince[id] == nil { s.missingSince[id] = now }
            }
            for id in s.missingSince.keys where knownIds.contains(id) || s.entries[id] == nil { s.missingSince[id] = nil }
            Self.expireSessions(&s, now: now)
        }
    }

    private static func expireSessions(_ s: inout State, now: Date) {
        for (session, at) in s.lastEvent where now.timeIntervalSince(at) >= sessionTTL {
            s.injectedBySession[session] = nil; s.lastEvent[session] = nil; s.pending[session] = nil
        }
    }

    private func load() -> State {
        if let state { return state }
        // ponytail: an unreadable file starts empty (lifecycle is derived usage data, never what the user wrote)
        let s = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        state = s
        return s
    }

    /// ponytail: whole file rewritten per change, on the actor. Written 0600, fsynced, renamed over; a failed write leaves no tmp.
    private func mutate(_ change: (inout State) -> Void) {
        var s = load()
        change(&s)
        state = s
        let dir = file.deletingLastPathComponent(), tmp = dir.appendingPathComponent(".lifecycle-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(s)
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count } && fsync(fd) == 0
            close(fd)
            guard ok, rename(tmp.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(tmp.path)
            memoryLog("lifecycle: \(error)")
        }
    }
}
