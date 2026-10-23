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
    /// The lot `terminal` belongs to (at most one).
    public func lot(of terminal: UUID) -> Lot? { lots.first { $0.members.contains(terminal) } }
}
