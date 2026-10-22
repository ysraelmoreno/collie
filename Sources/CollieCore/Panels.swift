import Foundation
import CollieProtocol

public struct Panel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String            // unique among terminals and panels (case-insensitive); enforced by the daemon
    public var pluginId: String
    public var placement: PanelPlacement
    public var paddockId: UUID?          // canvas only
    public var state: [String: JSONValue]
    public var createdBy: UUID?        // opening Shepherd; nil = app
    public init(id: UUID, name: String, pluginId: String, placement: PanelPlacement, paddockId: UUID? = nil,
                state: [String: JSONValue] = [:], createdBy: UUID? = nil) {
        self.id = id; self.name = name; self.pluginId = pluginId; self.placement = placement
        self.paddockId = paddockId; self.state = state; self.createdBy = createdBy
    }
    private enum CodingKeys: String, CodingKey { case id, name, pluginId, placement, paddockId, state, createdBy }
    private enum Legacy: String, CodingKey { case floorId }   // before the herding vocabulary
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        pluginId = try c.decode(String.self, forKey: .pluginId); placement = try c.decode(PanelPlacement.self, forKey: .placement)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? d.container(keyedBy: Legacy.self).decodeIfPresent(UUID.self, forKey: .floorId)
        state = try c.decode([String: JSONValue].self, forKey: .state); createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
    }
}
