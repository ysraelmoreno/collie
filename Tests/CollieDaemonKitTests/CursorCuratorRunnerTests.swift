import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// The owner's R2/R3 (cursor-agent 2026.11.17), sanitized: no personal data.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/curator")
private func fixture(_ name: String) throws -> String { try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8) }

private let call = CuratorCall(instructions: "be terse", input: "--force oi DADOS", schema: #"{"type":"object","required":["ops"]}"#)

/// A fake `cursor-agent` in `<base>/bin`: `status` and `models` answer from fixtures; `-p` records argv, env, stdin and
/// the config it found (`rec`, `rec.in`), then runs `body` (default: print the R3 result).
private struct Fake {
    let base: URL
    var root: URL { base.appendingPathComponent("collie") }
    var bin: URL { base.appendingPathComponent("bin") }
    var rec: URL { base.appendingPathComponent("rec") }
    var home: URL { CursorCuratorRunner.home(root) }

    init(status: String = "cursor-status-authenticated.json", home: Bool = true, body: String? = nil) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("collie-cursor-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if home { try fm.createDirectory(at: CursorCuratorRunner.home(base.appendingPathComponent("collie")), withIntermediateDirectories: true) }
        let rec = base.appendingPathComponent("rec").path
        let script = """
            #!/bin/sh
            case "$1" in
              status) cat '\(fixtures.appendingPathComponent(status).path)'; exit 0 ;;
              models) printf 'Available models\\n\\nauto - Auto (default)\\ncomposer-2.5 - Composer 2.5\\n'; exit 0 ;;
            esac
            { printf '%s\\n' "$@"; echo ---; env | sort; echo ---; cat "$CURSOR_CONFIG_DIR/cli-config.json"; } > '\(rec)'
            cat > '\(rec).in'
            \(body ?? "cat '\(fixtures.appendingPathComponent("cursor-result.json").path)'")

            """
        let exe = base.appendingPathComponent("bin/cursor-agent")
        try script.write(to: exe, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }
    func runner(path: String? = nil, retryAfter: Duration = .seconds(30)) -> CursorCuratorRunner {
        let p = path ?? (bin.path + ":/usr/bin:/bin")
        return CursorCuratorRunner(root: root, path: { p }, trust: .limited, retryAfter: retryAfter, fallback: [], sandboxed: false)
    }
    func recorded() throws -> [String] { try String(contentsOf: rec, encoding: .utf8).components(separatedBy: "---\n") }
}

@Suite(.serialized) struct CursorCuratorRunnerTests {
    @Test func argumentsPinned() {
        let cwd = URL(fileURLWithPath: "/tmp/w")
        #expect(CursorCuratorRunner.arguments(model: "auto", cwd: cwd)
                == ["-p", "--output-format", "json", "--mode", "ask", "--sandbox", "disabled", "--trust", "--workspace", "/tmp/w",
                    "--model", "auto"])
        let a = CursorCuratorRunner.arguments(model: "x", cwd: cwd)
        for bad in ["--force", "--yolo", "--approve-mcps", "--api-key", "--auth-token", "-H", "-e", "--endpoint", "--plugin-dir",
                    "--worktree", "--resume", "--continue"] { #expect(!a.contains(bad), "\(bad)") }
    }

    @Test func noModelFlagWhenEmpty() {
        #expect(!CursorCuratorRunner.arguments(model: "", cwd: URL(fileURLWithPath: "/tmp/w")).contains("--model"))
    }

    @Test func infoIsCursorLimited() {
        let i = CursorCuratorRunner(root: URL(fileURLWithPath: "/x"), path: { "" }, trust: .limited).info
        #expect(i == CuratorProviderInfo(provider: .cursor, trust: .limited, destination: "Cursor", structuredOutput: false,
                                         reportsUsage: true, timeout: .seconds(120), inputMax: 12_000))
    }

    /// Built from nothing: the user's CURSOR_API_KEY & co. can't reach it; HOME is the curator's own cursor-home.
    @Test func envIsolated() async throws {
        let root = URL(fileURLWithPath: "/r")
        let e = CursorCuratorRunner.environment(root: root, path: "/usr/bin")
        #expect(Set(e.keys) == ["HOME", "CURSOR_CONFIG_DIR", "AGENT_CLI_CREDENTIAL_STORE", "PATH", "LANG", "TMPDIR"])
        #expect(e["HOME"] == "/r/curator/cursor-home" && e["CURSOR_CONFIG_DIR"] == "/r/curator/cursor-home/.cursor")
        #expect(e["AGENT_CLI_CREDENTIAL_STORE"] == "file")
        let f = try Fake()
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        let env = try f.recorded()[1]
        for k in ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN", "CURSOR_API_ENDPOINT", "XDG_CONFIG_HOME", "COLLIE_SOCKET", "COLLIE_TOKEN", "ANTHROPIC_API_KEY"] {
            #expect(!env.contains(k + "="), "\(k)")
        }
        #expect(env.contains("HOME=\(f.home.path)\n"))
    }

    /// Written before every call whatever was there; the prompt (instructions, the exact line, schema, input) on stdin.
    @Test func closedConfigWrittenAndPromptOnStdin() async throws {
        let f = try Fake()
        try FileManager.default.createDirectory(at: f.home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try #"{"approvalMode":"unrestricted"}"#.write(to: f.home.appendingPathComponent(".cursor/cli-config.json"), atomically: false, encoding: .utf8)
        let o = try await f.runner().run(call, model: "auto", timeout: .seconds(20))
        let parts = try f.recorded()
        #expect(parts[2].trimmingCharacters(in: .whitespacesAndNewlines) == CursorCuratorRunner.closedConfig)
        #expect(!parts[0].contains(call.input) && parts[0].contains("--model\nauto\n"))
        let stdin = try String(contentsOf: URL(fileURLWithPath: f.rec.path + ".in"), encoding: .utf8)
        #expect(stdin == CursorCuratorRunner.prompt(call))
        #expect(stdin.contains(CursorCuratorRunner.schemaLine + "\n" + call.schema) && stdin.hasSuffix(call.input))
        #expect(CursorCuratorRunner.schemaLine == "Responda só com um objeto JSON que siga este JSON Schema, sem texto antes ou depois:")
        #expect(o.json == .object(["ops": .array([])]) && o.inputTokens == 10_178 && o.outputTokens == 70 && o.costUSD == nil)
    }

    /// R3: the CLI rewrites its config adding keys (kept), but a changed allowlist or deny means the answer isn't trusted.
    @Test func configCheckedAfterCall() async throws {
        let extra = #"{"version":1,"approvalMode":"allowlist","permissions":{"allow":[],"deny":["Shell(*)","Write(**)","Read(**)","WebFetch(*)","Mcp(*:*)"]},"model":"auto","network":{}}"#
        let kept = try Fake(body: "printf '%s' '\(extra)' > \"$CURSOR_CONFIG_DIR/cli-config.json\"; cat '\(fixtures.path)/cursor-result.json'")
        #expect(try await kept.runner().run(call, model: "", timeout: .seconds(20)).inputTokens == 10_178)
        let open = #"{"version":1,"approvalMode":"unrestricted","permissions":{"allow":["Shell(*)"],"deny":[]}}"#
        let opened = try Fake(body: "printf '%s' '\(open)' > \"$CURSOR_CONFIG_DIR/cli-config.json\"; cat '\(fixtures.path)/cursor-result.json'")
        await #expect(throws: ProtocolError(code: .internal, message: CursorCuratorRunner.tampered)) {
            try await opened.runner().run(call, model: "", timeout: .seconds(20))
        }
    }

    @Test func parsesResult() throws {
        let o = try CursorCuratorRunner.parse(try fixture("cursor-result.json"), status: 0, stderr: "")
        #expect(o.json == .object(["ops": .array([])]) && o.inputTokens == 10_178 && o.outputTokens == 70 && o.costUSD == nil)
    }

    @Test func fencedJsonAccepted() throws {
        let fenced = #"{"type":"result","is_error":false,"result":"```json\n{\"ops\":[]}\n```","usage":{"inputTokens":1,"outputTokens":2}}"#
        #expect(try CursorCuratorRunner.parse(fenced, status: 0, stderr: "").json == .object(["ops": .array([])]))
    }

    @Test func proseIsJunk() {
        for out in [#"{"type":"result","is_error":false,"result":"Claro! Aqui está: {\"ops\":[]}"}"#, "texto solto", ""] {
            #expect(throws: ProtocolError(code: .unavailable, message: "resposta ilegível do cursor"), "\(out)") {
                try CursorCuratorRunner.parse(out, status: 0, stderr: "")
            }
        }
    }

    @Test func isErrorThrows() {
        #expect(throws: ProtocolError(code: .unavailable, message: "boom")) {
            try CursorCuratorRunner.parse(#"{"type":"result","is_error":true,"result":"boom"}"#, status: 0, stderr: "")
        }
    }

    /// R3: exit 1, empty stdout, "Authentication required … 'agent login'" on stderr.
    @Test func authRequiredUnavailable() async throws {
        let stderr = try fixture("cursor-auth-required.txt")
        #expect(throws: ProtocolError(code: .unavailable, message: "cursor sem login para o curador")) {
            try CursorCuratorRunner.parse("", status: 1, stderr: stderr)
        }
        let f = try Fake(body: "cat '\(fixtures.path)/cursor-auth-required.txt' >&2; exit 1")
        let r = f.runner(retryAfter: .seconds(30))
        await #expect(throws: ProtocolError(code: .unavailable, message: "cursor sem login para o curador")) {
            try await r.run(call, model: "", timeout: .seconds(20))
        }
        #expect(await r.availability() == .unavailable("cursor sem login para o curador"))   // the run's answer is cached
    }

    /// NOT measured in R3 (no usage-limit error seen): the generic texts, as for Claude.
    @Test func usageLimitIsExhausted() async throws {
        #expect(throws: ProtocolError.self) { try CursorCuratorRunner.parse("", status: 1, stderr: "Error: You've hit your usage limit") }
        let f = try Fake(body: "echo 'Error: You have hit your usage limit' >&2; exit 1")
        let r = f.runner()
        await #expect(throws: ProtocolError.self) { try await r.run(call, model: "", timeout: .seconds(20)) }
        guard case .exhausted(_, let until) = await r.availability() else { Issue.record("not exhausted"); return }
        #expect(until.map { $0 > Date() } ?? false)
    }

    @Test func statusAuthenticated() async throws {
        #expect(CursorCuratorRunner.login(try fixture("cursor-status-authenticated.json")) == .available)
        #expect(await (try Fake()).runner().availability() == .available)
    }

    /// Only status/isAuthenticated are read: nothing of userInfo (e-mail, names, team) can come out.
    @Test func statusUnauthenticated() async throws {
        #expect(CursorCuratorRunner.login(try fixture("cursor-status-unauthenticated.json")) == .unavailable("cursor sem login para o curador"))
        #expect(await (try Fake(status: "cursor-status-unauthenticated.json")).runner().availability() == .unavailable("cursor sem login para o curador"))
        #expect(CursorCuratorRunner.login("{") == .unavailable("cursor não respondeu"))
        let a = CursorCuratorRunner.login(try fixture("cursor-status-authenticated.json"))
        #expect(!"\(a)".contains("example") && !"\(a)".contains("Example"))
    }

    @Test func missingCursorUnavailable() async throws {
        let f = try Fake()
        #expect(await f.runner(path: "/usr/bin:/bin").availability() == .unavailable("cursor não encontrado"))
        #expect(await f.runner(path: "").availability() == .unavailable(ClaudeCuratorRunner.envNotCaptured))
        await #expect(throws: ProtocolError(code: .unavailable, message: "cursor não encontrado")) {
            try await f.runner(path: "/usr/bin:/bin").run(call, model: "", timeout: .seconds(5))
        }
    }

    /// No cursor-home: never logged in for the curator; no `status` is run (Collie never logs in by itself).
    @Test func noCursorHomeUnavailable() async throws {
        let f = try Fake(home: false)
        #expect(await f.runner().availability() == .unavailable("cursor sem login para o curador"))
        #expect(await f.runner().models() == [])
        await #expect(throws: ProtocolError(code: .unavailable, message: "cursor sem login para o curador")) {
            try await f.runner().run(call, model: "", timeout: .seconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: f.rec.path) && !FileManager.default.fileExists(atPath: f.home.path))
    }

    /// "Entrar" (Preferences only): cursor-home made 0700, and the login line for the user's terminal, in it alone.
    @Test func loginCommandInOwnHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-cl-\(UUID().uuidString.prefix(8))/it's")
        let cmd = try CursorCuratorRunner.prepareLogin(root: root, exe: URL(fileURLWithPath: "/u/.local/bin/cursor-agent"))
        let h = CursorCuratorRunner.home(root).path
        #expect(cmd == "HOME='\(h.replacingOccurrences(of: "'", with: "'\\''"))' CURSOR_CONFIG_DIR='\(h.replacingOccurrences(of: "'", with: "'\\''"))/.cursor' AGENT_CLI_CREDENTIAL_STORE=file exec '/u/.local/bin/cursor-agent' login")
        for d in [h, h + "/.cursor"] {
            #expect((try FileManager.default.attributesOfItem(atPath: d)[.posixPermissions] as? Int) == 0o700, "\(d)")
        }
    }

    @Test func modelsListed() async throws {
        #expect(await (try Fake()).runner().models() == ["auto", "composer-2.5"])
        #expect(CursorCuratorRunner.models("auto - Auto (default)\ngpt-5.4-nano-low - GPT\nNo models\n") == ["auto", "gpt-5.4-nano-low"])
    }

    /// The rendered profile: its own cursor-home only; nothing of the user's home, Claude's files or the Keychain.
    @Test func profileHasNoUserHome() {
        let home = NSHomeDirectory()
        let ch = URL(fileURLWithPath: "/Users/u/Library/Application Support/Collie/curator/cursor-home")
        let script = URL(fileURLWithPath: "/Users/u/.local/share/cursor-agent/versions/v/cursor-agent")
        let p = CuratorSandboxProfile.render(CuratorSandboxProfile.cursor(script: script, cwd: URL(fileURLWithPath: "/private/tmp/w"), cursorHome: ch))
        for bad in ["\"\(home)/.cursor", "\"\(home)/.claude", "Library/Keychains", "\"/Users/u/.cursor", "\"/Users/u/.claude", "securityd"] {
            #expect(!p.contains(bad), "\(bad)")
        }
        #expect(p.contains("(allow file-write* (subpath \"\(ch.path)\"))"))
        for x in ["node", "cursor-agent-sea", "cursor-agent-worker-sea"] {
            #expect(p.contains("(allow process-exec (literal \"/Users/u/.local/share/cursor-agent/versions/v/\(x)\"))"), "\(x)")
        }
        for x in ["/usr/bin/env", "/bin/bash", "/usr/bin/realpath", "/usr/bin/dirname", "/usr/bin/basename"] {
            #expect(p.contains("(allow process-exec (literal \"\(x)\"))"), "\(x)")
        }
    }
}
