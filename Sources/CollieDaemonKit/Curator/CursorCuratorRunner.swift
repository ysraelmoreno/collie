import Foundation
import CollieCore
import CollieProtocol

/// `cursor-agent -p` as the curator (spec 2026-11-17 §3; formats from the owner's R2/R3, cursor-agent 2026.11.17):
/// its own HOME, config dir and file-stored login under `<root>/curator/cursor-home` (the user's `~/.cursor` never
/// reached), `--mode ask`, an empty-allowlist config written before every call and checked after, the prompt on stdin,
/// under its own Seatbelt profile. Collie never logs it in by itself: only the Preferences' "Entrar" does.
struct CursorCuratorRunner: CuratorRunner {
    let root: URL
    /// The user's PATH (`UserEnvironment.current()["PATH"]`); "" when its capture failed.
    let path: @Sendable () async -> String
    let info: CuratorProviderInfo
    let retryAfter: Duration
    /// Where cursor-agent is looked for past the PATH (`BinaryLocator.dirs` of the user's real home).
    let fallback: [String]
    /// ponytail: tests only (sandbox-exec can't nest inside an agent's sandbox); collied always runs it sandboxed.
    let sandboxed: Bool
    private let cache = CuratorCache<CuratorAvailability>()

    static let availabilityTTL: Duration = .seconds(600)
    /// The only outbound port its profile opens (HTTPS). ponytail: the owner's real run confirms the Cursor API needs
    /// nothing else; filtering by domain would take a local proxy (later).
    static let port = 443
    /// The PATH of a sandboxed call: the user's PATH only locates the CLI; the script's `bash`, `realpath`… come from here.
    static let sandboxPath = "/usr/bin:/bin"
    static let unreadable = "\(CuratorTag.unreadable) (cursor)"
    static var noAnswer: String { tr("cursor não respondeu", "cursor didn't answer") }
    static var noLogin: String { tr("cursor sem login para o curador", "cursor has no login for the curator") }
    static var missing: String { tr("cursor não encontrado", "cursor not found") }
    static var tampered: String {
        tr("cursor: a configuração fechada mudou durante a chamada; resposta descartada",
           "cursor: the closed configuration changed during the call; answer discarded")
    }
    /// Exact (spec): the schema goes in the prompt (no native schema flag).
    static var schemaLine: String {
        tr("Responda só com um objeto JSON que siga este JSON Schema, sem texto antes ou depois:",
           "Answer only with a JSON object that follows this JSON Schema, with no text before or after:")
    }
    /// Logged out: exit 1, empty stdout, "Authentication required" on stderr.
    static func needsLogin(_ stderr: String) -> Bool { stderr.range(of: "authentication required", options: .caseInsensitive) != nil }
    /// Global Constraints: allowlist with nothing allowed and every tool denied.
    static let closedConfig = #"{"version":1,"approvalMode":"allowlist","permissions":{"allow":[],"deny":["Shell(*)","Write(**)","Read(**)","WebFetch(*)","Mcp(*:*)"]},"autoAcceptWebSearch":false,"sandbox":{"mode":"disabled"}}"#

    init(root: URL, path: @escaping @Sendable () async -> String, trust: CuratorTrust, retryAfter: Duration = .seconds(30),
         fallback: [String] = BinaryLocator.dirs(home: NSHomeDirectory()), sandboxed: Bool = true) {
        self.root = root; self.path = path; self.retryAfter = retryAfter; self.fallback = fallback; self.sandboxed = sandboxed
        info = CuratorProviderInfo(provider: .cursor, trust: trust, destination: "Cursor", structuredOutput: false,
                                   reportsUsage: true, timeout: .seconds(120), inputMax: 12_000)
    }

    static func home(_ root: URL) -> URL { root.appendingPathComponent("curator/cursor-home") }
    var cursorHome: URL { Self.home(root) }
    var configFile: URL { cursorHome.appendingPathComponent(".cursor/cli-config.json") }

    /// "Entrar no Cursor para o curador" (the Preferences' button, the only way Collie logs it in): cursor-home and its
    /// `.cursor` made 0700, and the line the user's new terminal runs (R2: the login lands in `.cursor/auth.json` there;
    /// the user's own Cursor login stays as it was).
    static func prepareLogin(root: URL, exe: URL) throws -> String {
        let h = home(root)
        try FileManager.default.createDirectory(at: h.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for d in [h, h.appendingPathComponent(".cursor")] { try makeOwnDir(d) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "HOME=\(q(h.path)) CURSOR_CONFIG_DIR=\(q(h.path + "/.cursor")) AGENT_CLI_CREDENTIAL_STORE=file exec \(q(exe.path)) login"
    }

    // A4 (review): collied writes, outside any sandbox, in a dir the CLI controls. Never through a link it planted:
    // every path is checked with lstat (a regular file with one link, or a dir, the user's) before it is written or trusted.
    private static func lstatOf(_ u: URL) -> stat? {
        var st = stat()
        return lstat(u.path, &st) == 0 ? st : nil
    }
    static func ownFile(_ u: URL) -> Bool {
        guard let st = lstatOf(u) else { return false }
        return st.st_mode & S_IFMT == S_IFREG && st.st_nlink == 1 && st.st_uid == getuid()
    }
    static func ownDir(_ u: URL) -> Bool {
        guard let st = lstatOf(u) else { return false }
        return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid()
    }
    /// `u` as a real 0700 dir of the user's: a link (removed, never followed) or anything else there goes first.
    static func makeOwnDir(_ u: URL) throws {
        if !ownDir(u) {
            if lstatOf(u) != nil { try FileManager.default.removeItem(at: u) }   // a symlink: the link itself
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        chmod(u.path, 0o700)
    }
    /// The closed config, written fresh (the atomic rename replaces whatever entry was there, a link included), 0600.
    private func writeClosedConfig() throws {
        let dot = configFile.deletingLastPathComponent()
        try Self.makeOwnDir(dot)
        if Self.lstatOf(configFile) != nil, !Self.ownFile(configFile) { try FileManager.default.removeItem(at: configFile) }
        try Data(Self.closedConfig.utf8).write(to: configFile, options: .atomic)
        guard Self.ownFile(configFile) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: configFile.path]) }
        chmod(configFile.path, 0o600)
        let auth = dot.appendingPathComponent("auth.json")
        if Self.ownFile(auth) { chmod(auth.path, 0o600) }   // a linked one is left alone (its target never touched)
    }
    /// After a call: cursor-home, `.cursor` and the config still real and ours, the config still closed.
    private func closedAfterCall() -> Bool {
        Self.ownDir(cursorHome) && Self.ownDir(configFile.deletingLastPathComponent()) && Self.ownFile(configFile)
            && Self.stillClosed(try? Data(contentsOf: configFile))
    }

    /// Pinned (R3). Never `--force`, `--yolo`, `--approve-mcps`, `--api-key`, `--auth-token`, `-H`, `-e`, `--plugin-dir`,
    /// `--worktree`, `--resume`, `--continue`; no prompt in argv (stdin).
    static func arguments(model: String, cwd: URL) -> [String] {
        ["-p", "--output-format", "json", "--mode", "ask", "--sandbox", "disabled", "--trust", "--workspace", cwd.path]
            + (model.isEmpty ? [] : ["--model=" + model])   // one argv item: never read as another flag
    }

    /// From nothing: no `CURSOR_API_KEY`, `CURSOR_AUTH_TOKEN`, `CURSOR_API_ENDPOINT`, `XDG_CONFIG_HOME` or `COLLIE_*` can
    /// come from the user's shell.
    static func environment(root: URL, path: String) -> [String: String] {
        let h = home(root).path
        return ["HOME": h, "CURSOR_CONFIG_DIR": h + "/.cursor", "AGENT_CLI_CREDENTIAL_STORE": "file", "PATH": path,
                "LANG": "en_US.UTF-8", "TMPDIR": FileManager.default.temporaryDirectory.path]
    }

    static func prompt(_ c: CuratorCall) -> String {
        c.instructions + "\n\n" + schemaLine + "\n" + c.schema + "\n\n" + c.input
    }

    /// R3: one `{"type":"result", "is_error", "result": "<the curator's JSON as text>", "usage": {inputTokens,
    /// outputTokens, …}}`. Logged out: exit 1, empty stdout, "Authentication required" on stderr. Tokens filled, cost nil.
    static func parse(_ stdout: String, status: Int32, stderr: String) throws(ProtocolError) -> CuratorOutput {
        if needsLogin(stderr) { throw ProtocolError(code: .unavailable, message: noLogin) }
        if exhausted(stderr) { throw ProtocolError(code: .unavailable, message: String(stderr.prefix(300))) }
        let line = stdout.split(separator: "\n").reversed().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let line, case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            if status != 0, let p = CuratorSandboxProfile.blocked(stderr) {
                throw ProtocolError(code: .unavailable, message: tr("curador bloqueado pelo sandbox: \(p)", "curator blocked by the sandbox: \(p)"))
            }
            throw ProtocolError(code: .unavailable, message: status == 0 ? unreadable
                                : tr("cursor saiu com \(status): \(stderr.prefix(300))", "cursor exited with \(status): \(stderr.prefix(300))"))
        }
        let result: String? = if case .string(let s)? = o["result"] { s } else { nil }
        if case .bool(true)? = o["is_error"] { throw ProtocolError(code: .unavailable, message: result ?? "cursor error") }
        guard let result, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(ClaudeCuratorRunner.unfenced(result).utf8)),
              case .object = json else { throw ProtocolError(code: .unavailable, message: unreadable) }
        func num(_ k: String) -> Int? {
            if case .object(let u)? = o["usage"], case .number(let n)? = u[k] { Int(n) } else { nil }
        }
        return CuratorOutput(json: json, inputTokens: num("inputTokens"), outputTokens: num("outputTokens"), costUSD: nil)
    }

    /// `status --format json`: only `status`/`isAuthenticated` are read (never `userInfo`: e-mail, names, team).
    static func login(_ statusJSON: String) -> CuratorAvailability {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(statusJSON.utf8)),
              case .string(let s)? = o["status"] else { return .unavailable(noAnswer, code: .noAnswer) }
        return s == "authenticated" && o["isAuthenticated"] == .bool(true) ? .available : .unavailable(noLogin, code: .noLogin)
    }

    /// `cursor-agent models`: "auto - Auto (default)" lines → their ids.
    static func models(_ stdout: String) -> [String] {
        stdout.split(separator: "\n").compactMap { l in
            guard let r = l.range(of: " - ") else { return nil }
            let id = l[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            return id.isEmpty || id.contains(" ") ? nil : id
        }
    }

    /// The config left after the call still has the closed `approvalMode`, `permissions`, `sandbox.mode` and
    /// `autoAcceptWebSearch` (the CLI adds keys of its own: kept).
    static func stillClosed(_ data: Data?) -> Bool {
        func closed(_ d: Data?) -> [String: JSONValue]? {
            guard let d, case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) else { return nil }
            return o
        }
        guard let now = closed(data), let want = closed(Data(closedConfig.utf8)) else { return false }
        func mode(_ o: [String: JSONValue]) -> JSONValue? { if case .object(let s)? = o["sandbox"] { s["mode"] } else { nil } }
        return now["approvalMode"] == want["approvalMode"] && now["permissions"] == want["permissions"]
            && mode(now) == mode(want) && mode(now) != nil && now["autoAcceptWebSearch"] == .bool(false)
    }

    private func locate() async -> (URL?, path: String) {
        let p = await path()
        return (BinaryLocator.locate("cursor-agent", env: ["PATH": p], fallback: fallback), p)
    }

    // ponytail: a real answer (logged in or not, missing) is kept 10 min; a failed `status` only `retryAfter`
    func availability() async -> CuratorAvailability {
        if let v = await cache.get() { return v }
        let (exe, p) = await locate()
        guard let exe else {
            let captured = !p.isEmpty
            let v = CuratorAvailability.unavailable(captured ? Self.missing : ClaudeCuratorRunner.envNotCaptured)
            await cache.set(v, for: captured ? Self.availabilityTTL : retryAfter)
            return v
        }
        // no cursor-home: never logged in for the curator (no `status` run; "Entrar" creates it)
        guard Self.ownDir(cursorHome) else {   // a link there is never used either
            await cache.set(.unavailable(Self.noLogin, code: .noLogin), for: retryAfter)
            return .unavailable(Self.noLogin, code: .noLogin)
        }
        let r = try? await curatorTempDir { cwd throws(ProtocolError) in
            try await BoundedProcess.run(executable: exe, args: ["status", "--format", "json"], in: cwd,
                                         env: Self.environment(root: root, path: p), timeout: .seconds(15), cap: 64 << 10)
        }
        let v = r.map { Self.login($0.stdout) } ?? .unavailable(Self.noAnswer, code: .noAnswer)
        await cache.set(v, for: v.code == .noAnswer ? retryAfter : Self.availabilityTTL)
        return v
    }

    /// R2 shows no billing field: unknown (the Curator asks consent for it).
    func billing() async -> CuratorBilling { .unknown }

    func models() async -> [String] {
        let (exe, p) = await locate()
        guard let exe, Self.ownDir(cursorHome) else { return [] }
        let r = try? await curatorTempDir { cwd throws(ProtocolError) in
            try await BoundedProcess.run(executable: exe, args: ["models"], in: cwd, env: Self.environment(root: root, path: p),
                                         timeout: .seconds(15), cap: 64 << 10)
        }
        return r.map { Self.models($0.stdout) } ?? []
    }

    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput {
        // config.json edited by hand skips `setProvider`'s check
        guard Curator.validModel(model) else { throw ProtocolError(code: .invalidArgs, message: Curator.badModel) }
        let (found, p) = await locate()
        guard let exe = found else {
            throw ProtocolError(code: .unavailable, message: p.isEmpty ? ClaudeCuratorRunner.envNotCaptured : Self.missing)
        }
        guard Self.ownDir(cursorHome) else { throw ProtocolError(code: .unavailable, message: Self.noLogin) }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("curator"), profile = dir.appendingPathComponent("run-\(UUID().uuidString).sb")
        return try await curatorTempDir { cwd throws(ProtocolError) in
            defer { try? fm.removeItem(at: profile) }
            do {
                try writeClosedConfig()   // before every call, whatever was there
                if sandboxed {
                    let text = CuratorSandboxProfile.render(CuratorSandboxProfile.cursor(script: exe, cwd: cwd, cursorHome: cursorHome))
                    guard fm.createFile(atPath: profile.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: profile.path])
                    }
                }
            } catch {
                throw ProtocolError(code: .internal, message: "curator: \(error.localizedDescription)")
            }
            var e = Self.environment(root: root, path: sandboxed ? Self.sandboxPath : p)
            e["TMPDIR"] = cwd.path
            let args = Self.arguments(model: model, cwd: cwd)
            let r: ProcessResult
            do throws(ProtocolError) {
                r = sandboxed
                    ? try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), args: ["-f", profile.path, exe.path] + args,
                                                   in: cwd, env: e, timeout: timeout, cap: ClaudeCuratorRunner.outputCap, stdin: Data(Self.prompt(c).utf8))
                    : try await BoundedProcess.run(executable: exe, args: args, in: cwd, env: e, timeout: timeout,
                                                   cap: ClaudeCuratorRunner.outputCap, stdin: Data(Self.prompt(c).utf8))
            } catch where error.code == .timeout {
                throw ProtocolError(code: .timeout, message: Self.noAnswer)
            }
            // R3: the CLI rewrites its config; the allowlist, denies and sandbox must still be ours, else no answer of
            // this call is trusted (a failed one too)
            guard closedAfterCall() else { throw ProtocolError(code: .internal, message: Self.tampered) }
            let out: CuratorOutput
            do throws(ProtocolError) { out = try Self.parse(r.stdout, status: r.status, stderr: r.stderr) } catch {
                if Self.exhausted(error.message) {
                    await cache.set(.exhausted(error.message, until: Date().addingTimeInterval(Self.exhaustedFor)), for: .seconds(Int64(Self.exhaustedFor)))
                } else if Self.needsLogin(r.stderr) {
                    await cache.set(.unavailable(Self.noLogin, code: .noLogin), for: retryAfter)
                }
                throw error
            }
            return out
        }
    }
}
