import Foundation

public enum Preset: String, Codable, Sendable, CaseIterable { case shell, claude, codex, custom }

public struct TerminalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var preset: Preset
    public var command: String?
    public var cwd: String
    public var isShepherd: Bool
    public var paddockId: UUID?   // nil = pasture
    public init(id: UUID, name: String, preset: Preset, command: String?, cwd: String, isShepherd: Bool, paddockId: UUID? = nil) {
        self.id = id; self.name = name; self.preset = preset; self.command = command
        self.cwd = cwd; self.isShepherd = isShepherd; self.paddockId = paddockId
    }
    private enum CodingKeys: String, CodingKey { case id, name, preset, command, cwd, isShepherd, paddockId }
    private enum Legacy: String, CodingKey { case isMaestro, floorId }   // before the herding vocabulary
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), l = try d.container(keyedBy: Legacy.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        preset = try c.decode(Preset.self, forKey: .preset); command = try c.decodeIfPresent(String.self, forKey: .command)
        cwd = try c.decode(String.self, forKey: .cwd)
        isShepherd = try c.decodeIfPresent(Bool.self, forKey: .isShepherd) ?? l.decode(Bool.self, forKey: .isMaestro)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? l.decodeIfPresent(UUID.self, forKey: .floorId)
    }
}

public enum PaddockStatus: String, Codable, Sendable { case working, blocked, review, done }
public enum LandMode: String, Codable, Sendable { case merge, squash, rebase, pr }

public struct Paddock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var repoRoot: String      // toplevel of the main repo (pasture)
    public var path: String          // <repoRoot>/.collie/paddocks/<name>
    public var branch: String        // "collie/<name>"
    public var baseBranch: String    // pasture's branch at creation
    public var status: PaddockStatus
    public var createdBy: UUID?      // creating Shepherd terminal; nil = app
    public var landedAt: Date?
    public var designSystem: UUID?   // the paddock's own active design system; nil = the workspace's
    public init(id: UUID, name: String, repoRoot: String, path: String, branch: String, baseBranch: String,
                status: PaddockStatus = .working, createdBy: UUID? = nil, landedAt: Date? = nil, designSystem: UUID? = nil) {
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

/// Whether the Shepherd should have UI work designed first: ask the user, always, or never.
public enum DesignFirst: String, Codable, Sendable, CaseIterable { case ask, always, never }

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 3
    public var id: UUID
    public var name: String
    public var terminals: [TerminalRecord]
    public var connections: [Connection]
    public var paddocks: [Paddock]
    public var panels: [Panel]
    public var designSystem: UUID?   // active design system of pasture and of paddocks without their own
    public var designFirst: DesignFirst = .ask   // set only by `design.prefer` / Preferences
    public init(id: UUID, name: String, terminals: [TerminalRecord] = [], connections: [Connection] = [], paddocks: [Paddock] = [], panels: [Panel] = []) {
        self.id = id; self.name = name; self.terminals = terminals; self.connections = connections; self.paddocks = paddocks; self.panels = panels
    }
    private enum K: String, CodingKey { case schemaVersion, id, name, terminals, connections, paddocks, panels, designSystem, designFirst }
    private enum Legacy: String, CodingKey { case floors }   // before the herding vocabulary
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        terminals = try c.decode([TerminalRecord].self, forKey: .terminals)
        connections = try c.decode([Connection].self, forKey: .connections)
        paddocks = try c.decodeIfPresent([Paddock].self, forKey: .paddocks)
            ?? decoder.container(keyedBy: Legacy.self).decodeIfPresent([Paddock].self, forKey: .floors) ?? []   // v1 files have none
        panels = try c.decodeIfPresent([Panel].self, forKey: .panels) ?? []   // v1/v2 files have none
        designSystem = try c.decodeIfPresent(UUID.self, forKey: .designSystem)
        designFirst = try c.decodeIfPresent(DesignFirst.self, forKey: .designFirst) ?? .ask
    }
    // schemaVersion always writes the current version (a decoded v1 file is re-saved as 3).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(terminals, forKey: .terminals); try c.encode(connections, forKey: .connections); try c.encode(paddocks, forKey: .paddocks)
        try c.encode(panels, forKey: .panels); try c.encodeIfPresent(designSystem, forKey: .designSystem)
        if designFirst != .ask { try c.encode(designFirst, forKey: .designFirst) }   // ponytail: the default is never written
    }
}
