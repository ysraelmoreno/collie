import Foundation

public enum Preset: String, Codable, Sendable, CaseIterable { case shell, claude, codex, custom }

/// `free`: "Terminal livre (sem sandbox)", created only by the user in the app; unreachable by any leash.
public enum TerminalSandbox: String, Codable, Sendable {
    case sandboxed, free
    public init(from d: Decoder) throws {   // fail closed: an unknown value is sandboxed
        self = TerminalSandbox(rawValue: try d.singleValueContainer().decode(String.self)) ?? .sandboxed
    }
}

/// The sandbox of terminals started from now on (user decision 2026-10-25): `open` (the default) lets an agent read and
/// write everything in the account but Collie's own internals; `strict` is the closed profile (project writes, secrets
/// closed, access cards). Set only by the app (`admin.sandbox`).
public enum SandboxMode: String, Codable, Sendable, CaseIterable {
    case open, strict
    public init(from d: Decoder) throws {   // fail closed: an unknown value is strict
        self = SandboxMode(rawValue: try d.singleValueContainer().decode(String.self)) ?? .strict
    }
}

public struct TerminalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var preset: Preset
    public var command: String?
    public var cwd: String
    public var isShepherd: Bool
    public var paddockId: UUID?   // nil = pasture
    public var sandbox: TerminalSandbox
    /// Resolved project folder (git toplevel of the cwd, the paddock's worktree, else the folder); nil = not computed yet.
    public var projectRoot: String?
    /// The sandbox mode its last sandboxed start ran with (its profile, cards, cwd bounds); nil: none yet (strict rules).
    public var startMode: SandboxMode?
    public init(id: UUID, name: String, preset: Preset, command: String?, cwd: String, isShepherd: Bool, paddockId: UUID? = nil,
                sandbox: TerminalSandbox = .sandboxed, projectRoot: String? = nil) {
        self.id = id; self.name = name; self.preset = preset; self.command = command
        self.cwd = cwd; self.isShepherd = isShepherd; self.paddockId = paddockId
        self.sandbox = sandbox; self.projectRoot = projectRoot
    }
    private enum CodingKeys: String, CodingKey { case id, name, preset, command, cwd, isShepherd, paddockId, sandbox, projectRoot, startMode }
    private enum Legacy: String, CodingKey { case isMaestro, floorId }   // before the herding vocabulary
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), l = try d.container(keyedBy: Legacy.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        preset = try c.decode(Preset.self, forKey: .preset); command = try c.decodeIfPresent(String.self, forKey: .command)
        cwd = try c.decode(String.self, forKey: .cwd)
        isShepherd = try c.decodeIfPresent(Bool.self, forKey: .isShepherd) ?? l.decode(Bool.self, forKey: .isMaestro)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? l.decodeIfPresent(UUID.self, forKey: .floorId)
        sandbox = (try? c.decodeIfPresent(TerminalSandbox.self, forKey: .sandbox)) ?? .sandboxed   // records before the sandbox
        projectRoot = try c.decodeIfPresent(String.self, forKey: .projectRoot)
        startMode = try? c.decodeIfPresent(SandboxMode.self, forKey: .startMode)
    }
}

public enum PaddockStatus: String, Codable, Sendable { case working, blocked, review, done }
public enum LandMode: String, Codable, Sendable { case merge, squash, rebase, pr }

/// `worktree`: a git worktree on its own branch of the pasture. `folder`: an existing folder (git or not), worked in place:
/// no branch, no land, and its delete never touches the folder.
public enum PaddockKind: String, Codable, Sendable { case worktree, folder }

public struct Paddock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: PaddockKind = .worktree   // missing (records before folder paddocks) = worktree
    public var repoRoot: String      // toplevel of the main repo (pasture); a folder paddock's folder
    public var path: String          // <repoRoot>/.collie/paddocks/<name>; a folder paddock's folder
    public var branch: String        // "collie/<name>"; "" for a folder paddock
    public var baseBranch: String    // pasture's branch at creation; "" for a folder paddock
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
    /// A folder paddock: `path` is the folder, no git.
    public static func folder(id: UUID = UUID(), name: String, path: String, createdBy: UUID? = nil) -> Paddock {
        var f = Paddock(id: id, name: name, repoRoot: path, path: path, branch: "", baseBranch: "", createdBy: createdBy)
        f.kind = .folder
        return f
    }
    public var isFolder: Bool { kind == .folder }
    /// The branch, nil for a folder paddock.
    public var gitBranch: String? { isFolder ? nil : branch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(PaddockKind.self, forKey: .kind) ?? .worktree
        repoRoot = try c.decode(String.self, forKey: .repoRoot); path = try c.decode(String.self, forKey: .path)
        branch = try c.decode(String.self, forKey: .branch); baseBranch = try c.decode(String.self, forKey: .baseBranch)
        status = try c.decode(PaddockStatus.self, forKey: .status); createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        landedAt = try c.decodeIfPresent(Date.self, forKey: .landedAt); designSystem = try c.decodeIfPresent(UUID.self, forKey: .designSystem)
    }
}

public struct Connection: Codable, Sendable, Equatable {
    public var a: UUID
    public var b: UUID
    public init(a: UUID, b: UUID) { self.a = a; self.b = b }
}

/// "Onde desenhar": where the Shepherd has UI work designed first: a Prévia page (`artifact`, the default), FigCraft, or ask
/// the user. (Before: "design primeiro" ask|always|never; `always` is now `figcraft`, `never` `artifact`.)
public enum DesignFirst: String, Codable, Sendable, CaseIterable {
    case artifact, figcraft, ask
    /// A value, or one from before "Onde desenhar"; nil when unknown.
    public static func parse(_ s: String) -> DesignFirst? { DesignFirst(rawValue: s) ?? ["always": .figcraft, "never": .artifact][s] }
    /// Unknown (or not a string): the default, never an error.
    public init(from decoder: Decoder) throws {
        self = ((try? decoder.singleValueContainer().decode(String.self)).flatMap(Self.parse)) ?? .artifact
    }
}

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 3
    public var id: UUID
    public var name: String
    public var terminals: [TerminalRecord]
    public var connections: [Connection]
    public var paddocks: [Paddock]
    public var panels: [Panel]
    public var designSystem: UUID?   // active design system of pasture and of paddocks without their own
    public var designFirst: DesignFirst = .artifact   // set only by `design.prefer` / Preferences
    public var lots: [Lot] = []
    /// Before the mode became one Collie-wide preference (`<root>/preferences.json`): read once and moved there.
    public var terminalSandbox: SandboxMode?
    public init(id: UUID, name: String, terminals: [TerminalRecord] = [], connections: [Connection] = [], paddocks: [Paddock] = [], panels: [Panel] = []) {
        self.id = id; self.name = name; self.terminals = terminals; self.connections = connections; self.paddocks = paddocks; self.panels = panels
    }
    private enum K: String, CodingKey { case schemaVersion, id, name, terminals, connections, paddocks, panels, designSystem, designFirst, lots, terminalSandbox }
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
        designFirst = (try? c.decodeIfPresent(DesignFirst.self, forKey: .designFirst)) ?? .artifact   // an unknown value must never discard the workspace
        terminalSandbox = c.contains(.terminalSandbox)   // present but unreadable: strict (fail closed), never the workspace lost
            ? (try? c.decodeIfPresent(SandboxMode.self, forKey: .terminalSandbox)) ?? .strict : nil
        lots = ((try? c.decodeIfPresent([Lossy<Lot>].self, forKey: .lots)) ?? []).compactMap(\.value)   // a bad entry is dropped, never the workspace
    }
    // schemaVersion always writes the current version (a decoded v1 file is re-saved as 3).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(terminals, forKey: .terminals); try c.encode(connections, forKey: .connections); try c.encode(paddocks, forKey: .paddocks)
        try c.encode(panels, forKey: .panels); try c.encodeIfPresent(designSystem, forKey: .designSystem)
        if !lots.isEmpty { try c.encode(lots, forKey: .lots) }
        try c.encodeIfPresent(terminalSandbox, forKey: .terminalSandbox)
        if designFirst != .artifact { try c.encode(designFirst, forKey: .designFirst) }   // ponytail: the default is never written
    }
}
