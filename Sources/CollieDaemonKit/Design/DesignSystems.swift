import Foundation
import CollieProtocol

/// A design system: a design file (2A registry) whose library is published on the local figcraft server.
/// `viewLink` is as secret as an edit link: it never leaves the daemon. `reverted`: the version the library was last
/// reverted to while its file still shows newer content (a publish then needs `--force`).
struct DesignSystem: Codable, Sendable, Equatable {
    var id: UUID; var name: String; var fileId: UUID; var viewLink: String; var version: Int; var createdAt: Date
    var reverted: Int? = nil
}

/// One screen file's result of an activation, a swap or a propagated version (`file`: its name). `unmatched`: what
/// the swap found no match for in the new library (still bound to the old one).
struct FileOutcome: Codable, Sendable, Equatable {
    var file: String; var ok: Bool; var detail: String; var unmatched: [String]? = nil
}

struct DesignSystemEvent: Codable, Sendable, Equatable {
    var at: Date
    var kind: String   // created|published|reverted|activated
    var version: Int?
    var scope: String?   // "workspace" | "paddock:<name>"
    var by: String   // terminal name | "app"
    var reason: String
    var snapshot: String?   // a .figcraft file name in the system's folder
    var files: [FileOutcome]
    var paddockId: UUID? = nil   // a paddock scope's paddock (its undo timeline follows the paddock, not its name)
}

extension DesignSystemEvent {
    private enum CodingKeys: String, CodingKey { case at, kind, version, scope, by, reason, snapshot, files, paddockId }
    private enum Legacy: String, CodingKey { case floorId }   // before the herding vocabulary (`scope` stays as written)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at); kind = try c.decode(String.self, forKey: .kind)
        version = try c.decodeIfPresent(Int.self, forKey: .version); scope = try c.decodeIfPresent(String.self, forKey: .scope)
        by = try c.decode(String.self, forKey: .by); reason = try c.decode(String.self, forKey: .reason)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot); files = try c.decode([FileOutcome].self, forKey: .files)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? d.container(keyedBy: Legacy.self).decodeIfPresent(UUID.self, forKey: .floorId)
    }
}

/// `<dir>/systems.json` (0600) and per system `<dir>/systems/<id>/` (0700): `history.json` (0600, last 200 events) and
/// the `v<N>.figcraft` snapshots. Written whole to a temp file, then renamed over.
struct DesignSystemStore: Sendable {
    static let historyCap = 200
    let dir: URL   // <root>/design
    private var registry: URL { dir.appendingPathComponent("systems.json") }
    func dir(_ id: UUID) -> URL { dir.appendingPathComponent("systems/\(id.uuidString.lowercased())") }

    /// Same rule as design file names (the system's file carries its name).
    static func validate(_ name: String) throws(ProtocolError) { try DesignService.validate(name) }

    func load() throws(ProtocolError) -> [DesignSystem] {
        guard let d = FileManager.default.contents(atPath: registry.path) else { return [] }
        // a corrupt registry is not replaced by an empty one (its links would be lost): it is an error until repaired
        guard let all = try? Self.decoder.decode([DesignSystem].self, from: d) else {
            throw ProtocolError(code: .internal, message: "design: \(registry.path) is unreadable")
        }
        return all
    }

    func save(_ all: [DesignSystem]) throws(ProtocolError) {
        try DesignService.writePrivate(try Self.encode(all), to: registry)
    }

    /// A create in flight or failed half-way: its design file (`DesignService.File.id`) and whether it is a copy.
    struct Pending: Codable, Sendable, Equatable { var fileId: String; var copied: Bool }
    private var pendingFile: URL { dir.appendingPathComponent("systems-pending.json") }

    /// By lowercased name; none (or unreadable): empty.
    func pending() -> [String: Pending] {
        FileManager.default.contents(atPath: pendingFile.path).flatMap { try? Self.decoder.decode([String: Pending].self, from: $0) } ?? [:]
    }

    func setPending(_ name: String, _ p: Pending?) throws(ProtocolError) {
        var all = pending()
        all[name] = p
        try DesignService.writePrivate(try Self.encode(all), to: pendingFile)
    }

    /// Oldest first; none (or unreadable): empty.
    func history(_ id: UUID) -> [DesignSystemEvent] {
        FileManager.default.contents(atPath: dir(id).appendingPathComponent("history.json").path)
            .flatMap { try? Self.decoder.decode([DesignSystemEvent].self, from: $0) } ?? []
    }

    func append(_ e: DesignSystemEvent, to id: UUID) throws(ProtocolError) {
        let all = Array((history(id) + [e]).suffix(Self.historyCap))
        try DesignService.writePrivate(try Self.encode(all), to: try folder(id).appendingPathComponent("history.json"))
    }

    /// The system's folder, made 0700 when missing.
    func folder(_ id: UUID) throws(ProtocolError) -> URL {
        let u = dir(id)
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ProtocolError(code: .internal, message: "design: cannot create \(u.path)") }
        return u
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static func encode(_ v: some Encodable) throws(ProtocolError) -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { return try enc.encode(v) } catch { throw ProtocolError(code: .internal, message: "design: cannot encode the registry") }
    }
}
