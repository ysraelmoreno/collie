import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct AgentLaunchTests {
    let collie = URL(fileURLWithPath: "/opt/o rq/collie")
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("al-\(UUID().uuidString)") }
    func rec(_ p: Preset, _ c: String? = nil) -> TerminalRecord { TerminalRecord(id: UUID(), name: "A", preset: p, command: c, cwd: "/tmp", isMaestro: false) }

    @Test func claudeSpecUsesSettingsFlag() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude)
        let s = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        let file = dir.appendingPathComponent("\(r.id.uuidString).claude.json")
        #expect(s.arguments[0] == "-lc" && s.arguments[1].contains("--settings '\(file.path)'"))
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let entry = (((o["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        let cmd = entry["command"] as! String
        #expect(entry["timeout"] as? Int == 10)
        #expect(cmd.hasSuffix("hook claude-stop") && cmd.hasPrefix("'/opt/o rq/collie'"))
        let note = (((o["hooks"] as! [String: Any])["Notification"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        #expect((note["command"] as! String).hasSuffix("hook claude-notification") && note["timeout"] as? Int == 5)
        let perm = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        #expect(perm == 0o600)
    }
    @Test func claudeExplicitCommandRules() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try AgentLaunch.launchSpec(for: rec(.claude, "claude --model x"), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(a.arguments[1].hasPrefix("claude --model x --settings "))
        let b = try AgentLaunch.launchSpec(for: rec(.claude, "echo hi"), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(b.arguments == ["-lc", "echo hi"])
        let c = try AgentLaunch.launchSpec(for: rec(.shell), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(c.arguments == ["-l"])
        #expect(throws: (any Error).self) { try AgentLaunch.launchSpec(for: rec(.custom), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh") }
    }
    @Test func codexSpecUsesNotifyOverride() throws {
        let s = try AgentLaunch.launchSpec(for: rec(.codex), env: [:], hooksDir: tmp(), collie: collie, shell: "/bin/zsh")
        #expect(s.arguments[1] == #"codex -c 'notify=["/opt/o rq/collie","hook","codex-notify"]'"#)   // MCP is opt-in
    }
    @Test func mcpConfigWritten() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude)
        let s = try AgentLaunch.launchSpec(for: r, env: ["COLLIE_TOKEN": "sekret-token"], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        let file = dir.appendingPathComponent("\(r.id.uuidString).mcp.json")
        #expect(s.arguments[1].contains("--mcp-config '\(file.path)'"))
        let data = try Data(contentsOf: file), text = String(decoding: data, as: UTF8.self)
        let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = (o["mcpServers"] as! [String: Any])["collie"] as! [String: Any]
        #expect(server["type"] as? String == "stdio" && server["command"] as? String == "/opt/o rq/collie")
        #expect(server["args"] as? [String] == ["mcp"] && server["env"] == nil)
        #expect(!text.contains("COLLIE_TOKEN") && !text.contains("sekret-token") && !s.arguments[1].contains("sekret-token"))
        let perm = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        #expect(perm == 0o600)
    }
    @Test func mcpConfigIsAdditive() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try AgentLaunch.launchSpec(for: rec(.claude), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(s.arguments[1].contains(" --mcp-config ") && !s.arguments[1].contains("--strict-mcp-config"))
    }
    @Test func customClaudeCommandGetsMcp() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude, "claude --model x")
        let s = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(s.arguments[1].hasPrefix("claude --model x --settings ")
                && s.arguments[1].hasSuffix("--mcp-config '\(dir.appendingPathComponent("\(r.id.uuidString).mcp.json").path)'"))
    }
    @Test func removeHooksRemovesMcp() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude)
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(r.id.uuidString).mcp.json").path))
        AgentLaunch.removeHooks(for: r.id, in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
    @Test func codexGetsMcpWithoutSecretsInArgv() throws {
        let s = try AgentLaunch.launchSpec(for: rec(.codex), env: ["COLLIE_TOKEN": "sekret-token"], hooksDir: tmp(), collie: collie, shell: "/bin/zsh",
                                           codexMCP: true)
        #expect(s.arguments[1] == #"codex -c 'notify=["/opt/o rq/collie","hook","codex-notify"]'"#
                + #" -c 'mcp_servers.collie.command="/opt/o rq/collie"' -c 'mcp_servers.collie.args=["mcp"]'"#
                + #" -c 'mcp_servers.collie.env_vars=["COLLIE_SOCKET","COLLIE_TERMINAL_ID","COLLIE_TOKEN","COLLIE_TERMINAL_NAME","COLLIE_WORKSPACE_ID","COLLIE_MAESTRO"]'"#)
        #expect(!s.arguments[1].contains("sekret-token"))
    }
    @Test func noGlobalSettingsTouched() throws {
        let home = tmp(), dir = tmp()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: dir) }
        for p in [Preset.claude, .codex, .shell] {
            _ = try AgentLaunch.launchSpec(for: rec(p), env: ["HOME": home.path], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }
    @Test func colliePathWithQuoteIsShellQuoted() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude)
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: URL(fileURLWithPath: "/opt/it's/collie"), shell: "/bin/zsh")
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("\(r.id.uuidString).claude.json"))) as! [String: Any]
        let cmd = ((((o["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
        #expect(cmd == #"'/opt/it'\''s/collie' hook claude-stop"#)
        // sh must parse it back to the exact path as one word
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s|' " + cmd]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "/opt/it's/collie|hook|claude-stop|")
    }
}
