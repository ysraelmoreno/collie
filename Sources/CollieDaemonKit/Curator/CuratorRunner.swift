import Foundation
import CollieCore
import CollieProtocol

/// One curator job: the system prompt, the (fenced, scrubbed) input and the JSON Schema of the answer.
struct CuratorCall: Sendable {
    var instructions: String
    var input: String
    var schema: String
}

struct CuratorOutput: Sendable {
    var json: JSONValue
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

/// `unavailable` carries the pt-BR reason shown as "curador indisponível: <motivo>".
enum CuratorAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// The low-cost headless model that curates memory (tests inject a fake: they never spend tokens).
protocol CuratorRunner: Sendable {
    func availability() async -> CuratorAvailability
    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput
}

/// `claude -p` with no tools, no MCP, no user settings/hooks/plugins, in an empty temp cwd, under its own Seatbelt profile
/// (writes: its temp dir and Claude's own state). Its sandbox id is in no `sandboxKnown`: its denials raise no card.
struct ClaudeCuratorRunner: CuratorRunner {
    static let sandboxId = UUID(uuidString: "00000000-0000-0000-0000-00000000c0de")!
    static let outputCap = 256 << 10
    static let availabilityTTL: Duration = .seconds(600)

    /// Collie's data root (the profile goes in `<root>/curator/`), the home the profile closes (`config.sandboxHome ?? home`),
    /// and the user's environment (`UserEnvironment.current()`).
    let root: URL, home: URL
    let env: @Sendable () async -> [String: String]
    private let cache = Cache()

    init(root: URL, home: URL, env: @escaping @Sendable () async -> [String: String]) {
        self.root = root; self.home = home; self.env = env
    }

    private actor Cache {
        var value: (CuratorAvailability, ContinuousClock.Instant)?
        func get() -> CuratorAvailability? {
            guard let (v, at) = value, ContinuousClock.now < at + ClaudeCuratorRunner.availabilityTTL else { return nil }
            return v
        }
        func set(_ v: CuratorAvailability) { value = (v, ContinuousClock.now) }
    }

    /// Pinned from `claude --help` (2.1.310) and the tokenless gate. Never `--bare` (it skips the keychain login).
    /// `--` keeps an input that starts with `-` the prompt.
    static func arguments(_ c: CuratorCall, model: String) -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--json-schema", c.schema, "--tools", "",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "project,local", "--safe-mode",
         "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none", "--max-budget-usd", "0.05",
         "--system-prompt", c.instructions, "--", c.input]
    }

    /// `--output-format json`'s result: `structured_output`, else `result` parsed as JSON; `is_error` → `.unavailable`.
    static func parse(_ stdout: String) throws(ProtocolError) -> CuratorOutput {
        func bad(_ why: String) -> ProtocolError { ProtocolError(code: .internal, message: "curator output: \(why)") }
        guard let r = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)), case .object(let o) = r else {
            throw bad("not a JSON object")
        }
        var result: String? { if case .string(let s)? = o["result"] { s } else { nil } }
        if case .bool(true)? = o["is_error"] { throw ProtocolError(code: .unavailable, message: result ?? "claude error") }
        let json: JSONValue
        if let s = o["structured_output"], s != .null { json = s }
        else if let t = result, let v = try? JSONDecoder().decode(JSONValue.self, from: Data(t.utf8)) { json = v }
        else { throw bad("no structured output") }
        func num(_ v: JSONValue?) -> Double { if case .number(let n)? = v { n } else { 0 } }
        var usage: [String: JSONValue] { if case .object(let u)? = o["usage"] { u } else { [:] } }
        return CuratorOutput(json: json, inputTokens: Int(num(usage["input_tokens"])), outputTokens: Int(num(usage["output_tokens"])),
                             costUSD: num(o["total_cost_usd"]))
    }

    /// The user's env minus Collie's keys (no socket, token or terminal id reaches the curator), HOME the closed home.
    private func environment() async -> [String: String] {
        var e = await env().filter { !$0.key.hasPrefix("COLLIE_") }
        e["HOME"] = home.path
        return e
    }

    static func locate(_ env: [String: String]) -> URL? {
        (env["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // ponytail: a cached "sem login" lasts the TTL too (logging in shows up within 10 min)
    func availability() async -> CuratorAvailability {
        if let v = await cache.get() { return v }
        let e = await environment()
        let v: CuratorAvailability
        if let claude = Self.locate(e) {
            let r = try? await BoundedProcess.run(executable: claude, args: ["auth", "status", "--json"], in: home, env: e,
                                                  timeout: .seconds(10), cap: 64 << 10)
            let out = r.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.stdout.utf8)) }
            if case .object(let o)? = out, o["loggedIn"] == .bool(true) { v = .available } else { v = .unavailable("claude sem login") }
        } else {
            v = .unavailable("claude não encontrado")
        }
        await cache.set(v)
        return v
    }

    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput {
        let e = await environment()
        guard let claude = Self.locate(e) else { throw ProtocolError(code: .unavailable, message: "claude não encontrado") }
        let fm = FileManager.default
        let cwd = fm.temporaryDirectory.appendingPathComponent("collie-curator-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("curator"), profile = dir.appendingPathComponent("curator.sb")
        do {
            for d in [cwd, dir, dir.appendingPathComponent("sandbox")] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let text = SandboxProfile.render(SandboxInput(
                terminal: Self.sandboxId, project: cwd, mainGitDir: nil, home: home, collieRoot: root,
                terminalDir: dir.appendingPathComponent("sandbox"), socket: dir.appendingPathComponent("no-socket"), agent: .claude))
            try? fm.removeItem(at: profile)
            guard fm.createFile(atPath: profile.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: profile.path])
            }
        } catch {
            try? fm.removeItem(at: cwd)
            throw ProtocolError(code: .internal, message: "curator: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: cwd) }
        SandboxLaunch.makeHomeDirs(EssentialPaths.agentHome(.claude, command: nil), in: home)   // R19: its state dirs
        let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                                             args: ["-f", profile.path, claude.path] + Self.arguments(c, model: model),
                                             in: cwd, env: e, timeout: timeout, cap: Self.outputCap)
        do { return try Self.parse(r.stdout) } catch where error.code == .internal && r.status != 0 {
            throw ProtocolError(code: .unavailable, message: "claude saiu com \(r.status): \(r.stderr.prefix(300))")
        }
    }
}
