import Foundation
import CollieCore

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

    /// Entries at or after `d`, oldest first.
    func since(_ d: Date) -> [DigestEntry] { all().filter { $0.at >= d } }

    func mark(_ id: UUID, undone: Bool?, resolved: Bool?) throws {
        var es = all()
        guard let i = es.firstIndex(where: { $0.id == id }) else { return }
        if let undone { es[i].undone = undone }
        if let resolved { es[i].resolved = resolved }
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
