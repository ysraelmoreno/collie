import Foundation
import CollieProtocol

public struct Panel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String            // unique among terminals and panels (case-insensitive); enforced by the daemon
    public var pluginId: String
    public var placement: PanelPlacement
    public var floorId: UUID?          // canvas only
    public var state: [String: JSONValue]
    public var createdBy: UUID?        // opening Maestro; nil = app
    public init(id: UUID, name: String, pluginId: String, placement: PanelPlacement, floorId: UUID? = nil,
                state: [String: JSONValue] = [:], createdBy: UUID? = nil) {
        self.id = id; self.name = name; self.pluginId = pluginId; self.placement = placement
        self.floorId = floorId; self.state = state; self.createdBy = createdBy
    }
}
