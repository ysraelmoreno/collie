import Foundation

/// Outcome scores per memory id in Collie's root (`<root>/learning/scores.json`, 0600), never in the repo's memory files.
/// A score starts at 1.0, stays in [0.2, 2.0] and multiplies relevance. Also the memories injected into each open work,
/// pruned once the work has an outcome.
actor ScoreStore {
    static let merged = 0.1, correction = -0.5, userEdit = -0.2, curatorWeight = 0.5
    static let floor = 0.2, ceiling = 2.0

    private struct State: Codable { var scores: [UUID: Double] = [:]; var injected: [UUID: Set<UUID>] = [:] }
    nonisolated let file: URL
    private var state: State?

    init(file: URL) { self.file = file }

    func noteInjected(_ ids: Set<UUID>, work: UUID) {
        guard !ids.isEmpty else { return }
        mutate { $0.injected[work, default: []].formUnion(ids) }
    }

    /// The work closed: by merge/land, its injected memories gain `merged`; any other close is neutral. Either way its
    /// injections are dropped.
    func outcome(work: UUID, merged: Bool) {
        guard let ids = load().injected[work] else { return }
        mutate { s in
            s.injected[work] = nil
            if merged { for id in ids { Self.add(&s, id, Self.merged) } }
        }
    }

    /// Any signed delta (a correction, a user edit, a curator note × `curatorWeight`).
    func penalize(_ id: UUID, _ delta: Double, reason: String) {
        mutate { Self.add(&$0, id, delta) }
        memoryLog("score \(id.uuidString.lowercased()) \(delta > 0 ? "+" : "")\(delta): \(reason)")
    }

    /// Back to 1.0 (a restored memory starts over).
    func reset(_ id: UUID) { if load().scores[id] != nil { mutate { $0.scores[id] = nil } } }

    func factor(_ id: UUID) -> Double { load().scores[id] ?? 1 }
    func all() -> [UUID: Double] { load().scores }
    func pending(_ work: UUID) -> Set<UUID> { load().injected[work] ?? [] }   // tests

    private static func add(_ s: inout State, _ id: UUID, _ delta: Double) {
        s.scores[id] = min(max((s.scores[id] ?? 1) + delta, floor), ceiling)
    }

    private func load() -> State {
        if let state { return state }
        // ponytail: an unreadable file starts over at 1.0 for all (scores are a hint, never data the user wrote)
        let s = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        state = s
        return s
    }

    /// ponytail: the whole file rewritten per change, on the actor; fine for thousands of ids.
    /// Written 0600 from the start, fsynced, renamed over; a failed write leaves no tmp and the old file as it was.
    private func mutate(_ change: (inout State) -> Void) {
        var s = load()
        change(&s)
        state = s
        let dir = file.deletingLastPathComponent(), tmp = dir.appendingPathComponent(".scores-\(UUID().uuidString).tmp")
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
            memoryLog("scores: \(error)")
        }
    }
}
