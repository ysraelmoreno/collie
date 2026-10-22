import Foundation

public enum Preset: String, Codable, Sendable, CaseIterable { case shell, claude, codex, custom }

public struct TerminalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var preset: Preset
    public var command: String?
    public var cwd: String
    public var isMaestro: Bool
    public var floorId: UUID?   // nil = ground
    public init(id: UUID, name: String, preset: Preset, command: String?, cwd: String, isMaestro: Bool, floorId: UUID? = nil) {
        self.id = id; self.name = name; self.preset = preset; self.command = command
        self.cwd = cwd; self.isMaestro = isMaestro; self.floorId = floorId
    }
}

public enum FloorStatus: String, Codable, Sendable { case working, blocked, review, done }
public enum LandMode: String, Codable, Sendable { case merge, squash, rebase, pr }

public struct Floor: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var repoRoot: String      // toplevel of the main repo (ground)
    public var path: String          // <repoRoot>/.collie/floors/<name>
    public var branch: String        // "collie/<name>"
    public var baseBranch: String    // ground's branch at creation
    public var status: FloorStatus
    public var createdBy: UUID?      // creating Maestro terminal; nil = app
    public var landedAt: Date?
    public var designSystem: UUID?   // the floor's own active design system; nil = the workspace's
    public init(id: UUID, name: String, repoRoot: String, path: String, branch: String, baseBranch: String,
                status: FloorStatus = .working, createdBy: UUID? = nil, landedAt: Date? = nil, designSystem: UUID? = nil) {
        self.id = id; self.name = name; self.repoRoot = repoRoot; self.path = path; self.branch = branch
        self.baseBranch = baseBranch; self.status = status; self.createdBy = createdBy; self.landedAt = landedAt
        self.designSystem = designSystem
    }
}

public struct Connection: Codable, Sendable, Equatable {
    public var a: UUID
    public var b: UUID
    public init(a: UUID, b: UUID) { self.a = a; self.b = b }
}

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 3
    public var id: UUID
    public var name: String
    public var terminals: [TerminalRecord]
    public var connections: [Connection]
    public var floors: [Floor]
    public var panels: [Panel]
    public var designSystem: UUID?   // active design system of ground and of floors without their own
    public init(id: UUID, name: String, terminals: [TerminalRecord] = [], connections: [Connection] = [], floors: [Floor] = [], panels: [Panel] = []) {
        self.id = id; self.name = name; self.terminals = terminals; self.connections = connections; self.floors = floors; self.panels = panels
    }
    private enum K: String, CodingKey { case schemaVersion, id, name, terminals, connections, floors, panels, designSystem }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        terminals = try c.decode([TerminalRecord].self, forKey: .terminals)
        connections = try c.decode([Connection].self, forKey: .connections)
        floors = try c.decodeIfPresent([Floor].self, forKey: .floors) ?? []   // v1 files have none
        panels = try c.decodeIfPresent([Panel].self, forKey: .panels) ?? []   // v1/v2 files have none
        designSystem = try c.decodeIfPresent(UUID.self, forKey: .designSystem)
    }
    // schemaVersion always writes the current version (a decoded v1 file is re-saved as 3).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(terminals, forKey: .terminals); try c.encode(connections, forKey: .connections); try c.encode(floors, forKey: .floors)
        try c.encode(panels, forKey: .panels); try c.encodeIfPresent(designSystem, forKey: .designSystem)
    }
}
