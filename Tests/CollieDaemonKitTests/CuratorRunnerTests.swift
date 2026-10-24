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
    func runner(path: String? = nil, retryAfter: Duration = .seconds(30)) -> ClaudeCuratorRunner {
        let env = ["PATH": path ?? (bin.path + ":/usr/bin:/bin"), "HOME": f.home.path,
                   "COLLIE_SOCKET": "/x.sock", "COLLIE_TOKEN": "t", "COLLIE_TERMINAL_ID": "i",
                   "ANTHROPIC_API_KEY": "sk-x", "ANTHROPIC_AUTH_TOKEN": "tok-x", "ANTHROPIC_BASE_URL": "https://x",
                   "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1"]
        return ClaudeCuratorRunner(root: f.collie, home: f.home, env: { env }, retryAfter: retryAfter)
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
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
            #expect(!parts[1].contains(k + "="), "R5: the plan login, never a key or another provider (\(k))")
        }
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
        let fake = try Fake { rec in "echo $$ > '\(rec.path)'; sleep 5 & echo $! >> '\(rec.path)'; wait\n" }
        let start = ContinuousClock.now
        await #expect(throws: ProtocolError(code: .timeout, message: "claude não respondeu")) {
            try await fake.runner().run(call, model: "haiku", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
        // its own pids only (other suites may run a BoundedProcess meanwhile)
        let pids = try String(contentsOf: fake.rec, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
        #expect(pids.count == 2)
        for p in pids { #expect(kill(p, 0) != 0 && !BoundedProcess.livePids().contains(p), "\(p) survived") }
    }

    /// A banner line before the JSON (an update notice) and a fenced `result` still parse.
    @Test func parseTolerant() throws {
        #expect(try ClaudeCuratorRunner.parse("Update available: 2.2.0\n" + fixture + "\n").inputTokens == 812)
        let fenced = #"{"type":"result","is_error":false,"result":"```json\n{\"ops\":[]}\n```","usage":{"input_tokens":1,"output_tokens":2},"total_cost_usd":0}"#
        #expect(try ClaudeCuratorRunner.parse(fenced).json == .object(["ops": .array([])]))
        #expect(try ClaudeCuratorRunner.parse("[{\"type\":\"system\"}," + fixture + "]").outputTokens == 40)
        // a trailing unrelated JSON line (telemetry, a warning) can't shadow the answer
        #expect(try ClaudeCuratorRunner.parse(fixture + "\n{\"level\":\"warn\",\"msg\":\"x\"}\n").inputTokens == 812)
    }

    @Test func parseGarbageUnavailable() {
        for junk in ["", "oops", "{\"type\":\"result\",\"is_error\":false,\"result\":\"não é json\"}"] {
            #expect(throws: ProtocolError(code: .unavailable, message: ClaudeCuratorRunner.unreadable), "\(junk)") {
                try ClaudeCuratorRunner.parse(junk)
            }
        }
    }

    /// An auth-status that fails (junk, timeout) is not "sem login" for 10 min: retried soon; it runs in an empty temp cwd.
    @Test func authErrorRetried() async throws {
        let fake = try Fake { rec in """
            pwd >> '\(rec.path)'
            [ -f '\(rec.path).n' ] && { echo '{"loggedIn": true}'; exit 0; }
            touch '\(rec.path).n'; echo 'boom'; exit 3

            """ }
        let r = fake.runner(retryAfter: .zero)
        #expect(await r.availability() == .unavailable("claude não respondeu"))
        #expect(await r.availability() == .available)
        #expect(await r.availability() == .available)   // cached: no third run
        let cwds = try String(contentsOf: fake.rec, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(cwds.count == 2)
        for d in cwds { #expect(d != SignedAppCheck.realPath(fake.f.home) && d.contains("collie-curator-") && !FileManager.default.fileExists(atPath: d)) }
    }
}
