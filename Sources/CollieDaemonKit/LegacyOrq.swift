import Foundation
import Darwin
import CollieCore

/// What an Orq install left on disk, carried over to Collie. Nothing is merged, overwritten or deleted.
public enum LegacyOrq {
    public static let dataRootName = "Orq"
    public static let socketName = "orqd.sock"
    public static let repoDir = ".orq"
    public static let branchPrefix = "orq/"
    public static let partituraExt = "orqpartitura"
    public static let backupExt = "orqbackup"

    public enum MigrationOutcome: Equatable, Sendable { case moved, nothingToMove, bothExist, oldDaemonAlive, failed(String) }

    /// Moves the Orq data root `old` to `new` (one `rename`, never over an existing `new`) and leaves `old` as a symlink
    /// to it. Refused while an Orq daemon answers. A symlink that cannot be made is only logged: the data is already in `new`.
    /// The herds are renamed by `renameLegacyHerds`, on every start.
    public static func migrateDataRoot(old: URL, new: URL, oldDaemonAlive: () -> Bool) -> MigrationOutcome {
        var st = stat()
        guard lstat(old.path, &st) == 0 else { return .nothingToMove }
        if st.st_mode & S_IFMT == S_IFLNK {   // ours (→ new), or data the user moved elsewhere: say where
            let to = (try? FileManager.default.destinationOfSymbolicLink(atPath: old.path)) ?? "?"
            if URL(fileURLWithPath: to, relativeTo: old.deletingLastPathComponent()).standardizedFileURL.path != new.standardizedFileURL.path {
                log("\(old.path) is a link to \(to), left as it is")
            }
            return .nothingToMove
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { return .nothingToMove }
        if lstat(new.path, &st) == 0 { return .bothExist }
        if oldDaemonAlive() { return .oldDaemonAlive }
        guard renamex_np(old.path, new.path, UInt32(RENAME_EXCL)) == 0 else { return .failed("rename: \(String(cString: strerror(errno)))") }
        if symlink(new.path, old.path) != 0 { log("cannot link \(old.path) to \(new.path): \(String(cString: strerror(errno)))") }
        return .moved
    }

    /// Orq's and Collie's first names for saved herds (`<root>/partituras/*.orqpartitura|*.colliepartitura`).
    public static let partituraDir = "partituras"
    public static let colliePartituraExt = "colliepartitura"
    /// A Collie repo's paddocks before they were paddocks (`.collie/floors/<name>`); `.orq/floors/` likewise.
    public static let collieFloorsDir = "floors"

    /// Saved herds under their old names (a moved Orq root, an imported `.orqbackup`, a Collie that still said
    /// partitura): `partituras/` and its `.removed/` go into `herds/` (and `herds/.removed/`), `*.orqpartitura` and
    /// `*.colliepartitura` there become `*.collieherd`. Contents are never touched. Idempotent: run on every start.
    /// A clash leaves the old file where it is (never written over); an emptied `partituras/` is removed.
    public static func renameLegacyHerds(in root: URL) {
        let fm = FileManager.default
        let old = root.appendingPathComponent(partituraDir), new = root.appendingPathComponent("herds")
        for sub in ["", ".removed"] {
            let to = sub.isEmpty ? new : new.appendingPathComponent(sub)
            for from in [sub.isEmpty ? old : old.appendingPathComponent(sub), to] {
                for n in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                    guard let ext = [partituraExt, colliePartituraExt, "collieherd"].first(where: { n.hasSuffix(".\($0)") }) else { continue }
                    let target = String(n.dropLast(ext.count)) + "collieherd"
                    if from == to, target == n { continue }
                    try? fm.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    if renamex_np(from.appendingPathComponent(n).path, to.appendingPathComponent(target).path, UInt32(RENAME_EXCL)) != 0 {
                        log("cannot rename \(from.path)/\(n): \(String(cString: strerror(errno)))")
                    }
                }
            }
        }
        rmdir(old.appendingPathComponent(".removed").path); rmdir(old.path)   // only when empty
    }

    /// True only when a daemon accepts a connection on `socket`.
    public static func daemonAnswers(_ socket: URL) -> Bool {
        let fd = makeSocket(); defer { close(fd) }
        return (try? withAddr(socket.path, { connect(fd, $0, $1) })) == 0
    }

    /// The repo's Collie folder: `.orq` for a repo that has it and no `.collie` yet, else `.collie`. Asked of the pasture
    /// (the main worktree): its paddocks use the same folder.
    static func repoDirName(repoRoot: URL) -> String {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoRoot.appendingPathComponent(repoDir).path)
            && !fm.fileExists(atPath: repoRoot.appendingPathComponent(".collie").path) ? repoDir : ".collie"
    }

    /// Pathspecs that keep both memory folders out of a status (the pasture's own memory never blocks a land or a rollback).
    static let memoryExcludes = [":(exclude).collie/memory", ":(exclude)\(repoDir)/memory"]

    /// The pasture of a paddock path (`<pasture>/.collie/paddocks/…`, or `floors/` under `.collie` or `.orq`), nil when it
    /// is not one.
    static func pasture(ofPaddockPath p: String) -> String? {
        for d in [".collie", repoDir] {
            for sub in ["paddocks", collieFloorsDir] {
                if let r = p.range(of: "/\(d)/\(sub)/") { return String(p[..<r.lowerBound]) }
            }
        }
        return nil
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("collied: legacy Orq data: \(s)\n".utf8)) }
}
