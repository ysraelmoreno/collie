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

@Suite(.serialized, .curatorPT) struct CursorCuratorRunnerTests {
    @Test func argumentsPinned() {
        let cwd = URL(fileURLWithPath: "/tmp/w")
        #expect(CursorCuratorRunner.arguments(model: "auto", cwd: cwd)
                == ["-p", "--output-format", "json", "--mode", "ask", "--sandbox", "disabled", "--trust", "--workspace", "/tmp/w",
                    "--model=auto"])
        let a = CursorCuratorRunner.arguments(model: "x", cwd: cwd)
        for bad in ["--force", "--yolo", "--approve-mcps", "--api-key", "--auth-token", "-H", "-e", "--endpoint", "--plugin-dir",
                    "--worktree", "--resume", "--continue"] { #expect(!a.contains(bad), "\(bad)") }
    }

    /// A7: production runs it under its profile; only tests turn that off.
    @Test func sandboxedByDefault() {
        #expect(CursorCuratorRunner(root: URL(fileURLWithPath: "/x"), path: { "" }, trust: .limited).sandboxed)
    }

    /// A6: a model id from config.json edited by hand can't become a flag.
    @Test func badModelRefused() async throws {
        let f = try Fake()
        await #expect(throws: ProtocolError(code: .invalidArgs, message: Curator.badModel)) {
            try await f.runner().run(call, model: "--yolo", timeout: .seconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: f.rec.path))
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
        #expect(!parts[0].contains(call.input) && parts[0].contains("--model=auto\n"))
        let stdin = try String(contentsOf: URL(fileURLWithPath: f.rec.path + ".in"), encoding: .utf8)
        #expect(stdin == CursorCuratorRunner.prompt(call))
        #expect(stdin.contains(CursorCuratorRunner.schemaLine + "\n" + call.schema) && stdin.hasSuffix(call.input))
        #expect(CursorCuratorRunner.schemaLine == "Responda só com um objeto JSON que siga este JSON Schema, sem texto antes ou depois:")
        #expect(o.json == .object(["ops": .array([])]) && o.inputTokens == 10_178 && o.outputTokens == 70 && o.costUSD == nil)
    }

    /// R3: the CLI rewrites its config adding keys (kept), but a changed allowlist or deny means the answer isn't trusted.
    @Test func configCheckedAfterCall() async throws {
        let extra = #"{"version":1,"approvalMode":"allowlist","permissions":{"allow":[],"deny":["Shell(*)","Write(**)","Read(**)","WebFetch(*)","Mcp(*:*)"]},"autoAcceptWebSearch":false,"sandbox":{"mode":"disabled","networkAccess":"allowlist"},"model":"auto","network":{}}"#
        let kept = try Fake(body: "printf '%s' '\(extra)' > \"$CURSOR_CONFIG_DIR/cli-config.json\"; cat '\(fixtures.path)/cursor-result.json'")
        #expect(try await kept.runner().run(call, model: "", timeout: .seconds(20)).inputTokens == 10_178)
        let open = #"{"version":1,"approvalMode":"unrestricted","permissions":{"allow":["Shell(*)"],"deny":[]}}"#
        let opened = try Fake(body: "printf '%s' '\(open)' > \"$CURSOR_CONFIG_DIR/cli-config.json\"; cat '\(fixtures.path)/cursor-result.json'")
        await #expect(throws: ProtocolError(code: .internal, message: CursorCuratorRunner.tampered)) {
            try await opened.runner().run(call, model: "", timeout: .seconds(20))
        }
    }

    // A4: collied (outside the sandbox) writes in a dir the CLI controls: never through a link it planted.
    private func victim(_ f: Fake, _ text: String = "export SAFE=1\n") throws -> URL {
        let v = f.base.appendingPathComponent("zshrc")
        try text.write(to: v, atomically: false, encoding: .utf8)
        return v
    }

    @Test func plantedConfigSymlinkNotFollowed() async throws {
        let f = try Fake(), fm = FileManager.default
        let v = try victim(f)
        try fm.createDirectory(at: f.home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.runner().configFile, withDestinationURL: v)
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        #expect(try String(contentsOf: v, encoding: .utf8) == "export SAFE=1\n")
        #expect(CursorCuratorRunner.ownFile(f.runner().configFile))
        #expect(try f.recorded()[2].trimmingCharacters(in: .whitespacesAndNewlines) == CursorCuratorRunner.closedConfig)
    }

    @Test func plantedDotCursorSymlinkNotFollowed() async throws {
        let f = try Fake(), fm = FileManager.default
        let outside = f.base.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.home.appendingPathComponent(".cursor"), withDestinationURL: outside)
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(CursorCuratorRunner.ownDir(f.home.appendingPathComponent(".cursor")))
    }

    /// A cursor-home that is a link is never used (nor recreated: only "Entrar" makes it).
    @Test func cursorHomeSymlinkRefused() async throws {
        let f = try Fake(home: false), fm = FileManager.default
        let outside = f.base.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: f.home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.home, withDestinationURL: outside)
        await #expect(throws: ProtocolError(code: .unavailable, message: "cursor sem login para o curador")) {
            try await f.runner().run(call, model: "", timeout: .seconds(5))
        }
        #expect(await f.runner().availability() == .unavailable("cursor sem login para o curador", code: .noLogin))
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        // "Entrar" replaces the link with a real 0700 dir; nothing lands in the link's target
        _ = try CursorCuratorRunner.prepareLogin(root: f.root, exe: URL(fileURLWithPath: "/x/cursor-agent"))
        #expect(CursorCuratorRunner.ownDir(f.home) && !fm.fileExists(atPath: outside.appendingPathComponent(".cursor").path))
    }

    /// The CLI swapping its config for a link (even to a closed copy) or adding a hard link: the answer isn't trusted.
    @Test func swappedOrLinkedConfigIsTampered() async throws {
        let f0 = try Fake()
        let copy = f0.base.appendingPathComponent("copy.json")
        try CursorCuratorRunner.closedConfig.write(to: copy, atomically: false, encoding: .utf8)
        let swaps = ["rm \"$CURSOR_CONFIG_DIR/cli-config.json\"; ln -s '\(copy.path)' \"$CURSOR_CONFIG_DIR/cli-config.json\"",
                     "ln \"$CURSOR_CONFIG_DIR/cli-config.json\" '\(f0.base.path)/hard-\(UUID().uuidString)'"]
        for swap in swaps {
            let f = try Fake(body: swap + "; cat '\(fixtures.path)/cursor-result.json'")
            await #expect(throws: ProtocolError(code: .internal, message: CursorCuratorRunner.tampered), "\(swap)") {
                try await f.runner().run(call, model: "", timeout: .seconds(20))
            }
        }
    }

    /// A5: the check runs on a failed or is_error answer too, and covers sandbox.mode and autoAcceptWebSearch.
    @Test func tamperCheckedOnFailureToo() async throws {
        let open = #"{"version":1,"approvalMode":"unrestricted","permissions":{"allow":[],"deny":[]}}"#
        let f = try Fake(body: "printf '%s' '\(open)' > \"$CURSOR_CONFIG_DIR/cli-config.json\"; echo boom >&2; exit 1")
        await #expect(throws: ProtocolError(code: .internal, message: CursorCuratorRunner.tampered)) {
            try await f.runner().run(call, model: "", timeout: .seconds(20))
        }
        func with(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var o = try #require(try JSONSerialization.jsonObject(with: Data(CursorCuratorRunner.closedConfig.utf8)) as? [String: Any])
            edit(&o)
            return try JSONSerialization.data(withJSONObject: o)
        }
        #expect(CursorCuratorRunner.stillClosed(try with { $0["model"] = "auto"; $0["network"] = [:] }))
        #expect(!CursorCuratorRunner.stillClosed(try with { $0["sandbox"] = ["mode": "enabled"] }))
        #expect(!CursorCuratorRunner.stillClosed(try with { $0["sandbox"] = nil }))
        #expect(!CursorCuratorRunner.stillClosed(try with { $0["autoAcceptWebSearch"] = true }))
        #expect(!CursorCuratorRunner.stillClosed(try with { $0["autoAcceptWebSearch"] = nil }))
        #expect(!CursorCuratorRunner.stillClosed(try with { $0["permissions"] = ["allow": [], "deny": ["Shell(*)"]] }))
    }

    /// Every call: `.cursor` 0700 and `auth.json` 0600 (a linked auth.json is left alone, its target untouched).
    @Test func permissionsEveryCall() async throws {
        let f = try Fake(), fm = FileManager.default
        let dot = f.home.appendingPathComponent(".cursor"), auth = dot.appendingPathComponent("auth.json")
        try fm.createDirectory(at: dot, withIntermediateDirectories: true)
        try "{}".write(to: auth, atomically: false, encoding: .utf8)
        chmod(dot.path, 0o755); chmod(auth.path, 0o644)
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        func mode(_ u: URL) throws -> Int? { try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int }
        #expect(try mode(dot) == 0o700 && mode(auth) == 0o600 && mode(f.runner().configFile) == 0o600)
        let v = try victim(f); chmod(v.path, 0o644)
        try fm.removeItem(at: auth); try fm.createSymbolicLink(at: auth, withDestinationURL: v)
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        #expect(try mode(v) == 0o644)
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
            #expect(throws: ProtocolError(code: .unavailable, message: CursorCuratorRunner.unreadable), "\(out)") {
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
        #expect(await r.availability() == .unavailable("cursor sem login para o curador", code: .noLogin))   // the run's answer is cached
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
        #expect(CursorCuratorRunner.login(try fixture("cursor-status-unauthenticated.json")) == .unavailable("cursor sem login para o curador", code: .noLogin))
        #expect(await (try Fake(status: "cursor-status-unauthenticated.json")).runner().availability() == .unavailable("cursor sem login para o curador", code: .noLogin))
        #expect(CursorCuratorRunner.login("{") == .unavailable("cursor não respondeu", code: .noAnswer))
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
        #expect(await f.runner().availability() == .unavailable("cursor sem login para o curador", code: .noLogin))
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
        for bad in ["\"\(home)/.cursor", "\"\(home)/.claude", "Library/Keychains", "\"/Users/u/.cursor", "\"/Users/u/.claude", "securityd",
                    "SecurityServer", "\"/private/var/db\"", "/usr/bin/security", "com.apple.security"] {
            #expect(!p.contains(bad), "\(bad)")
        }
        #expect(p.contains("(allow file-write* (subpath \"\(ch.path)\"))"))
        for x in ["node", "cursor-agent-sea", "cursor-agent-worker-sea"] {
            #expect(p.contains("(allow process-exec (literal \"/Users/u/.local/share/cursor-agent/versions/v/\(x)\"))"), "\(x)")
        }
        // A1: the tools the script runs where this macOS has them (15: /bin/realpath, /usr/bin/dirname…), both dirs if both exist
        let fm = FileManager.default
        for x in ["env", "bash", "realpath", "dirname", "basename"] {
            let real = ["/bin/" + x, "/usr/bin/" + x].filter { fm.isExecutableFile(atPath: $0) }
            #expect(!real.isEmpty, "\(x)")
            for r in real { #expect(p.contains("(allow process-exec (literal \"\(r)\"))"), "\(r)") }
            for gone in ["/bin/" + x, "/usr/bin/" + x] where !real.contains(gone) { #expect(!p.contains("\"\(gone)\""), "\(gone)") }
        }
        #expect(p.contains("(allow process-exec (literal \"/bin/realpath\"))"))   // macOS 15 has no /usr/bin/realpath
        // A2: the version dir's native modules (.node) can be mapped executable; nothing else
        #expect(p.contains("(allow file-map-executable (subpath \"/Users/u/.local/share/cursor-agent/versions/v\"))"))
        #expect(p.split(separator: "\n").filter { $0.contains("file-map-executable") }.count == 1)
        // A2 (iii): <version>/.running stays closed to writes
        #expect(!p.contains("file-write* (subpath \"/Users/u/.local/share"))
        // A3: outbound only to port 443 (DNS goes through mDNSResponder's mach service)
        #expect(p.contains("(allow network-outbound (remote ip \"*:443\"))") && !p.contains("(allow network-outbound (remote ip))"))
        #expect(p.contains("com.apple.mDNSResponder") && CursorCuratorRunner.port == 443)
    }

    /// The CAs macOS trusts reach the CLI as a PEM in its own cursor-home (`NODE_EXTRA_CA_CERTS`), not through the Keychain:
    /// written every call, 0600, a planted link replaced (never followed).
    @Test func trustedRootsInCursorHome() async throws {
        let f = try Fake()
        let pem = f.home.appendingPathComponent("system-ca.pem"), outside = f.base.appendingPathComponent("outside.pem")
        try "keep".write(to: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: pem, withDestinationURL: outside)
        _ = try await f.runner().run(call, model: "", timeout: .seconds(20))
        let env = try f.recorded()[1]
        #expect(env.contains("NODE_EXTRA_CA_CERTS=\(SignedAppCheck.realPath(pem))\n"))
        let text = try String(contentsOf: pem, encoding: .utf8)
        #expect(CursorCuratorRunner.ownFile(pem) && text.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: pem.path)[.posixPermissions] as? Int
        let kept = try String(contentsOf: outside, encoding: .utf8)
        #expect(mode == 0o600 && kept == "keep")
    }

    /// A2 (ii): sandboxed, the CLI gets a fixed system PATH (the user's only finds it): no Homebrew bash or coreutils.
    @Test func sandboxedPathIsSystem() {
        #expect(CursorCuratorRunner.sandboxPath == "/usr/bin:/bin")
    }
}
