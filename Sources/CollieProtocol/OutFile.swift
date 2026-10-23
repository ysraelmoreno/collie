import Foundation

/// `--out PATH` of `browser screenshot`: the caller's process copies the daemon's file (the daemon writes only under its root).
public enum OutFile {
    /// Copies `result.path` to `dest` (relative to `cwd`; parent dirs created, existing file replaced) and returns the result with `path` = the new absolute path.
    public static func copyPath(of result: JSONValue, to dest: String, cwd: String) throws(ProtocolError) -> JSONValue {
        guard case .object(var o) = result, case .string(let src)? = o["path"] else {
            throw ProtocolError(code: .internal, message: "--out: the reply has no path")
        }
        guard !dest.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "--out needs a path") }
        let url = URL(fileURLWithPath: dest, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(atPath: src, toPath: url.path)
        } catch { throw ProtocolError(code: .invalidArgs, message: "--out: cannot write \(url.path): \(error.localizedDescription)") }
        o["path"] = .string(url.path)
        return .object(o)
    }
}
