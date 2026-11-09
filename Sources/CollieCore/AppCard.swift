import Foundation

/// An app do cercado waiting for the user (spec 2026-11-08-paddock-apps-design.md): its approval in a paddock
/// (`approve`: Aprovar pins `sha256`), or one call of a `confirm` command (`confirm`: Permitir / Negar). Only the app
/// (admin) answers; an agent never does.
public struct AppCard: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case approve, confirm }
    public var id: UUID
    public var kind: Kind
    public var paddock: UUID
    public var paddockName: String
    public var app: String
    public var name: String
    public var base: String?
    /// approve: the commands, `confirm` ones marked; confirm: empty.
    public var commands: [String]
    public var events: [String]
    /// approve: the manifest (+ `ui/`) hash that Aprovar pins.
    public var sha256: String
    /// confirm: the call, as the user reads it ("restart api-gateway"), and its command (`restart`).
    public var call: String?
    public var command: String?
    /// The terminal that asked (attach, or the call); nil: the user.
    public var by: UUID?
    public var at: Date
    /// approve: the command the daemon will run for the app's service (`service.start`), shown as "Vai rodar".
    public var start: String?
    public init(id: UUID = UUID(), kind: Kind, paddock: UUID, paddockName: String, app: String, name: String, base: String?,
                commands: [String] = [], events: [String] = [], sha256: String = "", call: String? = nil, command: String? = nil, by: UUID?, at: Date = Date(), start: String? = nil) {
        self.id = id; self.kind = kind; self.paddock = paddock; self.paddockName = paddockName; self.app = app; self.name = name
        self.base = base; self.commands = commands; self.events = events; self.sha256 = sha256; self.call = call; self.command = command; self.by = by; self.at = at; self.start = start
    }
}
