import Foundation
import CollieCore
import CollieProtocol

/// One automatic action of the curator, with what it changed (`before`: the records as they were, for Desfazer).
struct DigestEntry: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var at: Date
    var action: String   // aprendido|aposentado|mesclado|ativado|descartado|ask
    var title: String
    var reason: String
    var store: String    // RepoMemory.key
    var created: [UUID]
    var before: [MemoryRecord]
    var undone: Bool
    var resolved: Bool
    /// The correction job that wrote it: Desfazer on any row of a job undoes the whole job.
    var job: UUID? = nil
    /// A supersede's successor (not in `created`: undoing a retirement never discards a record it didn't create).
    var by: UUID? = nil
}

/// `<root>/learning/digest.jsonl` (0600 in a 0700 dir), oldest first, the newest `cap` kept.
/// Not synchronized: the router (an actor) is its only user.
struct MemoryDigest {
    static let cap = 2_000
    let file: URL
    init(file: URL) { self.file = file }

    func append(_ e: [DigestEntry]) throws {
        guard !e.isEmpty else { return }
        try save(Array((all() + e).suffix(Self.cap)))
    }

    /// Entries at or after `d`, oldest first; `openAsks`: plus the asks still open, however old (L4: they wait for the user).
    func since(_ d: Date, openAsks: Bool = false) -> [DigestEntry] {
        all().filter { $0.at >= d || openAsks && $0.action == "ask" && !$0.resolved && !$0.undone }
    }

    func mark(_ ids: [UUID], undone: Bool?, resolved: Bool?) throws {
        var es = all()
        for i in es.indices where ids.contains(es[i].id) {
            if let undone { es[i].undone = undone }
            if let resolved { es[i].resolved = resolved }
        }
        try save(es)
    }

    /// A damaged line is skipped (the rest stays readable).
    private func all() -> [DigestEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(DigestEntry.self, from: Data($0.utf8)) }
    }

    /// ponytail: rewrites the whole file (≤ 2 000 entries, one write per curator job); append-only if that gets slow.
    private func save(_ es: [DigestEntry]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        var data = Data()
        for e in es { data += try enc.encode(e); data += Data("\n".utf8) }
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension CommandRouter {
    /// The record `id` now, in the entry's store or the global one (where a job's records live).
    private func current(_ id: UUID, _ e: DigestEntry) async -> (store: RepoMemory, rec: MemoryRecord)? {
        var stores = [memory.global]
        if let s = await memory.store(key: e.store), s !== memory.global { stores.insert(s, at: 0) }
        for s in stores {
            if let r = (try? await s.run { $0.store.all().records.first { $0.id == id } }) ?? nil { return (s, r) }
        }
        return nil
    }

    /// Desfazer: the entry's `before` records are written back as they were, the ones it `created` become discarded.
    /// M1: an entry of a correction job undoes the whole job (every row of it: the rule discarded, every retired memory
    /// and pin restored), in one go. Refused when any record changed after the action (the user or a later job): that is
    /// undone from the history. A second undo is a no-op. M2: what is active again is pushed to the sessions told it went.
    func undoDigest(_ id: UUID) async throws -> DigestEntry {
        let es = digest.since(.distantPast)
        guard var e = es.first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "entrada \(id.uuidString.lowercased()) não encontrada")
        }
        if e.undone { return e }
        guard e.action != "ask" else { throw ProtocolError(code: .invalidArgs, message: "uma pergunta se resolve (memory.resolve), não se desfaz") }
        let group = e.job.map { j in es.filter { $0.job == j && !$0.undone && $0.action != "ask" } } ?? [e]
        let before = group.flatMap(\.before)
        let created = Set(group.flatMap(\.created)).subtracting(before.map(\.id))
        var now: [UUID: (store: RepoMemory, rec: MemoryRecord)] = [:]
        for g in group { for i in g.before.map(\.id) + g.created where now[i] == nil { if let c = await current(i, g) { now[i] = c } } }
        // ponytail: 1 s of slack — the job's own writes carry a timestamp a hair before its last entry's
        let last = group.map(\.at).max() ?? e.at
        if now.values.contains(where: { $0.rec.updatedAt > last.addingTimeInterval(1) }) {
            throw ProtocolError(code: .invalidArgs, message: "a memória mudou depois; desfaça pelo histórico")
        }
        var back: [UUID] = []
        for g in group {
            let home = await memory.store(key: g.store) ?? memory.global
            for b in g.before {
                let s = now[b.id]?.store ?? home
                try await s.run { try $0.store.write(b) }
                if b.status == .active, now[b.id]?.rec.status != .active { back.append(b.id) }
            }
        }
        for c in created {
            guard var r = now[c] else { continue }
            r.rec.status = .discarded; r.rec.updatedAt = Date()
            let rec = r.rec
            try await r.store.run { try $0.store.write(rec) }
        }
        try digest.mark(group.map(\.id), undone: true, resolved: nil)
        for id in back { await memory.scores.reset(id) }   // restored: its correction penalty goes too (starts over)
        await memory.restored(back)
        e.undone = true
        return e
    }

    /// "Precisa de você": the user keeps the newer or the older of the records the ask names (by when each was last
    /// changed before it); the kept one is active, the others superseded by it.
    func resolveAsk(_ id: UUID, keepNewer: Bool) async throws -> DigestEntry {
        guard var e = digest.since(.distantPast).first(where: { $0.id == id }), e.action == "ask" else {
            throw ProtocolError(code: .notFound, message: "pergunta \(id.uuidString.lowercased()) não encontrada")
        }
        if e.resolved { return e }
        let order = e.before.sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }
        if let keep = keepNewer ? order.last : order.first {
            for b in order {
                guard var c = await current(b.id, e) else { continue }
                if b.id == keep.id {
                    if c.rec.status != .active { await memory.restored([b.id]) }   // M2 (pushed once written: read at the next prompt)
                    c.rec.status = .active; c.rec.supersededBy = nil
                }
                else { c.rec.status = .superseded; c.rec.supersededBy = keep.id }
                c.rec.updatedAt = Date()
                let rec = c.rec
                try await c.store.run { try $0.store.write(rec) }
            }
        }
        try digest.mark([id], undone: nil, resolved: true)
        e.resolved = true
        return e
    }
}
