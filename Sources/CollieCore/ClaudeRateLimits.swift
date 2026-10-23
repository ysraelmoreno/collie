import Foundation

/// What `collie hook claude-statusline` keeps from Claude Code's statusLine feed: only the rate limits (no session, cwd or transcript data).
public enum ClaudeRateLimits {
    public static let fileName = "claude-rate-limits.json"
    private static let windows = ["five_hour", "seven_day"]

    /// `{"five_hour":{...},"seven_day":{...},"recorded_at":<epoch s>}`; nil without `rate_limits` or without either window.
    public static func extract(_ statusJSON: Data, now: Date = Date()) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: statusJSON) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for w in windows {
            guard let win = limits[w] as? [String: Any] else { continue }
            let kept = win.filter { ["used_percentage", "resets_at"].contains($0.key) }   // ponytail: whitelist, nothing else is stored
            if !kept.isEmpty { out[w] = kept }
        }
        guard !out.isEmpty else { return nil }
        out["recorded_at"] = Int(now.timeIntervalSince1970)
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// `statusLine.command` of the user's settings when `statusLine.type == "command"`.
    public static func userStatusLineCommand(settings: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let sl = root["statusLine"] as? [String: Any], sl["type"] as? String == "command",
              let cmd = sl["command"] as? String, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return cmd
    }

    /// Atomic write, 0600 (temp file created 0600 then renamed over the target).
    public static func write(_ data: Data, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { _ = try FileManager.default.replaceItemAt(dir.appendingPathComponent(fileName), withItemAt: tmp) }
        catch { try? FileManager.default.removeItem(at: tmp); throw error }
    }

    /// COLLIE_USAGE_DIR, else `<root>/usage` from the socket path `<root>/run/collied.sock`; nil when neither is known.
    public static func usageDir(env: [String: String]) -> URL? {
        if let d = env["COLLIE_USAGE_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        guard let s = env["COLLIE_SOCKET"], !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("usage")
    }
}

extension ClaudeRateLimits {
    /// The user's own statusLine would run Collie's hook again: its first words are `collie hook claude-statusline` (collie possibly a quoted path).
    public static func invokesOurHook(_ command: String) -> Bool {
        command.range(of: #"(^|[\s;&|(])['"]?[^\s'"]*collie['"]?\s+hook\s+claude-statusline"#, options: .regularExpression) != nil
    }

    private final class Buf: @unchecked Sendable {
        let lock = NSLock(); var data = Data(); var eof = false
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
        func finish() { lock.lock(); eof = true; lock.unlock() }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return eof }
    }

    /// `/bin/sh -c command` in its own process group with `stdin`; returns stdout (all of it, or what arrived by `timeout`).
    /// On timeout the whole group gets SIGTERM, then SIGKILL after 0.3 s. Never throws; nil when it could not even start.
    public static func runUserCommand(_ command: String, stdin: Data, env: [String: String], timeout: TimeInterval = 5) -> Data? {
        signal(SIGPIPE, SIG_IGN)
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0]
        guard pipe(&inP) == 0 else { return nil }
        guard pipe(&outP) == 0 else { close(inP[0]); close(inP[1]); return nil }
        for fd in inP + outP { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }   // dup2 in the child clears it on 0/1 only
        var fa: posix_spawn_file_actions_t? = nil, at: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&at)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at) }
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&at, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&at, 0)   // new group, pgid == child pid
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [String](["/bin/sh", "-c", command]).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/sh", &fa, &at, argv, envp)
        close(inP[0]); close(outP[1])
        guard rc == 0 else { close(inP[1]); close(outP[0]); return nil }

        let buf = Buf(), wfd = inP[1], rfd = outP[0]
        Thread.detachNewThread {
            stdin.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(wfd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(wfd)
        }
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(rfd, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(Data(chunk[0..<n]))
            }
            buf.finish()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0, exited = false
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { exited = true }
            if exited && buf.done { return buf.snapshot }
            usleep(5_000)
        }
        // timeout: stop the whole group (children, pipelines, backgrounded jobs)
        killpg(pid, SIGTERM)
        usleep(300_000)
        killpg(pid, SIGKILL)
        if !exited { waitpid(pid, &status, 0) }
        return buf.snapshot
    }
}
