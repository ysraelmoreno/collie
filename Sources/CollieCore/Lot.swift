import Foundation

/// Terminals grouped by effort. Membership never grants reach (leashes are the only permission): it only picks
/// which lot memory/board a terminal gets. A terminal is in at most one lot; an empty lot stays until the user deletes it.
public struct Lot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var goal: String
    public var paddockId: UUID?
    public var members: [UUID]
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, goal: String = "", paddockId: UUID? = nil, members: [UUID] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.goal = goal; self.paddockId = paddockId; self.members = members; self.createdAt = createdAt
    }
    private enum K: String, CodingKey { case id, name, goal, paddockId, members, createdAt }
    /// Only id and name are required; anything else malformed is defaulted (R2).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        goal = (try? c.decodeIfPresent(String.self, forKey: .goal)) ?? ""
        paddockId = try? c.decodeIfPresent(UUID.self, forKey: .paddockId)
        members = ((try? c.decodeIfPresent([Lossy<UUID>].self, forKey: .members)) ?? []).compactMap(\.value)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

/// One array element that may fail to decode: it becomes nil instead of failing the array.
public struct Lossy<T: Decodable>: Decodable {
    public let value: T?
    public init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Workspace {
    /// The lot `terminal` belongs to (at most one). A free terminal is in none (R6: old membership ignored).
    public func lot(of terminal: UUID) -> Lot? {
        if terminals.contains(where: { $0.id == terminal && $0.sandbox == .free }) { return nil }
        return lots.first { $0.members.contains(terminal) }
    }
}

/// One post on a lot's board (`lot.post`): agent-written, so untrusted text — shown and injected as data, never run.
/// `kind` stays a string so a value from a newer build still decodes (R2): only `handoff|question|answer` addressed to a
/// terminal are injected into its prompts, `status` (and anything else) only on `lot.board`.
public struct LotPost: Codable, Sendable, Equatable, Identifiable {
    public static let kinds = ["handoff", "question", "status", "answer"]
    public static let maxText = 4_000, maxTextBytes = 16_384, maxRef = 200
    public var id: UUID
    public var at: Date
    public var kind: String
    /// The author's name when posted ("app" for the user).
    public var from: String
    public var fromId: UUID?
    /// The recipient (a lot member when posted) and its name then.
    public var to: UUID?
    public var toName: String?
    /// A label only (a memory/artifact/work id): never resolved for readers.
    public var ref: String?
    public var text: String
    public init(id: UUID = UUID(), at: Date = Date(), kind: String, from: String, fromId: UUID? = nil, to: UUID? = nil,
                toName: String? = nil, ref: String? = nil, text: String) {
        self.id = id; self.at = at; self.kind = kind; self.from = from; self.fromId = fromId; self.to = to; self.toName = toName
        self.ref = ref; self.text = text
    }
    private enum K: String, CodingKey { case id, at, kind, from, fromId, to, toName, ref, text }
    /// Only id and text are required; anything else malformed is defaulted (R2).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id); text = try c.decode(String.self, forKey: .text)
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date(timeIntervalSinceReferenceDate: 0)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "status"
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? ""
        fromId = try? c.decodeIfPresent(UUID.self, forKey: .fromId)
        to = try? c.decodeIfPresent(UUID.self, forKey: .to)
        toName = try? c.decodeIfPresent(String.self, forKey: .toName)
        ref = try? c.decodeIfPresent(String.self, forKey: .ref)
    }
}
