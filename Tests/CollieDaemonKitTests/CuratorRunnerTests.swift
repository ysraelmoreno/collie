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
    /// In Claude's state: writable under the curator's profile, like nothing else in the home.
    var rec: URL { f.home.appendingPathComponent(".claude/projects/rec") }
    init(_ script: String) throws { try self.init { _ in script } }
    /// `script(rec)`: `rec` is `self.rec`. Under the profile only `/bin/sh` runs: the scripts use its builtins.
    init(_ script: (URL) -> String) throws {
        f = try FakeHome(git: false, socket: false)
        let script = script(f.home.appendingPathComponent(".claude/projects/rec"))
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + script).write(to: claude, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }
    /// `fallback` [] by default: the machine's real ~/.local/bin/claude never leaks into a test.
    func runner(path: String? = nil, retryAfter: Duration = .seconds(30), fallback: [String] = []) -> ClaudeCuratorRunner {
        let env = ["PATH": path ?? (bin.path + ":/usr/bin:/bin"), "HOME": f.home.path,
                   "COLLIE_SOCKET": "/x.sock", "COLLIE_TOKEN": "t", "COLLIE_TERMINAL_ID": "i",
                   "ANTHROPIC_API_KEY": "sk-x", "ANTHROPIC_AUTH_TOKEN": "tok-x", "ANTHROPIC_BASE_URL": "https://x",
                   "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1"]
        return ClaudeCuratorRunner(root: f.collie, home: f.home, env: { env }, retryAfter: retryAfter, fallback: fallback)
    }
}

/// R1: the owner's real `claude auth status --json` on the subscription (Max), sanitized (email, org, paths, date are
/// example values).
private let subscriptionStatus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/curator/claude-auth-status-subscription.json")
/// A SYNTHETIC status: the real subscription fixture edited by `edit`. Not a real Console/API account's output (R1 has
/// none): these only pin that anything but the subscription's positive set is unavailable.
private func syntheticStatus(_ edit: (inout [String: Any]) -> Void) throws -> String {
    var o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: subscriptionStatus)) as? [String: Any])
    edit(&o)
    return String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
}

/// sandbox-exec can't nest: inside an agent's sandbox the real-profile tests are skipped (the owner's R2 runs them).
private let canSandbox: Bool = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}()
private let nested: Comment = "already inside a sandbox: sandbox-exec can't nest"

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
        // E4: the input goes on stdin, never in argv (other processes read argv)
        #expect(a.last == call.instructions && !a.contains(call.input) && !a.contains("--"))
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

    /// E4: the prompt reaches the child on stdin (and an early-exiting child never kills the daemon with SIGPIPE).
    @Test func stdinDelivered() async throws {
        let big = String(repeating: "oi ", count: 100_000)
        let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "cat"], in: URL(fileURLWithPath: "/tmp"),
                                             env: [:], timeout: .seconds(10), stdin: Data(big.utf8))
        #expect(r.stdout == big)
        let gone = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "exit 0"], in: URL(fileURLWithPath: "/tmp"),
                                                env: [:], timeout: .seconds(10), stdin: Data(big.utf8))
        #expect(gone.status == 0)
    }

    @Test(.enabled(if: canSandbox, nested)) func inputViaStdin() async throws {
        let fake = try Fake { rec in "printf '%s\\n' \"$@\" > '\(rec.path)'; read -r l; printf '%s' \"$l\" > '\(rec.path).in'; printf '%s' '\(fixture)'\n" }
        _ = try await fake.runner().run(call, model: "haiku", timeout: .seconds(20))
        #expect(try String(contentsOf: URL(fileURLWithPath: fake.rec.path + ".in"), encoding: .utf8) == call.input)
        #expect(!(try String(contentsOf: fake.rec, encoding: .utf8)).contains(call.input))
    }

    /// E6: credit or quota errors make the runner `.exhausted` (the queue waits without spending attempts).
    @Test func creditErrorIsExhausted() {
        for t in ["Credit balance is too low", "You've hit your usage limit", "Rate limit exceeded", "quota reached", "Please upgrade your plan"] {
            #expect(ClaudeCuratorRunner.exhausted(t), "\(t)")
        }
        #expect(!ClaudeCuratorRunner.exhausted("claude saiu com 1: boom"))
    }

    @Test(.enabled(if: canSandbox, nested)) func creditErrorRunIsExhausted() async throws {
        let fake = try Fake(#"[ "$1" = "auth" ] && { echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}'; exit 0; }; printf '%s' '{"type":"result","is_error":true,"result":"Credit balance is too low"}'"# + "\n")
        let r = fake.runner()
        await #expect(throws: ProtocolError.self) { try await r.run(call, model: "haiku", timeout: .seconds(20)) }
        guard case .exhausted(_, let until)? = Optional(await r.availability()) else { Issue.record("not exhausted"); return }
        #expect(until.map { $0 > Date() } ?? false)
    }

    @Test func parseIsError() {
        #expect(throws: ProtocolError(code: .unavailable, message: "Credit balance is too low")) {
            try ClaudeCuratorRunner.parse(#"{"type":"result","is_error":true,"result":"Credit balance is too low"}"#)
        }
    }

    @Test(.enabled(if: canSandbox, nested)) func fakeClaudeRunsSandboxed() async throws {
        let fake = try Fake { rec in """
            { printf '%s\\n' "$@"; echo ---; printf 'HOME=%s\\nTMPDIR=%s\\n' "$HOME" "$TMPDIR"; export -p; echo ---; pwd; } > '\(rec.path)'
            : > "$HOME/outside" 2>/dev/null
            : > "$HOME/../escape" 2>/dev/null
            echo x >> "$HOME/.claude/settings.json" 2>/dev/null
            read l < "$HOME/.ssh/id_ed25519" 2>/dev/null && echo LEAK-ssh >> '\(rec.path)'
            read l < "$HOME/.claude.json" 2>/dev/null && echo LEAK-claude.json >> '\(rec.path)'
            read l < "$HOME/.config/gh/hosts.yml" 2>/dev/null && echo LEAK-gh >> '\(rec.path)'
            /usr/bin/true 2>/dev/null && echo EXEC >> '\(rec.path)'
            printf '%s' '\(fixture)'
            """ }
        let settings = fake.f.home.appendingPathComponent(".claude/settings.json")
        let before = try Data(contentsOf: settings)

        let o = try await fake.runner().run(call, model: "haiku", timeout: .seconds(30))
        #expect(o.json == .object(["ops": .array([])]) && o.inputTokens == 812)
        let rec = try String(contentsOf: fake.rec, encoding: .utf8)
        #expect(!rec.contains("LEAK") && !rec.contains("EXEC"), "\(rec)")
        let parts = rec.components(separatedBy: "---\n")
        #expect(parts.count == 3)
        #expect(parts[0].contains("--strict-mcp-config\n") && !parts[0].contains(call.input))
        #expect(!parts[1].contains("COLLIE_SOCKET") && !parts[1].contains("COLLIE_TOKEN") && !parts[1].contains("COLLIE_TERMINAL_ID"))
        #expect(parts[1].contains("HOME=\(fake.f.home.path)\n"))
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
            #expect(!parts[1].contains(k + "="), "R5: the plan login, never a key or another provider (\(k))")
        }
        for f in ["outside", "../escape"] { #expect(!FileManager.default.fileExists(atPath: fake.f.home.appendingPathComponent(f).path)) }
        #expect(try Data(contentsOf: settings) == before)
        let cwd = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!cwd.isEmpty && !FileManager.default.fileExists(atPath: cwd))
        #expect(parts[1].contains("TMPDIR=\(cwd)\n"))   // temp files land in the cwd
    }

    /// Each call writes its own `run-<uuid>.sb` (0600), removed after; the fixed `curator.sb` is gone.
    @Test(.enabled(if: canSandbox, nested)) func perCallFile() async throws {
        let fake = try Fake { rec in "while [ ! -f '\(rec.path).go' ]; do :; done\nprintf '%s' '\(fixture)'\n" }
        let r = fake.runner(), dir = fake.f.collie.appendingPathComponent("curator")
        func profiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".sb") } }
        async let a = r.run(call, model: "haiku", timeout: .seconds(20))
        async let b = r.run(call, model: "haiku", timeout: .seconds(20))
        let deadline = ContinuousClock.now + .seconds(10)
        while profiles().count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let seen = profiles()
        #expect(seen.count == 2 && seen.allSatisfy { $0.hasPrefix("run-") }, "\(seen)")
        for s in seen {
            #expect((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(s).path)[.posixPermissions] as? Int) == 0o600)
        }
        try Data().write(to: URL(fileURLWithPath: fake.rec.path + ".go"))
        _ = try await (a, b)
        #expect(profiles().isEmpty)
    }

    /// Whatever the run's outcome (here sandbox-exec may refuse to nest), no profile file is left behind.
    @Test func noProfileLeft() async throws {
        let fake = try Fake("printf '%s' '\(fixture)'\n")
        _ = try? await fake.runner().run(call, model: "haiku", timeout: .seconds(10))
        let left = try FileManager.default.contentsOfDirectory(atPath: fake.f.collie.appendingPathComponent("curator").path)
        #expect(!left.contains { $0.hasSuffix(".sb") }, "\(left)")
    }

    @Test func missingClaudeUnavailable() async throws {
        let fake = try Fake("exit 0\n")
        let r = fake.runner(path: "/usr/bin:/bin")
        #expect(await r.availability() == .unavailable("claude não encontrado"))
        await #expect(throws: ProtocolError(code: .unavailable, message: "claude não encontrado")) {
            try await r.run(call, model: "haiku", timeout: .seconds(5))
        }
    }

    /// The daemon's env capture failed (no PATH): claude is still found in a known dir of the user's real home.
    @Test func missingPathUsesFallback() async throws {
        let ok = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}'; exit 0; }; exit 2"# + "\n")
        #expect(await ok.runner(path: "", fallback: [ok.bin.path]).availability() == .available)
    }

    /// Env capture failed and no known dir has claude: say so (not "não encontrado"), and retry soon, not in 10 min.
    @Test func uncapturedEnvRetriedSoon() async throws {
        let ok = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}'; exit 0; }; exit 2"# + "\n")
        let later = ok.f.base.appendingPathComponent("later")
        let r = ok.runner(path: "", retryAfter: .zero, fallback: [later.path])
        #expect(await r.availability() == .unavailable(ClaudeCuratorRunner.envNotCaptured))
        await #expect(throws: ProtocolError(code: .unavailable, message: ClaudeCuratorRunner.envNotCaptured)) {
            try await r.run(call, model: "haiku", timeout: .seconds(5))
        }
        try FileManager.default.moveItem(at: ok.bin, to: later)
        #expect(await r.availability() == .available)
        // a real PATH with no claude is still "não encontrado", kept the long TTL
        let p = ok.runner(path: "/usr/bin:/bin", retryAfter: .zero)
        #expect(await p.availability() == .unavailable("claude não encontrado"))
        #expect(ClaudeCuratorRunner.envNotCaptured == "ambiente do usuário não capturado (o shell excedeu o prazo; confira o .zshrc)")
    }

    @Test func loggedOutUnavailable() async throws {
        let fake = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": false, "authMethod": "none"}'; exit 1; }; exit 2"# + "\n")
        #expect(await fake.runner().availability() == .unavailable("claude sem login"))
        let ok = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}'; exit 0; }; exit 2"# + "\n")
        #expect(await ok.runner().availability() == .available)
    }

    @Test(.enabled(if: canSandbox, nested)) func timeoutKills() async throws {
        let fake = try Fake { rec in "echo $$ > '\(rec.path)'; while :; do :; done & echo $! >> '\(rec.path)'; wait\n" }
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
            [ -f '\(rec.path).n' ] && { echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}'; exit 0; }
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

    // Task 7 (E3): Claude's side only reads its login into a `CuratorBilling`; the policy is `Curator.admit`.
    @Test func subscriptionLoginAvailable() async throws {
        let fake = try Fake(#"[ "$1 $2 $3" = "auth status --json" ] && { cat '\#(subscriptionStatus.path)'; exit 0; }; exit 2"# + "\n")
        let r = fake.runner()
        #expect(await r.availability() == .available)
        #expect(await r.billing() == .included("assinatura"))
        // a new subscription tier is still the subscription; a new unknown field is ignored
        let team = try syntheticStatus { $0["subscriptionType"] = "team"; $0["planTier"] = "x"; $0["newField"] = [1] }
        #expect(ClaudeCuratorRunner.login(team)?.billing == .included("assinatura"))
        let bare = try syntheticStatus { $0["subscriptionType"] = nil; $0["storedClaudeAiLogin"] = nil }
        #expect(ClaudeCuratorRunner.login(bare)?.billing == .included("assinatura"))
    }

    /// SYNTHETIC Console/API shapes (no real one in R1): an API key method or a non-first-party provider.
    @Test func consoleLoginUnavailable() throws {
        for edit: (inout [String: Any]) -> Void in [{ $0["authMethod"] = "api_key" }, { $0["authMethod"] = "console" },
                                                    { $0["apiProvider"] = "bedrock" }, { $0["apiProvider"] = "vertex" }] {
            let l = try #require(ClaudeCuratorRunner.login(try syntheticStatus(edit)))
            #expect(l.availability == .available && l.billing == .metered("conta de API (cobrança por token)"))
        }
    }

    /// SYNTHETIC: a method or provider never seen, or one missing, is not the subscription.
    @Test func unknownMethodUnavailable() throws {
        for edit: (inout [String: Any]) -> Void in [{ $0["authMethod"] = "oauth" }, { $0["authMethod"] = nil },
                                                    { $0["apiProvider"] = nil }, { $0["authMethod"] = 1 },
                                                    { $0["authMethod"] = "Claude.ai " }] {
            let s = try syntheticStatus(edit)
            #expect(ClaudeCuratorRunner.login(s)?.billing == .unknown, "\(s)")
        }
    }

    @Test func loggedOutOrJunkStatus() throws {
        let out = try #require(ClaudeCuratorRunner.login(try syntheticStatus { $0["loggedIn"] = false }))
        #expect(out.availability == .unavailable("claude sem login") && out.billing == .unknown)
        for junk in ["", "{", "[]", #"{"loggedIn":"yes"}"#, "null"] { #expect(ClaudeCuratorRunner.login(junk) == nil, "\(junk)") }
        // what is read never echoes the status's fields (email, org)
        for edit: (inout [String: Any]) -> Void in [{ $0["authMethod"] = "user@example.com" }, { $0["apiProvider"] = "Example Organization" }] {
            let b = ClaudeCuratorRunner.login(try syntheticStatus(edit))?.billing
            #expect(!"\(String(describing: b))".lowercased().contains("example"))
        }
    }
}
