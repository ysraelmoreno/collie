/// After an app-only update the newer app/CLI/MCP may talk to an older daemon (spec §4, compatibility contract):
/// a command that daemon lacks answers "Unknown command" — shown as "<cmd>: reinicie o serviço para usar isto".
public enum RestartHint {
    public static let text = "reinicie o serviço para usar isto"

    /// The daemon's "Unknown command" (router `Unknown command '<cmd>'`, parser `unknown command: <cmd>`) → same code,
    /// the hint; any other error untouched.
    public static func wrap(_ e: ProtocolError) -> ProtocolError {
        guard e.code == .invalidArgs,
              let m = e.message.wholeMatch(of: /[Uu]nknown command(?: '([^']+)'|: (\S+))/),
              let cmd = m.1 ?? m.2 else { return e }
        return ProtocolError(code: e.code, message: "\(cmd): \(text)", retryAfter: e.retryAfter)
    }
}
