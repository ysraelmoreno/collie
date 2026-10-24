import Foundation

/// A path the user opened by an explicit click in the app: to one terminal (`owner` = its id) or to a lot (`owner` =
/// the lot's id: its current and future members). A write grant also reads.
public struct SandboxGrant: Codable, Sendable, Equatable, Identifiable {
    public enum Access: String, Codable, Sendable { case read, write }
    public enum Scope: String, Codable, Sendable { case terminal, lot }
    public var id: UUID
    public var path: String
    public var access: Access
    public var scope: Scope
    public var owner: UUID
    /// A terminal grant's project when it was clicked (R29): a reused id on another project loses it.
    public var project: String?
    public var createdAt: Date
    public init(id: UUID = UUID(), path: String, access: Access, scope: Scope, owner: UUID, project: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.path = path; self.access = access; self.scope = scope; self.owner = owner; self.project = project
        self.createdAt = createdAt
    }
}

/// One access card: a sandbox denial seen in the log (`requested` false) or an agent's `collie access request`.
/// One per (terminal, op, folder): `count` adds up the repeats, `path` is the first one seen.
public struct SandboxDenial: Codable, Sendable, Equatable {
    public var terminal: UUID
    /// read | write | delete | exec
    public var op: String
    public var path: String
    public var count: Int
    public var at: Date
    public var requested: Bool
    /// The agent's reason (requests only), scrubbed of secrets.
    public var reason: String?
    /// `path`'s parent: what **Liberar a pasta** opens.
    public var folder: String
    /// Why `path` can never be released (the card shows only **Negar**); nil: it can.
    public var refusal: String?
    /// Why the folder can't be released (too wide, or closed); nil: it can.
    public var folderRefusal: String?
    public init(terminal: UUID, op: String, path: String, count: Int = 1, at: Date = Date(), requested: Bool = false,
                reason: String? = nil, refusal: String? = nil, folderRefusal: String? = nil) {
        self.terminal = terminal; self.op = op; self.path = path; self.count = count; self.at = at
        self.requested = requested; self.reason = reason
        self.folder = (path as NSString).deletingLastPathComponent
        self.refusal = refusal; self.folderRefusal = folderRefusal
    }
    /// The grant this op needs.
    public var access: SandboxGrant.Access { op == "read" ? .read : .write }
}

extension TerminalRecord {
    /// Restarted after a grant, the agent can pick its conversation up again: Claude (`--continue`, when it had one,
    /// R25). Codex and Cursor start a new one (their resume wasn't confirmed by the spike).
    public var resumesConversation: Bool {
        preset == .claude && (command.map { $0.split(whereSeparator: \.isWhitespace).first == "claude" } ?? true)
    }
}
