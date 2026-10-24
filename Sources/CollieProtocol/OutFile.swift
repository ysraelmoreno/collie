import Foundation

/// `--out PATH` of every command in `Commands.outputFile` (screenshots, design exports): the caller's process copies the
/// daemon's file (the daemon writes only under its root; a sandboxed caller gets its readable clone, `SandboxLaunch.handOver`).
public enum OutFile {
    /// Copies `result.path` to `dest` (relative to `cwd`; parent dirs created, existing file replaced) and returns the result with `path` = the new absolute path.
    public static func copyPath(of result: JSONValue, to dest: String, cwd: String) throws(ProtocolError) -> JSONValue {
        guard case .object(var o) = result, case .string(let src)? = o["path"] else {
            throw ProtocolError(code: .internal, message: "--out: the reply has no path")
        }
        guard !dest.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "--out needs a path") }
        // a source this process can't read (in a sandbox: one the daemon didn't hand over) is not a write failure
        guard FileManager.default.isReadableFile(atPath: src) else { throw ProtocolError(code: .invalidArgs, message: "--out: cannot read \(src)") }
        var url = URL(fileURLWithPath: dest, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
        let fm = FileManager.default
        func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        // an existing directory (or `dir/`) receives the file under its own name; a directory is never replaced
        if dest.hasSuffix("/") || isDir(url) { url = url.appendingPathComponent(URL(fileURLWithPath: src).lastPathComponent) }
        guard !isDir(url) else { throw ProtocolError(code: .invalidArgs, message: "--out: \(url.path) is a directory") }
        do {
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // copy beside the target, then rename over it: a failed copy keeps the old file
            let tmp = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            do { try fm.copyItem(atPath: src, toPath: tmp.path) } catch { try? fm.removeItem(at: tmp); throw error }
            if rename(tmp.path, url.path) != 0 {
                let e = errno; try? fm.removeItem(at: tmp)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(e))])
            }
        } catch { throw ProtocolError(code: .invalidArgs, message: "--out: cannot write \(url.path): \(error.localizedDescription)") }
        o["path"] = .string(url.path)
        return .object(o)
    }
}
