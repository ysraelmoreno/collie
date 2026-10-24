import Foundation
import CollieCore

/// A terminal's project: what its sandbox confines it to, and what bounds the paths agents hand the daemon.
enum ProjectRoot {
    /// The paddock's worktree; else the nearest ancestor of the resolved `cwd` holding a `.git` entry (dir or file);
    /// else `cwd` itself. Symlinks resolved; a missing tail through its deepest existing ancestor.
    /// R9: found by lstat, never by running git: an agent-planted `core.worktree` would widen the root.
    static func resolve(cwd: String, paddock: Paddock?) -> URL {
        let dir = URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: paddock?.path ?? cwd)))
        guard paddock == nil else { return dir }
        var u = dir, st = stat()
        while true {
            if lstat(u.appendingPathComponent(".git").path, &st) == 0 { return u }
            if u.path == "/" { return dir }
            u = u.deletingLastPathComponent()
        }
    }

    /// `path` (resolved) is `root` (resolved) or below it, compared by path components (`/a/bc` is not in `/a/b`).
    static func contains(_ path: String, root: URL) -> Bool {
        let p = URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: path))).pathComponents
        let r = URL(fileURLWithPath: SignedAppCheck.realPath(root)).pathComponents
        return p.starts(with: r)
    }

}
