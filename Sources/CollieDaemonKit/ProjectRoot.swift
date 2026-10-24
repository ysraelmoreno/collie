import Foundation
import CollieCore

/// A terminal's project: what its sandbox confines it to, and what bounds the paths agents hand the daemon.
enum ProjectRoot {
    /// The paddock's worktree; else the git toplevel of `cwd`; else `cwd` itself (git failing or slow included).
    /// Symlinks resolved; a missing tail through its deepest existing ancestor.
    static func resolve(cwd: String, paddock: Paddock?) -> URL {
        let dir = URL(fileURLWithPath: paddock?.path ?? cwd)
        let top = paddock == nil ? gitToplevel(dir) : nil
        return URL(fileURLWithPath: SignedAppCheck.realPath(top.map { URL(fileURLWithPath: $0) } ?? dir))
    }

    /// `path` (resolved) is `root` (resolved) or below it, compared by path components (`/a/bc` is not in `/a/b`).
    static func contains(_ path: String, root: URL) -> Bool {
        let p = URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: path))).pathComponents
        let r = URL(fileURLWithPath: SignedAppCheck.realPath(root)).pathComponents
        return p.starts(with: r)
    }

    // ponytail: synchronous, at most `timeout` on the caller's actor (rev-parse answers in milliseconds); async if it ever shows
    static func gitToplevel(_ dir: URL, timeout: TimeInterval = 5) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // core.fsmonitor in an agent-writable .git/config would run code (as in GitRunner)
        p.arguments = ["-c", "core.fsmonitor=false", "-C", dir.path, "rev-parse", "--show-toplevel"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        return s.isEmpty ? nil : s
    }
}
