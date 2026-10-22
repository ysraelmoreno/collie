import Foundation

/// Manages `collied` as a user LaunchAgent so the daemon outlives the app.
public enum DaemonLauncher {
    public static let defaultLabel = "dev.collie.daemon"
    /// Runs launchctl; returns (exit status, stdout).
    public typealias Launchctl = @Sendable ([String]) throws -> (status: Int32, output: String)

    public static var defaultAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents") }
    public static var defaultLogDir: URL { home.appendingPathComponent("Library/Logs/Collie") }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static let realLaunchctl: Launchctl = { args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()   // drain before wait: no pipe-full deadlock
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    public static func plist(colliedPath: String, root: URL, label: String = defaultLabel, logDir: URL = defaultLogDir) -> Data {
        let log = logDir.appendingPathComponent("collied.log").path
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [colliedPath, "--root", root.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "ProcessType": "Interactive",
        ]
        // XML plist serialization sorts dictionary keys, so equal inputs give equal bytes.
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func validate(_ label: String) throws {
        if label.isEmpty || label.contains("/") || label.contains("..") { throw LaunchError.invalidLabel(label) }
    }

    /// Blocking (spawns launchctl, touches disk): call off the main thread.
    public static func ensureRunning(
        colliedPath: String, root: URL, label: String = defaultLabel,
        agentsDir: URL = defaultAgentsDir, logDir: URL = defaultLogDir, launchctl: Launchctl = realLaunchctl
    ) throws {
        try validate(label)
        let fm = FileManager.default
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let file = agentsDir.appendingPathComponent("\(label).plist")
        let data = plist(colliedPath: colliedPath, root: root, label: label, logDir: logDir)
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        func bootstrap() throws {
            // After bootout launchd may still be tearing the job down: bootstrap then fails with exit 5 (I/O error).
            for attempt in 0..<4 {
                let r = try launchctl(["bootstrap", domain, file.path])
                if r.status == 0 { return }
                guard r.status == 5, attempt < 3 else { throw LaunchError.bootstrapFailed(r.status) }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try? launchctl(["bootout", target])   // not loaded yet is fine
            try bootstrap()
            return
        }
        // `print` exits 0 for any loaded job, running or not: only the state line says which.
        let p = try launchctl(["print", target])
        if p.status != 0 { try bootstrap(); return }
        if p.output.contains("state = running") { return }
        if try launchctl(["kickstart", target]).status != 0 { try bootstrap() }
    }

    public static func stop(label: String = defaultLabel, launchctl: Launchctl = realLaunchctl) throws {
        try validate(label)
        _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    /// Restarts the running job in place (`kickstart -k`): kills its terminals. Blocking: call off the main thread.
    public static func restart(label: String = defaultLabel, launchctl: Launchctl = realLaunchctl) throws {
        try validate(label)
        let r = try launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if r.status != 0 { throw LaunchError.restartFailed(r.status) }
    }

    /// The connected daemon runs another build than the bundled one (nil daemon build = a daemon from before build ids).
    /// An unreadable bundled build cannot be compared: not stale.
    public static func isStale(daemonBuild: String?, bundledBuild: String?) -> Bool {
        guard let bundledBuild else { return false }
        return daemonBuild != bundledBuild
    }

    public enum LaunchError: Error, Equatable { case bootstrapFailed(Int32), restartFailed(Int32), invalidLabel(String) }
}
