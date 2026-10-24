import Foundation
import Dispatch
import CollieCore
import CollieDaemonKit

var root = Paths.defaultRoot
var workspace: UUID?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--root": if let v = it.next() { root = URL(fileURLWithPath: v) }
    case "--workspace":
        guard let v = it.next(), let u = UUID(uuidString: v) else { FileHandle.standardError.write(Data("bad --workspace\n".utf8)); exit(2) }
        workspace = u
    default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
    }
}

// an Orq install's data becomes ours before anything reads it; only for the real root (never a test's or a custom one)
if root.standardizedFileURL.path == Paths.defaultRoot.standardizedFileURL.path {
    let old = root.deletingLastPathComponent().appendingPathComponent(LegacyOrq.dataRootName)
    let r = LegacyOrq.migrateDataRoot(old: old, new: root) {
        LegacyOrq.daemonAnswers(old.appendingPathComponent("run").appendingPathComponent(LegacyOrq.socketName))
    }
    FileHandle.standardError.write(Data("collied: legacy Orq data: \(r)\n".utf8))
    switch r {   // continuing would create our root and block the move for good: exit, launchd starts us again
    case .oldDaemonAlive, .failed: exit(1)
    default: break
    }
}
// Orq's root is a link to ours: an old Orq.app reopened would run orqd on the same data
if LegacyOrq.daemonAnswers(Paths(root: root).runDir.appendingPathComponent(LegacyOrq.socketName)) {
    FileHandle.standardError.write(Data("collied: an Orq daemon (orqd) is running on \(root.path); quit Orq and remove Orq.app\n".utf8)); exit(1)
}

// an import staged by `admin.data.import` replaces the data before anything reads it (default-workspace included)
DataBackup.applyPending(Paths(root: root))
LegacyOrq.renameLegacyHerds(in: root)   // a moved Orq root, an imported .orqbackup, a Collie from before the herding vocabulary

// stable default so a restarted daemon reloads its state
if workspace == nil {
    let f = root.appendingPathComponent("default-workspace")
    if let t = try? String(contentsOf: f, encoding: .utf8), let u = UUID(uuidString: t.trimmingCharacters(in: .whitespacesAndNewlines)) {
        workspace = u
    } else {
        let u = UUID()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? u.uuidString.write(to: f, atomically: true, encoding: .utf8)
        workspace = u
    }
}

/// Absolute, symlink-free path of this executable (argv[0] may be a bare name resolved via PATH).
func selfPath() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0, let r = realpath(buf, nil) else { return nil }
    defer { free(r) }
    return URL(fileURLWithPath: String(cString: r))
}
guard let collie = selfPath()?.deletingLastPathComponent().appendingPathComponent("collie"),
      FileManager.default.isExecutableFile(atPath: collie.path) else {
    FileHandle.standardError.write(Data("collied: cannot find executable 'collie' next to collied (\(selfPath()?.path ?? "?"))\n".utf8)); exit(1)
}
// the app bundle puts it in Contents/Resources (collied is in Contents/Helpers)
let scrcpy = ProcessInfo.processInfo.environment["COLLIE_SCRCPY_SERVER"].map { URL(fileURLWithPath: $0) }
    ?? collie.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/scrcpy-server")
// the bundled design engine (Contents/Resources/figcraft); a missing one is reported by the design commands
let figcraft = ProcessInfo.processInfo.environment["COLLIE_FIGCRAFT_DIR"].map { URL(fileURLWithPath: $0) }
    ?? collie.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/figcraft")
let daemon: Daemon
do {
    var config = DaemonConfig(paths: Paths(root: root), collieExecutable: collie, workspaceId: workspace!)
    config.scrcpyServer = FileManager.default.fileExists(atPath: scrcpy.path) ? scrcpy : nil
    config.figcraftDir = figcraft
    let ctty = collie.deletingLastPathComponent().appendingPathComponent("collie-ctty")
    config.cttyHelper = FileManager.default.isExecutableFile(atPath: ctty.path) ? ctty : nil
    // admin only from the app this daemon ships with (Contents/Helpers/collied -> Contents/MacOS/Collie); see forDaemon
    if let me = selfPath() {
        let (check, note) = SignedAppCheck.forDaemon(executable: me, root: root, defaultRoot: Paths.defaultRoot)
        config.adminPeerCheck = check
        FileHandle.standardError.write(Data("collied: \(note)\n".utf8))
    } else {   // can't tell where we run from: as unbundled on the default root
        config.adminPeerCheck = SignedAppCheck(app: URL(fileURLWithPath: "/nonexistent/Collie"))
    }
    config.captureUserEnv = ProcessInfo.processInfo.environment["COLLIE_USER_ENV"] != "off"   // tests: never the developer's rc files
    // hash of the file this process started from; read off the cooperative pool
    config.build = await Task.detached { selfPath().flatMap(BuildID.of) }.value
    daemon = try Daemon(config: config)
    try await daemon.start()
} catch {
    FileHandle.standardError.write(Data("collied: \(error)\n".utf8)); exit(1)
}

var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { Task { await daemon.stop(); exit(0) } }
    s.resume(); sources.append(s)
}
// dispatchMain() traps inside the async top level; park instead (signal sources on .main still fire)
await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
