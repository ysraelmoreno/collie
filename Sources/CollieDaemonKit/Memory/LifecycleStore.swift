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
    /// The `RepoMemory.key` holding the record (set by the lifecycle pass); optional: older files decode.
    var store: String? = nil
    /// When the promotion gate last judged it (verdict or undo); the 14-day re-gate wait reads this, not `recheckedAt`.
    var gatedAt: Date? = nil
    /// `LifecycleRules.textHash` of the text an earned/longTerm tier was given for: an edited text starts over.
    var textHash: String? = nil
    /// The user undid its promotion: never gated automatically again.
    var promotionUndone: Bool? = nil
    /// What open flags took from its score (after the floor clamp); a valid re-check gives back exactly this.
    var flagPenalty: Double? = nil
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
        /// Promotion gates queued on `gateDay` (UTC `yyyy-MM-dd`); optional: older files decode.
        var gateDay: String?, gates: Int?
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

    /// `change` on each id's entry (a new one starts provisional at `now`), in one write.
    func update(_ ids: [UUID], now: Date, _ change: (UUID, inout LifecycleEntry) -> Void) {
        mutate { s in
            for id in ids {
                var e = s.entries[id] ?? LifecycleEntry(tierSince: now)
                change(id, &e)
                s.entries[id] = e
            }
        }
    }

    /// One useful use `key` for each id, in one write; skips an id `key.session` flagged wrong/outdated. Returns the ids
    /// taken (a `key` already held counts as taken: the set just doesn't grow).
    @discardableResult
    func addUse(_ ids: [UUID], key: UseKey, now: Date) -> [UUID] {
        var taken: [UUID] = []
        mutate { s in
            for id in ids {
                var e = s.entries[id] ?? LifecycleEntry(tierSince: now)
                guard !e.flags.contains(where: { $0.session == key.session && $0.verdict != .useful }) else { continue }
                e.usefulUses.insert(key)
                s.entries[id] = e
                taken.append(id)
            }
        }
        return taken
    }

    enum FlagOutcome: Sendable { case added, duplicate, limit }

    /// Appends `flag` to `id` in one write unless this session already flagged `id` (wrong/outdated: `.duplicate`) or already holds
    /// `limit` flags (`.limit`); count and append are one actor step, so concurrent flags can't overshoot.
    func addFlag(_ id: UUID, _ flag: LifecycleFlag, limit: Int, contest: Bool, now: Date) -> FlagOutcome {
        let s0 = load()
        if s0.entries[id]?.flags.contains(where: { $0.session == flag.session && $0.verdict != .useful }) == true { return .duplicate }
        guard s0.entries.values.reduce(0, { $0 + $1.flags.filter { $0.session == flag.session }.count }) < limit else { return .limit }
        mutate { s in
            var e = s.entries[id] ?? LifecycleEntry(tierSince: now)
            e.flags.append(flag)
            if contest { e.contestedNow = true; e.lastContestedAt = now }
            s.entries[id] = e
        }
        return .added
    }

    /// The user kept `id` (resolved its ask, restored it, undid its archive): uncontested, flags cleared, its unused clock
    /// and the 14-day re-check cooldown start now. Only an existing entry changes.
    func userKept(_ id: UUID, now: Date) {
        guard load().entries[id] != nil else { return }
        update(id, now: now) { $0.tierSince = now; $0.flags = []; $0.contestedNow = false; $0.recheckedAt = now; $0.flagPenalty = nil }
    }

    /// One promotion gate of `day` taken, unless `max` already were (count and take in one actor step).
    func takeGate(day: String, max: Int) -> Bool {
        let s0 = load(), used = s0.gateDay == day ? s0.gates ?? 0 : 0
        guard used < max else { return false }
        mutate { $0.gateDay = day; $0.gates = used + 1 }
        return true
    }

    /// A gate taken for a job the queue refused is given back.
    func releaseGate(day: String) {
        mutate { s in if s.gateDay == day, let g = s.gates, g > 0 { s.gates = g - 1 } }
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
    /// `store`: only entries of that store are judged (`knownIds` = its ids); the others stay as they are.
    func prune(store: String? = nil, knownIds: Set<UUID>, now: Date) {
        mutate { s in
            for (id, e) in s.entries where !knownIds.contains(id) && (store == nil || e.store == store) {
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
        // ponytail: an undecodable file is kept aside as `<name>.corrupt` (the last one only) and state starts empty
        // (lifecycle is derived usage data, never what the user wrote)
        var s = State()
        if let data = try? Data(contentsOf: file) {
            do { s = try JSONDecoder().decode(State.self, from: data) } catch {
                let aside = file.appendingPathExtension("corrupt")
                unlink(aside.path)
                let moved = rename(file.path, aside.path) == 0
                memoryLog("lifecycle: unreadable \(file.lastPathComponent) (\(error)); \(moved ? "kept as \(aside.lastPathComponent)" : "not moved"), starting empty")
            }
        }
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
