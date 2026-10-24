import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

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
    /// Env names the `collie mcp` child needs from the agent (names only: values never reach argv or files).
    static let mcpEnv = ["COLLIE_SOCKET", "COLLIE_TERMINAL_ID", "COLLIE_TOKEN", "COLLIE_TERMINAL_NAME", "COLLIE_WORKSPACE_ID", "COLLIE_SHEPHERD"]
    /// Claude has an earlier conversation for `cwd` (R25): a session file in `<config>/projects/<cwd, every
    /// non-alphanumeric character a dash>` (the unresolved or resolved cwd). `<config>`: `CLAUDE_CONFIG_DIR` from the
    /// terminal's `env`, else `~/.claude`. A name over 200 characters Claude cuts and suffixes with a hash: any dir with
    /// that 200-character prefix counts. ponytail: a near-twin long cwd may match (a plain `--continue` that finds nothing)
    static func hasClaudeConversation(cwd: String, home: URL, env: [String: String] = [:]) -> Bool {
        let dir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            .map { $0.appendingPathComponent("projects") } ?? home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        func sessions(_ name: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(name).path)) ?? []).contains { $0.hasSuffix(".jsonl") }
        }
        return Set([cwd, SignedAppCheck.realPath(URL(fileURLWithPath: cwd))]).contains { c in
            let enc = String(c.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            guard enc.count > 200 else { return sessions(enc) }
            let head = String(enc.prefix(200))
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasPrefix(head) && sessions($0) }
        }
    }
    /// JSON (and TOML-compatible) literal of a string or string array.
    static func literal(_ v: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    /// `rec` launches Claude (with Collie's settings file): the preset, or a claude/custom command whose program is `claude`.
    static func isClaude(_ rec: TerminalRecord) -> Bool {
        guard let c = rec.command else { return rec.preset == .claude }
        return (rec.preset == .claude || rec.preset == .custom) && EssentialPaths.commandAgent(c)?.name == "claude"
    }

    /// `env` is used verbatim as the child environment; hooks are wired by flag only (no global config touched).
    /// `codexMCP`: also give Codex the collie MCP server (opt-in, `COLLIE_CODEX_MCP=1` in the daemon env: its `env_vars` key is
    /// unverified against an installed codex, and an unknown key could stop Codex from launching).
    /// `resume`: restarted after a sandbox grant/revoke, the conversation goes on: Claude `--continue`. Codex and Cursor
    /// relaunch plain (their resume flags weren't confirmed by the spike; the app's card says so).
    /// `innerSandboxOff`: the terminal runs in Collie's sandbox, where Seatbelt can't nest (Task 1): agents start with
    /// their own sandbox off (Claude `sandbox.enabled false` in Collie's settings file, never the user's; Codex
    /// `--sandbox danger-full-access`; a custom `cursor-agent` command `--sandbox disabled`). Collie's still applies.
    /// `filesDir`: the sandboxed terminal's handed-over files (`SandboxLaunch.handOver`); Claude gets it as a working
    /// directory (`permissions.additionalDirectories`, in Collie's settings file only), so reading one never prompts.
    /// `pluginDir`: Claude only, `--plugin-dir` (the terminal's procedures as skills, `ProcedureSkills`).
    public static func launchSpec(for rec: TerminalRecord, env: [String: String], hooksDir: URL, collie: URL, shell: String,
                                  codexMCP: Bool = false, innerSandboxOff: Bool = false, resume: Bool = false,
                                  filesDir: URL? = nil, pluginDir: URL? = nil) throws -> LaunchSpec {
        func spec(_ args: [String]) -> LaunchSpec { LaunchSpec(executable: shell, arguments: args, environment: env, cwd: rec.cwd) }
        func claude(_ base: String) throws -> LaunchSpec {
            let f = settingsFile(rec.id, in: hooksDir)
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func hook(_ sub: String, _ timeout: Int, matcher: String? = nil) -> [[String: Any]] {
                var e: [String: Any] = ["hooks": [["type": "command", "command": quote(collie.path) + " hook " + sub, "timeout": timeout]]]
                if let matcher { e["matcher"] = matcher }
                return [e]
            }
            var json: [String: Any] = [
                // plan usage (ClaudeRateLimits): the hook records rate_limits, then runs the user's own statusLine
                "statusLine": ["type": "command", "command": quote(collie.path) + " hook claude-statusline", "padding": 0],
                "hooks": ["Stop": hook("claude-stop", 10),
                                                 "SessionStart": hook("claude-session-start", 5),
                                                 "UserPromptSubmit": hook("claude-prompt", 5),
                                                 // the work registry (WorkHookParser)
                                                 "PostToolUse": hook("claude-tool", 5, matcher: "TodoWrite|Task.*|Agent|Bash|BashOutput|KillShell"),
                                                 "SubagentStop": hook("claude-subagent-stop", 5),
                                                 "PreCompact": hook("claude-precompact", 5),
                                                 "SessionEnd": hook("claude-session-end", 5),
                                                 // permission dialogs: a pending approval (ApprovalTracker)
                                                 "Notification": hook("claude-notification", 5)]]
            if innerSandboxOff { json["sandbox"] = ["enabled": false] }
            if let filesDir { json["permissions"] = ["additionalDirectories": [filesDir.path]] }
            func write(_ o: [String: Any], _ to: URL) throws {
                let data = try JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])
                guard FileManager.default.createFile(atPath: to.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try write(json, f)
            // no `env`: the MCP child inherits COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN from claude, like the hooks.
            // Additive (no --strict-mcp-config): the user's own MCP servers stay.
            let m = mcpFile(rec.id, in: hooksDir)
            try write(["mcpServers": ["collie": ["type": "stdio", "command": collie.path, "args": ["mcp"]]]], m)
            return spec(["-lc", base + " --settings " + quote(f.path) + " --mcp-config " + quote(m.path)
                         + (pluginDir.map { " --plugin-dir " + quote($0.path) } ?? "") + (resume ? " --continue" : "")])
        }
        if let c = rec.command {
            // M4: the program past `env VAR=…` and a path (R19/B3's detection): Claude gets Collie's settings file
            let agent = EssentialPaths.commandAgent(c)
            if isClaude(rec) { return try claude(c) }
            // a custom codex/cursor-agent command: the same inner-sandbox switch, unless it picks a sandbox itself
            if innerSandboxOff, let agent, !c.contains("--sandbox"),
               let flag = ["codex": " -c " + quote(#"sandbox_mode="danger-full-access""#), "cursor-agent": " --sandbox disabled"][agent.name] {
                return spec(["-lc", String(c[..<agent.end]) + flag + c[agent.end...]])
            }
            return spec(["-lc", c])
        }
        switch rec.preset {
        case .shell: return spec(["-l"])
        case .claude: return try claude("claude")
        case .codex:
            // TOML basic strings/arrays; JSON string escaping is compatible. `env_vars` forwards the names only.
            var o = ["notify=" + literal([collie.path, "hook", "codex-notify"])]
            if codexMCP {
                o += ["mcp_servers.collie.command=" + literal(collie.path), "mcp_servers.collie.args=" + literal(["mcp"]),
                      "mcp_servers.collie.env_vars=" + literal(mcpEnv)]
            }
            return spec(["-lc", "codex" + (innerSandboxOff ? " --sandbox danger-full-access" : "") + o.map { " -c " + quote($0) }.joined()])
        case .custom: throw ProtocolError(code: .invalidArgs, message: "custom preset needs a command")
        }
    }
}
