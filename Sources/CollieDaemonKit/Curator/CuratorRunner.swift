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
    /// How soon an `auth status` that failed (timeout, junk) is tried again; a real answer is kept `availabilityTTL`.
    let retryAfter: Duration
    private let cache = Cache()

    static let unreadable = "resposta ilegível do claude"
    static let noAnswer = "claude não respondeu"
    /// R5 (user decision): the plan login, never an API key from the shell (no silent token billing).
    /// Review T2: nor another provider or endpoint (Bedrock, Vertex, a proxy URL).
    static let strippedKeys: Set = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]

    init(root: URL, home: URL, env: @escaping @Sendable () async -> [String: String], retryAfter: Duration = .seconds(30)) {
        self.root = root; self.home = home; self.env = env; self.retryAfter = retryAfter
    }

    private actor Cache {
        var value: (CuratorAvailability, until: ContinuousClock.Instant)?
        func get() -> CuratorAvailability? {
            guard let (v, until) = value, ContinuousClock.now < until else { return nil }
            return v
        }
        func set(_ v: CuratorAvailability, for d: Duration) { value = (v, ContinuousClock.now + d) }
    }

    /// Pinned from `claude --help` (2.1.310) and the tokenless gate. Never `--bare` (it skips the keychain login).
    /// `--` keeps an input that starts with `-` the prompt.
    static func arguments(_ c: CuratorCall, model: String) -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--json-schema", c.schema, "--tools", "",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "project,local", "--safe-mode",
         "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none", "--max-budget-usd", "0.05",
         "--system-prompt", c.instructions, "--", c.input]
    }

    /// `--output-format json`'s result: `structured_output`, else `result` parsed as JSON (a ```json fence stripped);
    /// `is_error` → `.unavailable` with its text. Tolerant of lines before it (a banner) and of an event array (its last
    /// `result`); nothing usable → `.unavailable(unreadable)`.
    static func parse(_ stdout: String) throws(ProtocolError) -> CuratorOutput {
        func decode(_ t: some StringProtocol) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(t.utf8)) }
        func resultObject(_ v: JSONValue?) -> [String: JSONValue]? {
            switch v {
            case .object(let o)? where o["type"] == .string("result") || o["result"] != nil || o["structured_output"] != nil
                || o["is_error"] != nil: return o   // a result's shape: an unrelated JSON line never shadows it
            case .array(let xs)?: return xs.reversed().lazy.compactMap { x -> [String: JSONValue]? in
                if case .object(let o) = x, o["type"] == .string("result") { o } else { nil } }.first
            default: return nil
            }
        }
        // ponytail: the whole output, else its last line that decodes (Claude prints its answer as one line)
        let candidates = [Substring(stdout)] + stdout.split(separator: "\n").reversed()
        guard let o = candidates.lazy.compactMap({ resultObject(decode($0)) }).first else {
            throw ProtocolError(code: .unavailable, message: unreadable)
        }
        var result: String? { if case .string(let s)? = o["result"] { s } else { nil } }
        if case .bool(true)? = o["is_error"] { throw ProtocolError(code: .unavailable, message: result ?? "claude error") }
        let json: JSONValue
        if let s = o["structured_output"], s != .null { json = s }
        else if let t = result, let v = decode(unfenced(t)) { json = v }
        else { throw ProtocolError(code: .unavailable, message: unreadable) }
        func num(_ v: JSONValue?) -> Double { if case .number(let n)? = v { n } else { 0 } }
        var usage: [String: JSONValue] { if case .object(let u)? = o["usage"] { u } else { [:] } }
        return CuratorOutput(json: json, inputTokens: Int(num(usage["input_tokens"])), outputTokens: Int(num(usage["output_tokens"])),
                             costUSD: num(o["total_cost_usd"]))
    }

    /// The text inside a ``` fence (```json too), else `t`.
    static func unfenced(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6, let nl = s.firstIndex(of: "\n") else { return t }
        return String(s[s.index(after: nl)..<s.index(s.endIndex, offsetBy: -3)])
    }

    /// The user's env minus Collie's keys (no socket, token or terminal id reaches the curator), HOME the closed home.
    private func environment() async -> [String: String] {
        var e = await env().filter { !$0.key.hasPrefix("COLLIE_") && !Self.strippedKeys.contains($0.key) }
        e["HOME"] = home.path
        return e
    }

    static func locate(_ env: [String: String]) -> URL? {
        (env["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// An empty temp dir for `body`, removed after (`project,local` settings: none to load).
    private func inTempDir<T>(_ body: (URL) async throws(ProtocolError) -> T) async throws(ProtocolError) -> T {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("collie-curator-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ProtocolError(code: .internal, message: "curator: \(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(at: cwd) }
        return try await body(cwd)
    }

    // ponytail: a real answer (logged in or not, claude missing) is kept 10 min (logging in shows up within that);
    // a failed `auth status` (timeout, junk) only `retryAfter`
    func availability() async -> CuratorAvailability {
        if let v = await cache.get() { return v }
        let e = await environment()
        guard let claude = Self.locate(e) else {
            await cache.set(.unavailable("claude não encontrado"), for: Self.availabilityTTL)
            return .unavailable("claude não encontrado")
        }
        let r = try? await inTempDir { cwd throws(ProtocolError) in
            try await BoundedProcess.run(executable: claude, args: ["auth", "status", "--json"], in: cwd, env: e,
                                         timeout: .seconds(10), cap: 64 << 10)
        }
        let out = r.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.stdout.utf8)) }
        guard case .object(let o)? = out, case .bool(let loggedIn)? = o["loggedIn"] else {
            await cache.set(.unavailable(Self.noAnswer), for: retryAfter)
            return .unavailable(Self.noAnswer)
        }
        let v: CuratorAvailability = loggedIn ? .available : .unavailable("claude sem login")
        await cache.set(v, for: Self.availabilityTTL)
        return v
    }

    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput {
        let e = await environment()
        guard let claude = Self.locate(e) else { throw ProtocolError(code: .unavailable, message: "claude não encontrado") }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("curator"), profile = dir.appendingPathComponent("curator.sb")
        return try await inTempDir { cwd throws(ProtocolError) in
            do {
                for d in [dir, dir.appendingPathComponent("sandbox")] {
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
                throw ProtocolError(code: .internal, message: "curator: \(error.localizedDescription)")
            }
            SandboxLaunch.makeHomeDirs(EssentialPaths.agentHome(.claude, command: nil), in: home)   // R19: its state dirs
            let r: ProcessResult
            do throws(ProtocolError) {
                r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                                                 args: ["-f", profile.path, claude.path] + Self.arguments(c, model: model),
                                                 in: cwd, env: e, timeout: timeout, cap: Self.outputCap)
            } catch where error.code == .timeout {
                throw ProtocolError(code: .timeout, message: Self.noAnswer)   // the fallback's motivo; the queue retries
            }
            do throws(ProtocolError) { return try Self.parse(r.stdout) } catch where error.message == Self.unreadable && r.status != 0 {
                throw ProtocolError(code: .unavailable, message: "claude saiu com \(r.status): \(r.stderr.prefix(300))")
            }
        }
    }
}
