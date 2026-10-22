import Foundation
import CollieCore
import CollieProtocol

/// `<dir>/<id>.collieherd` (0600, atomic) per saved herd, plus the factory ones (read-only, in memory). Files
/// are read and written off the cooperative pool; a file that does not validate is left out of the list.
/// Set aside: moved to `<dir>/.removed/<id>-<epochMs>-<random>.collieherd`, never deleted.
/// ponytail: the folder is read on each call (a few small files); cache it if the library grows.
actor HerdStore {
    let dir: URL
    private static let ext = "collieherd"

    init(dir: URL) { self.dir = dir }

    private static func bad(_ m: String, _ code: ErrorCode = .invalidArgs) -> ProtocolError { ProtocolError(code: code, message: m) }
    private static func safe(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// Factory + saved, by name.
    func list() async -> [Herd] {
        let d = dir, ext = Self.ext
        let saved = (try? await UnixSocketClient.offPool { () -> [Herd] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            return names.filter { $0.hasSuffix(".\(ext)") }.compactMap { n in
                guard let data = try? Data(contentsOf: d.appendingPathComponent(n)), let p = try? HerdFormat.decode(data),
                      "\(p.id).\(ext)" == n else { return nil }
                return p
            }
        }) ?? []
        let factory = Set(Herd.factory.map(\.id))
        return (Herd.factory + saved.filter { !factory.contains($0.id) })
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    func get(_ id: String) async -> Herd? {
        if let f = Herd.factory.first(where: { $0.id == id }) { return f }
        guard Self.safe(id) else { return nil }
        let f = dir.appendingPathComponent("\(id).\(Self.ext)")
        return try? await UnixSocketClient.offPool { try? HerdFormat.decode(try Data(contentsOf: f)) }.flatMap { $0 }
    }

    func put(_ p: Herd) async throws {
        guard !Herd.factory.contains(where: { $0.id == p.id }) else { throw Self.bad("rebanho de fábrica não pode ser substituído") }
        try HerdFormat.validate(p)
        let data: Data
        do { data = try HerdFormat.encode(p) } catch { throw Self.bad("rebanho: não foi possível codificar", .internal) }
        let to = dir.appendingPathComponent("\(p.id).\(Self.ext)")
        try await UnixSocketClient.offPool { try DesignService.writePrivate(data, to: to) }
    }

    func setAside(_ id: String) async throws {
        guard !Herd.factory.contains(where: { $0.id == id }) else { throw Self.bad("rebanho de fábrica não pode ser removido") }
        guard Self.safe(id) else { throw Self.bad("rebanho \(id) não existe", .notFound) }
        let from = dir.appendingPathComponent("\(id).\(Self.ext)")
        let stamp = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())"   // same ms: no overwrite
        let to = dir.appendingPathComponent(".removed/\(id)-\(stamp).\(Self.ext)")
        try await UnixSocketClient.offPool {
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path) else { throw Self.bad("rebanho \(id) não existe", .notFound) }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard rename(from.path, to.path) == 0 else { throw Self.bad("rebanho: não foi possível mover \(from.path)", .internal) }
        }
    }
}
