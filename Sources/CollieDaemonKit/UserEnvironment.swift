import Foundation
import os

/// The environment the user's interactive terminal would have (`$SHELL -ilc`: reads `.zshrc`, so nvm & co. are on PATH),
/// captured off the pool with a deadline and cached. Agents launch with it; the `shell` preset reads its rc files itself.
actor UserEnvironment {
    /// shell, args, env, timeout → stdout, or nil if the shell could not run / timed out.
    typealias Runner = @Sendable (_ shell: String, _ args: [String], _ env: [String: String], _ timeout: Duration) async -> Data?

    static let marker = "__COLLIE_ENV_BEGIN__"
    /// Output before the marker (banners, prompts, escape codes from rc files) is ignored.
    static let command = #"printf "\n__COLLIE_ENV_BEGIN__\0"; env -0"#
    /// `BoundedProcess`: stdin `/dev/null`, no tty, own process group killed at the deadline.
    static let live: Runner = { shell, args, env, timeout in
        let home = URL(fileURLWithPath: env["HOME"] ?? "/")
        return try? await BoundedProcess.run(executable: URL(fileURLWithPath: shell), args: args, in: home, env: env,
                                             timeout: timeout, salvage: complete).stdoutData
    }
    /// An rc that backgrounds a child holding stdout never lets the drains reach EOF: output that has the marker and ends
    /// on a NUL is the whole `env -0` answer.
    static let complete: @Sendable (Data) -> Bool = { $0.last == 0 && parse($0, marker: marker) != nil }
    /// An empty user environment, without running anything (an empty `PATH` passes the capture check and is filtered out).
    static let empty: Runner = { _, _, _, _ in Data((marker + "\0PATH=\0").utf8) }
    /// Daemon keys the session's tools need (ssh agent, temp dir): passed to the capture, and kept when the user has none.
    static let inherited = ["SSH_AUTH_SOCK", "TMPDIR"]
    static let retryAfter: Duration = .seconds(60)
    static let rcFiles = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]

    private let shell: String, home: URL, ttl: Duration, timeout: Duration, run: Runner
    private let log: @Sendable (String) -> Void
    private var cache: (env: [String: String], at: ContinuousClock.Instant, stamps: [Date?])?
    private var failedAt: ContinuousClock.Instant?
    private var inflight: Task<[String: String], Never>?

    struct Failure: Error { let reason: String }

    init(shell: String, home: URL, ttl: Duration = .seconds(600), timeout: Duration = .seconds(5),
         run: @escaping Runner = UserEnvironment.live,
         log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.shell = shell; self.home = home; self.ttl = ttl; self.timeout = timeout; self.run = run; self.log = log
    }

    /// Captured and filtered. Past `ttl` the last good one is served while a refresh runs in the background; an rc file
    /// change waits for a fresh capture. A failed capture serves the last good one, or `[:]` (retried after `retryAfter`).
    func current() async -> [String: String] {
        let st = stamps()
        if let c = cache, c.stamps == st {
            if ContinuousClock.now >= c.at + ttl { _ = refresh(st) }
            return c.env
        }
        guard let t = refresh(st) else { return cache?.env ?? [:] }
        return await t.value
    }

    /// The capture in flight, a new one, or nil while a failure's retry delay runs.
    private func refresh(_ st: [Date?]) -> Task<[String: String], Never>? {
        if let inflight { return inflight }
        if let f = failedAt, ContinuousClock.now < f + Self.retryAfter { return nil }
        let t = Task { [shell, home, timeout, run] in
            await self.finish(await Self.capture(shell: shell, home: home, timeout: timeout, run: run), st)
        }
        inflight = t
        return t
    }

    private func finish(_ r: Result<[String: String], Failure>, _ st: [Date?]) -> [String: String] {
        inflight = nil
        switch r {
        case .success(let e): cache = (e, ContinuousClock.now, st); failedAt = nil; return e
        case .failure(let f): failedAt = ContinuousClock.now; log("collied: env: capture failed (\(f.reason))"); return cache?.env ?? [:]
        }
    }

    /// Starts the capture in the background.
    func warm() { Task { _ = await current() } }

    // ponytail: six stat calls on the actor per launch; cheap enough to skip moving off the pool.
    private func stamps() -> [Date?] {
        Self.rcFiles.map {
            (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent($0).resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        }
    }

    private static func capture(shell: String, home: URL, timeout: Duration, run: @escaping Runner) async -> Result<[String: String], Failure> {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let args = (name == "zsh" || name == "bash" ? ["-ilc"] : ["-lc"]) + [command]   // fish & co.: no -i
        let pi = ProcessInfo.processInfo.environment
        var env = ["HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shell,
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb", "COLLIE_ENV_CAPTURE": "1"]
        for k in ["LANG"] + inherited { if let v = pi[k] { env[k] = v } }
        let shellEnv = env
        // the runner's own deadline kills the shell; this one also bounds a runner that never returns (cancelled)
        let runner = Task { await run(shell, args, shellEnv, timeout) }
        let sleeper = Task { try? await Task.sleep(for: timeout + .seconds(3)) }   // after the runner's own kill grace
        let out: Data?? = await withCheckedContinuation { c in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Data??) -> Void = { v in
                if once.withLock({ let first = !$0; $0 = true; return first }) { c.resume(returning: v) }
            }
            Task { finish(.some(await runner.value)) }
            Task { await sleeper.value; finish(.none) }
        }
        runner.cancel(); sleeper.cancel()
        guard let out else { return .failure(Failure(reason: "\(name) timed out after \(timeout)")) }
        guard let data = out else { return .failure(Failure(reason: "\(name) failed or timed out")) }
        guard let e = parse(data, marker: marker) else { return .failure(Failure(reason: "no environment in \(name) output")) }
        guard e["PATH"] != nil else { return .failure(Failure(reason: "no PATH in \(name) environment")) }
        return .success(filtered(e))
    }

    /// `K=V` pairs, NUL-separated, after the last `marker\0`; nil without a marker. A truncated last pair is dropped.
    static func parse(_ output: Data, marker: String) -> [String: String]? {
        guard let r = output.range(of: Data((marker + "\0").utf8), options: .backwards) else { return nil }
        var parts = output[r.upperBound...].split(separator: 0, omittingEmptySubsequences: false)
        parts.removeLast()   // what follows the last NUL: empty, or a pair cut short
        var e: [String: String] = [:]
        for p in parts {
            guard let eq = p.firstIndex(of: UInt8(ascii: "=")), eq > p.startIndex else { continue }
            e[String(decoding: p[..<eq], as: UTF8.self)] = String(decoding: p[(eq + 1)...], as: UTF8.self)
        }
        return e
    }

    /// Drops the capturing session's own state (tty, tmux, cwd, Collie's keys); `SSH_AUTH_SOCK` stays (git over ssh).
    static func filtered(_ env: [String: String]) -> [String: String] {
        let drop: Set = ["TMUX", "TMUX_PANE", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM",
                         "SHLVL", "PWD", "OLDPWD", "_", "COLLIE_ENV_CAPTURE"]
        let prefixes = ["ITERM_", "COLLIE_", "__CF", "XPC_"]
        return env.filter { k, v in !drop.contains(k) && !(k == "PATH" && v.isEmpty) && !prefixes.contains { k.hasPrefix($0) } }
    }

    /// The user's keys, overridden by Collie's (`LANG` and `inherited` only if the user has none); PATH = `collieBin` first, then the user's
    /// PATH (or Collie's), without repeating `collieBin`.
    static func merge(user: [String: String], collie: [String: String], collieBin: String,
                      lang: @autoclosure () -> String = defaultLang) -> [String: String] {
        var e = user
        let userFirst = Set(["LANG"] + inherited)
        for (k, v) in collie where k != "PATH" && !(userFirst.contains(k) && user[k] != nil) { e[k] = v }
        let base = user["PATH"] ?? collie["PATH"] ?? "/usr/bin:/bin"
        e["PATH"] = ([collieBin] + base.split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { $0 != collieBin })
            .joined(separator: ":")
        // launchd gives the daemon no locale: without one, zsh/readline read keys as ASCII ("ç", "ã" break), as
        // Terminal does, a UTF-8 LANG from the user's language when nothing sets one.
        if e["LANG"] == nil, e["LC_ALL"] == nil, e["LC_CTYPE"] == nil { e["LANG"] = lang() }
        return e
    }

    /// `<language>_<REGION>.UTF-8` from the user's macOS language when the system has that locale, else en_US.UTF-8.
    static func utf8Locale(identifier: String, exists: (String) -> Bool) -> String {
        let base = identifier.split(separator: "@").first.map(String.init)?.replacingOccurrences(of: "-", with: "_") ?? ""
        let candidate = base + ".UTF-8"
        return !base.isEmpty && exists(candidate) ? candidate : "en_US.UTF-8"
    }

    static let defaultLang = utf8Locale(identifier: Locale.current.identifier) {
        FileManager.default.fileExists(atPath: "/usr/share/locale/" + $0)
    }
}
