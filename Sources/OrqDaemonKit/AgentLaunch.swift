import Foundation
import OrqCore
import OrqProtocol
import OrqTerminal

public enum AgentLaunch {
    /// Single-quote for POSIX sh.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func settingsFile(_ id: UUID, in hooksDir: URL) -> URL {
        hooksDir.appendingPathComponent("\(id.uuidString).claude.json")
    }
    public static func mcpFile(_ id: UUID, in hooksDir: URL) -> URL {
        hooksDir.appendingPathComponent("\(id.uuidString).mcp.json")
    }
    public static func removeHooks(for id: UUID, in hooksDir: URL) {
        try? FileManager.default.removeItem(at: settingsFile(id, in: hooksDir))
        try? FileManager.default.removeItem(at: mcpFile(id, in: hooksDir))
    }
    /// Env names the `orq mcp` child needs from the agent (names only: values never reach argv or files).
    static let mcpEnv = ["ORQ_SOCKET", "ORQ_TERMINAL_ID", "ORQ_TOKEN", "ORQ_TERMINAL_NAME", "ORQ_WORKSPACE_ID", "ORQ_MAESTRO"]
    /// JSON (and TOML-compatible) literal of a string or string array.
    static func literal(_ v: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    /// `env` is used verbatim as the child environment; hooks are wired by flag only (no global config touched).
    /// `codexMCP`: also give Codex the orq MCP server (opt-in, `ORQ_CODEX_MCP=1` in the daemon env: its `env_vars` key is
    /// unverified against an installed codex, and an unknown key could stop Codex from launching).
    public static func launchSpec(for rec: TerminalRecord, env: [String: String], hooksDir: URL, orq: URL, shell: String,
                                  codexMCP: Bool = false) throws -> LaunchSpec {
        func spec(_ args: [String]) -> LaunchSpec { LaunchSpec(executable: shell, arguments: args, environment: env, cwd: rec.cwd) }
        func claude(_ base: String) throws -> LaunchSpec {
            let f = settingsFile(rec.id, in: hooksDir)
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func hook(_ sub: String, _ timeout: Int, matcher: String? = nil) -> [[String: Any]] {
                var e: [String: Any] = ["hooks": [["type": "command", "command": quote(orq.path) + " hook " + sub, "timeout": timeout]]]
                if let matcher { e["matcher"] = matcher }
                return [e]
            }
            let json: [String: Any] = ["hooks": ["Stop": hook("claude-stop", 10),
                                                 "SessionStart": hook("claude-session-start", 5),
                                                 "UserPromptSubmit": hook("claude-prompt", 5),
                                                 // the work registry (WorkHookParser)
                                                 "PostToolUse": hook("claude-tool", 5, matcher: "TodoWrite|Task.*|Agent|Bash|BashOutput|KillShell"),
                                                 "SubagentStop": hook("claude-subagent-stop", 5),
                                                 "PreCompact": hook("claude-precompact", 5),
                                                 "SessionEnd": hook("claude-session-end", 5),
                                                 // permission dialogs: a pending approval (ApprovalTracker)
                                                 "Notification": hook("claude-notification", 5)]]
            func write(_ o: [String: Any], _ to: URL) throws {
                let data = try JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])
                guard FileManager.default.createFile(atPath: to.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try write(json, f)
            // no `env`: the MCP child inherits ORQ_SOCKET/ORQ_TERMINAL_ID/ORQ_TOKEN from claude, like the hooks.
            // Additive (no --strict-mcp-config): the user's own MCP servers stay.
            let m = mcpFile(rec.id, in: hooksDir)
            try write(["mcpServers": ["orq": ["type": "stdio", "command": orq.path, "args": ["mcp"]]]], m)
            return spec(["-lc", base + " --settings " + quote(f.path) + " --mcp-config " + quote(m.path)])
        }
        if let c = rec.command {
            if rec.preset == .claude, c.split(whereSeparator: \.isWhitespace).first == "claude" { return try claude(c) }
            return spec(["-lc", c])
        }
        switch rec.preset {
        case .shell: return spec(["-l"])
        case .claude: return try claude("claude")
        case .codex:
            // TOML basic strings/arrays; JSON string escaping is compatible. `env_vars` forwards the names only.
            var o = ["notify=" + literal([orq.path, "hook", "codex-notify"])]
            if codexMCP {
                o += ["mcp_servers.orq.command=" + literal(orq.path), "mcp_servers.orq.args=" + literal(["mcp"]),
                      "mcp_servers.orq.env_vars=" + literal(mcpEnv)]
            }
            return spec(["-lc", "codex" + o.map { " -c " + quote($0) }.joined()])
        case .custom: throw ProtocolError(code: .invalidArgs, message: "custom preset needs a command")
        }
    }
}
