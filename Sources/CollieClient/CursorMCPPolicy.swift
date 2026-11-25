import CollieProtocol

/// The Cursor MCP client drops a tool call after ~60 s (`-32001`) while the target goes on working. For a Cursor
/// terminal the MCP server turns the blocking `ask` into `ask --no-wait` and cuts `wait` below that limit.
/// Measured 2026-11-24, cursor-agent 2026.11.22-e9042b2: a 50 s call returns, a 60 s one fails (spike REPORT §10).
public enum CursorMCPPolicy {
    public static let callTimeoutSeconds = 60
    public static let waitCapSeconds = callTimeoutSeconds - 10

    public enum Kind: Equatable, Sendable { case askDetached, waitCapped(Int) }
    public struct Adapted: Equatable, Sendable {
        public var args: [String: JSONValue]
        public var kind: Kind?
        public init(args: [String: JSONValue], kind: Kind?) { self.args = args; self.kind = kind }
    }

    /// `agent` is `memory.mcp-profile`'s; anything but "cursor" (or none) changes nothing.
    public static func adapt(agent: String?, command: String, args: [String: JSONValue]) -> Adapted {
        var a = args
        guard agent == "cursor" else { return .init(args: a, kind: nil) }
        switch command {
        case "ask" where a["no-wait"] != .bool(true):
            a["no-wait"] = .bool(true)
            return .init(args: a, kind: .askDetached)
        case "wait":
            if case .number(let t)? = a["timeout"], t <= Double(waitCapSeconds) { break }
            a["timeout"] = .number(Double(waitCapSeconds))
            return .init(args: a, kind: .waitCapped(waitCapSeconds))
        default: break
        }
        return .init(args: a, kind: nil)
    }

    /// One line for the detached ask's result (nil: no id, show the raw result).
    public static func askNote(result: JSONValue) -> String? {
        guard case .object(let o) = result, case .string(let id)? = o["askId"] else { return nil }
        return "Ask \(id) sent (not waiting: this client drops calls near \(callTimeoutSeconds) s). The reply arrives as a message, or run ask result \(id)."
    }

    public static func waitNote(target: String, seconds: Int) -> String {
        "'\(target)' is still working after \(seconds)s (this client drops calls near \(callTimeoutSeconds) s). Not done: call wait again to keep waiting."
    }
}
