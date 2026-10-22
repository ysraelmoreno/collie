import Foundation
import OrqProtocol

typealias GitResult = ProcessResult

/// Thin git wrapper over `BoundedProcess`; git never prompts or opens an editor/pager.
enum GitRunner {
    static func run(_ args: [String], in dir: URL, timeout: Duration = .seconds(120),
                    executable: URL = URL(fileURLWithPath: "/usr/bin/git")) async throws(ProtocolError) -> GitResult {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_EDITOR"] = "true"; env["GIT_PAGER"] = "cat"
        // core.fsmonitor in the (agent-writable) shared .git/config would run arbitrary code on every status
        let args = executable.lastPathComponent == "git" ? ["-c", "core.fsmonitor=false"] + args : args
        return try await BoundedProcess.run(executable: executable, args: args, in: dir, env: env, timeout: timeout)
    }
}

private let excludeLock = NSLock()

extension GitRunner {
    /// Appends `line` to `<commonDir>/info/exclude` once (the user's .gitignore is never touched). Synchronous file I/O.
    static func exclude(_ line: String, commonDir: URL) throws(ProtocolError) {
        excludeLock.lock(); defer { excludeLock.unlock() }   // read-modify-write: concurrent callers share one git dir
        let file = commonDir.appendingPathComponent("info/exclude")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if old.split(separator: "\n").contains(Substring(line)) { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + line + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch { throw ProtocolError(code: .internal, message: "cannot update info/exclude: \(error)") }
    }
}
