import Foundation

/// Finds a CLI by name: the env's PATH first, then the dirs installers use. The fallback exists because the daemon's
/// captured env can come back empty (the login shell timed out): a launchd daemon has no useful PATH of its own.
enum BinaryLocator {
    /// `home` is the user's REAL home (`NSHomeDirectory()`), never a sandbox's closed one.
    static func dirs(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    static func locate(_ name: String, env: [String: String], home: String) -> URL? {
        locate(name, env: env, fallback: dirs(home: home))
    }

    /// First `<dir>/<name>` that is an executable file (a symlink to one counts; a directory doesn't).
    static func locate(_ name: String, env: [String: String], fallback: [String]) -> URL? {
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path + fallback).lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && !dir.boolValue
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
