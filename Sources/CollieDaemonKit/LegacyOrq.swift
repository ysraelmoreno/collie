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
    /// to it; renames the `*.orqpartitura` files there (and in `.removed/`). Refused while an Orq daemon answers.
    /// A symlink that cannot be made is only logged: the data is already in `new`.
    public static func migrateDataRoot(old: URL, new: URL, oldDaemonAlive: () -> Bool) -> MigrationOutcome {
        var st = stat()
        guard lstat(old.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return .nothingToMove }   // gone, or our symlink
        if lstat(new.path, &st) == 0 { return .bothExist }
        if oldDaemonAlive() { return .oldDaemonAlive }
        guard renamex_np(old.path, new.path, UInt32(RENAME_EXCL)) == 0 else { return .failed("rename: \(String(cString: strerror(errno)))") }
        if symlink(new.path, old.path) != 0 { log("cannot link \(old.path) to \(new.path): \(String(cString: strerror(errno)))") }
        let p = new.appendingPathComponent("partituras")
        for dir in [p, p.appendingPathComponent(".removed")] {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasSuffix(".\(partituraExt)") {
                let to = String(n.dropLast(partituraExt.count)) + "colliepartitura"
                // a clash leaves the old file where it is (never written over)
                if renamex_np(dir.appendingPathComponent(n).path, dir.appendingPathComponent(to).path, UInt32(RENAME_EXCL)) != 0 {
                    log("cannot rename \(dir.path)/\(n): \(String(cString: strerror(errno)))")
                }
            }
        }
        return .moved
    }

    /// True only when a daemon accepts a connection on `socket`.
    public static func daemonAnswers(_ socket: URL) -> Bool {
        let fd = makeSocket(); defer { close(fd) }
        return (try? withAddr(socket.path, { connect(fd, $0, $1) })) == 0
    }

    /// The repo's Collie folder: `.orq` for a repo that has it and no `.collie` yet, else `.collie`.
    static func repoDirName(repoRoot: URL) -> String {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoRoot.appendingPathComponent(repoDir).path)
            && !fm.fileExists(atPath: repoRoot.appendingPathComponent(".collie").path) ? repoDir : ".collie"
    }

    /// The ground of a floor path (`<ground>/.collie/floors/…` or `<ground>/.orq/floors/…`), nil when it is not one.
    static func ground(ofFloorPath p: String) -> String? {
        for d in [".collie", repoDir] {
            if let r = p.range(of: "/\(d)/floors/") { return String(p[..<r.lowerBound]) }
        }
        return nil
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("collied: legacy Orq data: \(s)\n".utf8)) }
}
