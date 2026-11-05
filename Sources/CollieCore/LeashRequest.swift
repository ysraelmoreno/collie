import Foundation

/// A Shepherd's request to be leashed to a terminal it doesn't reach (`collie leash request`): a card the user answers.
public struct LeashRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var reason: String?
    public var at: Date
    public init(id: UUID = UUID(), from: UUID, to: UUID, reason: String?, at: Date = Date()) {
        self.id = id; self.from = from; self.to = to; self.reason = reason; self.at = at
    }
}
