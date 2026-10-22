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

// an import staged by `admin.data.import` replaces the data before anything reads it (default-workspace included)
DataBackup.applyPending(Paths(root: root))

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
