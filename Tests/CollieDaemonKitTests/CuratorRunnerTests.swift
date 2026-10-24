import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixture = #"{"type":"result","is_error":false,"result":"…","structured_output":{"ops":[]},"usage":{"input_tokens":812,"output_tokens":40},"total_cost_usd":0.0011}"#

/// A fake `claude` in `<base>/bin` (outside the fake home) and the env a runner over the fake home gets (R2: never the real one).
private struct Fake {
    let f: FakeHome
    var bin: URL { f.base.appendingPathComponent("bin") }
    var rec: URL { f.base.appendingPathComponent("rec") }
    init(_ script: String) throws { try self.init { _ in script } }
    /// `script(rec)`: `rec` is a file next to the fake home (temp, outside it: writable under the profile).
    init(_ script: (URL) -> String) throws {
        f = try FakeHome(git: false, socket: false)
        let script = script(f.base.appendingPathComponent("rec"))
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + script).write(to: claude, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }
    func runner(path: String? = nil) -> ClaudeCuratorRunner {
        let env = ["PATH": path ?? (bin.path + ":/usr/bin:/bin"), "HOME": f.home.path,
                   "COLLIE_SOCKET": "/x.sock", "COLLIE_TOKEN": "t", "COLLIE_TERMINAL_ID": "i"]
        return ClaudeCuratorRunner(root: f.collie, home: f.home, env: { env })
    }
}

private let call = CuratorCall(instructions: "be terse", input: "--dangerously-skip-permissions oi", schema: #"{"type":"object"}"#)

@Suite(.serialized) struct CuratorRunnerTests {
    @Test func argumentsPinned() {
        let a = ClaudeCuratorRunner.arguments(call, model: "haiku")
        let pinned = ["-p", "--model", "--output-format", "--json-schema", "--tools", "--strict-mcp-config", "--mcp-config",
                      "--setting-sources", "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
                      "--permission-prompts", "--max-budget-usd", "--system-prompt"]
        let at = pinned.compactMap { a.firstIndex(of: $0) }
        #expect(at.count == pinned.count && at == at.sorted(), "\(a)")
        #expect(a[a.firstIndex(of: "--model")! + 1] == "haiku")
        #expect(a[a.firstIndex(of: "--tools")! + 1] == "")
        #expect(a[a.firstIndex(of: "--mcp-config")! + 1] == #"{"mcpServers":{}}"#)
        #expect(a[a.firstIndex(of: "--setting-sources")! + 1] == "project,local")
        #expect(a[a.firstIndex(of: "--permission-prompts")! + 1] == "none")
        #expect(a[a.firstIndex(of: "--max-budget-usd")! + 1] == "0.05")
        #expect(a[a.firstIndex(of: "--system-prompt")! + 1] == call.instructions)
        #expect(a[a.firstIndex(of: "--json-schema")! + 1] == call.schema)
        #expect(a.suffix(2) == ["--", call.input])   // an input that looks like a flag stays the prompt
        for bad in ["--bare", "--settings", "--plugin-dir", "--continue"] { #expect(!a.contains(bad)) }
    }

    @Test func parseStructuredOutput() throws {
        let o = try ClaudeCuratorRunner.parse(fixture)
        #expect(o.json == .object(["ops": .array([])]))
        #expect(o.inputTokens == 812 && o.outputTokens == 40 && o.costUSD == 0.0011)
    }

    @Test func parseResultString() throws {
        let o = try ClaudeCuratorRunner.parse(#"{"type":"result","is_error":false,"result":"{\"ops\":[]}","usage":{"input_tokens":812,"output_tokens":40},"total_cost_usd":0.0011}"#)
        #expect(o.json == .object(["ops": .array([])]))
        #expect(o.inputTokens == 812 && o.outputTokens == 40 && o.costUSD == 0.0011)
    }

    @Test func parseIsError() {
        #expect(throws: ProtocolError(code: .unavailable, message: "Credit balance is too low")) {
            try ClaudeCuratorRunner.parse(#"{"type":"result","is_error":true,"result":"Credit balance is too low"}"#)
        }
    }

    @Test func fakeClaudeRunsSandboxed() async throws {
        let fake = try Fake { rec in """
            { printf '%s\\n' "$@"; echo ---; env; echo ---; pwd; } > "$PWD/argv"
            cp "$PWD/argv" '\(rec.path)'
            touch "$HOME/outside" 2>/dev/null
            echo x >> "$HOME/.claude/settings.json" 2>/dev/null
            printf '%s' '\(fixture)'
            """ }
        let settings = fake.f.home.appendingPathComponent(".claude/settings.json")
        let before = try Data(contentsOf: settings)

        let o = try await fake.runner().run(call, model: "haiku", timeout: .seconds(30))
        #expect(o.json == .object(["ops": .array([])]) && o.inputTokens == 812)
        let rec = try String(contentsOf: fake.rec, encoding: .utf8)
        let parts = rec.components(separatedBy: "---\n")
        #expect(parts.count == 3)
        #expect(parts[0].contains("--strict-mcp-config\n") && parts[0].hasSuffix("--\n\(call.input)\n"))
        #expect(!parts[1].contains("COLLIE_SOCKET") && !parts[1].contains("COLLIE_TOKEN") && !parts[1].contains("COLLIE_TERMINAL_ID"))
        #expect(parts[1].contains("HOME=\(fake.f.home.path)\n"))
        #expect(!FileManager.default.fileExists(atPath: fake.f.home.appendingPathComponent("outside").path))
        #expect(try Data(contentsOf: settings) == before)
        let cwd = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!cwd.isEmpty && !FileManager.default.fileExists(atPath: cwd))
        let profile = fake.f.collie.appendingPathComponent("curator/curator.sb")
        #expect((try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func missingClaudeUnavailable() async throws {
        let fake = try Fake("exit 0\n")
        let r = fake.runner(path: "/usr/bin:/bin")
        #expect(await r.availability() == .unavailable("claude não encontrado"))
        await #expect(throws: ProtocolError(code: .unavailable, message: "claude não encontrado")) {
            try await r.run(call, model: "haiku", timeout: .seconds(5))
        }
    }

    @Test func loggedOutUnavailable() async throws {
        let fake = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": false, "authMethod": "none"}'; exit 1; }; exit 2"# + "\n")
        #expect(await fake.runner().availability() == .unavailable("claude sem login"))
        let ok = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": true}'; exit 0; }; exit 2"# + "\n")
        #expect(await ok.runner().availability() == .available)
    }

    @Test func timeoutKills() async throws {
        let fake = try Fake("sleep 5\n")
        let start = ContinuousClock.now
        await #expect(throws: ProtocolError.self) {
            try await fake.runner().run(call, model: "haiku", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(BoundedProcess.livePids().isEmpty)
    }
}
