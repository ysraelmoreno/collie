import Foundation
import CollieCore

/// Installs a downloaded Collie dmg over the running app (spec 2026-11-17 §2, §4): mount, copy into a fresh
/// `mkdtemp` sibling, check, exchange by `renamex_np(RENAME_SWAP)` only (never writes into the installed bundle),
/// check again at the final path (swap back on failure), keep the previous bundle until the second healthy launch.
public struct AppUpdateSwap {
    public enum Refusal: Error, Equatable {
        case translocated, readOnly, notWritable, tccFolder, localBuild, lowSpace, badVersion(String), badSignature,
             swapFailed(String)
    }

    public typealias Mount = (_ dmg: URL) throws -> (point: URL, detach: () -> Void)

    static let siblingPrefix = ".Collie-update-"
    public static let previousKey = "update.previous", previousVersionKey = "update.previousVersion",
               launchesKey = "update.healthyLaunches"

    let app: URL
    let mount: Mount
    let verify: (URL) -> Bool
    let freeSpace: (String) -> Int64?
    let defaults: UserDefaults
    var parent: URL { app.deletingLastPathComponent() }

    public init(app: URL, mount: @escaping Mount,
                verify: @escaping (URL) -> Bool = { CodeSignature.appAndHelpers($0, teamId: CodeSignature.team) },
                freeSpace: @escaping (String) -> Int64?, defaults: UserDefaults) {
        self.app = app; self.mount = mount; self.verify = verify; self.freeSpace = freeSpace; self.defaults = defaults
    }

    /// Why this app can't update itself in place (nil: it can).
    public func destinationRefusal(tccWarning: Bool) -> Refusal? {
        if app.path.contains("/AppTranslocation/") { return .translocated }
        var fs = statfs()
        if statfs(parent.path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnly }
        if access(parent.path, W_OK) != 0 { return .notWritable }
        if tccWarning { return .tccFolder }
        if !verify(app) { return .localBuild }
        return nil
    }

    /// The new app, copied and checked into a new sibling of the installed one; returns `<sibling>/Collie.app`.
    /// On any refusal the sibling is gone and the dmg detached.
    public func prepare(dmg: URL, manifest: UpdateManifest, system: OperatingSystemVersion) throws(Refusal) -> URL {
        guard manifest.teamId == CodeSignature.team else { throw .badSignature }
        guard let free = freeSpace(parent.path), free >= manifest.size * 3 else { throw .lowSpace }
        let mounted: (point: URL, detach: () -> Void)
        do { mounted = try mount(dmg) } catch { throw .swapFailed("montar o dmg: \(error)") }
        defer { mounted.detach() }
        // B1: exclusive, 0700, never an existing path, never merged with planted content.
        var template = Array(parent.appendingPathComponent(Self.siblingPrefix + "XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw .swapFailed(tr("criar a pasta irmã: \(String(cString: strerror(errno)))", "creating the sibling folder: \(String(cString: strerror(errno)))")) }
        let sibling = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        let out = sibling.appendingPathComponent("Collie.app")
        do throws(Refusal) {
            let source = mounted.point.appendingPathComponent("Collie.app")
            try Self.scan(source)   // ditto may drop setuid on the copy; refuse a dmg that carries it at all
            try Self.ditto(source, out)
            try Self.checkInfo(out, manifest: manifest, system: system)
            try Self.scan(out)
            guard verify(out) else { throw .badSignature }
            Self.stripQuarantine(out)
            return out
        } catch {
            try? FileManager.default.removeItem(at: sibling)
            throw error
        }
    }

    /// `prepared` ↔ the installed app. The old one ends at `prepared` and is remembered as the previous version.
    public func swap(prepared: URL) throws(Refusal) {
        let old = Self.version(app)
        do { try exchange(prepared) } catch { removeSibling(of: prepared); throw error }
        remember(prepared, version: old)
    }

    /// Back to the remembered previous bundle, same exchange and check; the newer one becomes the previous.
    public func rollback() throws(Refusal) {
        guard let p = defaults.string(forKey: Self.previousKey), FileManager.default.fileExists(atPath: p) else {
            throw .swapFailed(tr("sem versão anterior", "no previous version"))
        }
        let current = Self.version(app)
        try exchange(URL(fileURLWithPath: p))   // failure: swapped back, the previous kept
        remember(URL(fileURLWithPath: p), version: current)
    }

    /// I8: the previous bundle goes away only on the second healthy launch; unhealthy launches don't count.
    public func launched(healthy: Bool) {
        guard healthy, let p = defaults.string(forKey: Self.previousKey) else { return }
        let n = defaults.integer(forKey: Self.launchesKey) + 1
        guard n >= 2 else { defaults.set(n, forKey: Self.launchesKey); return }
        removeSibling(of: URL(fileURLWithPath: p))
        for k in [Self.previousKey, Self.previousVersionKey, Self.launchesKey] { defaults.removeObject(forKey: k) }
    }

    /// `/bin/sh` arguments that wait for `pid` to exit, then reopen `app` through LaunchServices.
    public static func relauncher(pid: Int32, app: URL) -> [String] {
        let quoted = "'" + app.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-c", "while kill -0 \(pid); do sleep 0.2; done; /usr/bin/open \(quoted)"]
    }

    /// Starts the relauncher for this process, detached in its own session (`POSIX_SPAWN_SETSID`). Manual-only path.
    public static func spawnRelauncher(app: URL) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var argv: [UnsafeMutablePointer<CChar>?] = (["/bin/sh"] + relauncher(pid: getpid(), app: app)).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/sh", nil, &attr, &argv, environ) == 0
    }

    /// Removes every `.Collie-update-*` in `parent` except the one holding `keep`.
    public static func cleanupOrphans(parent: URL, keep: URL?) {
        let fm = FileManager.default
        let keepPath = keep?.standardizedFileURL.path
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(siblingPrefix) {
            let dir = parent.appendingPathComponent(name).standardizedFileURL.path
            if let keepPath, keepPath == dir || keepPath.hasPrefix(dir + "/") { continue }
            try? fm.removeItem(atPath: dir)
        }
    }

    /// The real mount (`hdiutil attach`), never called by the tests.
    public static func hdiutilMount(_ dmg: URL) throws -> (point: URL, detach: () -> Void) {
        let out = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom",
                                               FileManager.default.temporaryDirectory.path, "-plist", dmg.path])
        let plist = try PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any]
        guard let point = (plist?["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (URL(fileURLWithPath: point), { _ = try? run("/usr/bin/hdiutil", ["detach", point, "-force"]) })
    }

    // MARK: - steps

    /// `renamex_np` both ways; the check runs on the final path (B1), so a sibling rewritten after `prepare` is caught.
    func exchange(_ candidate: URL) throws(Refusal) {
        guard renamex_np(candidate.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
            throw .swapFailed(String(cString: strerror(errno)))
        }
        guard verify(app) else {
            renamex_np(candidate.path, app.path, UInt32(RENAME_SWAP))
            throw .badSignature
        }
    }

    func remember(_ previous: URL, version: String?) {
        defaults.set(previous.path, forKey: Self.previousKey)
        defaults.set(version, forKey: Self.previousVersionKey)
        defaults.set(0, forKey: Self.launchesKey)
    }

    /// Deletes `bundle`'s folder only when it is a `.Collie-update-*` next to the app (never anything else).
    func removeSibling(of bundle: URL) {
        let dir = bundle.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix(Self.siblingPrefix),
              dir.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    public static func version(_ app: URL) -> String? {
        info(app)?["CFBundleShortVersionString"] as? String
    }

    static func info(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    static func checkInfo(_ app: URL, manifest: UpdateManifest, system: OperatingSystemVersion) throws(Refusal) {
        let found = version(app)
        guard found == manifest.version else { throw .badVersion(found ?? "?") }
        guard let min = info(app)?["LSMinimumSystemVersion"] as? String else { return }
        let comps = min.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(comps.count), comps.allSatisfy({ $0 != nil }) else { throw .badVersion("macOS \(min)") }
        let need = comps.map { $0! } + Array(repeating: 0, count: 3 - comps.count)
        guard ![system.majorVersion, system.minorVersion, system.patchVersion].lexicographicallyPrecedes(need) else {
            throw .badVersion("macOS \(min)")
        }
    }

    /// Only files, dirs and relative symlinks that really resolve inside the bundle; no setuid/setgid.
    static func scan(_ app: URL) throws(Refusal) {
        guard let root = realpath(app.path, nil) else { throw .badSignature }
        let rootPath = String(cString: root); free(root)
        for rel in FileManager.default.subpaths(atPath: app.path) ?? [] {
            let path = app.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(path, &st) == 0, !setID(st.st_mode) else { throw .badSignature }
            switch st.st_mode & S_IFMT {
            case S_IFREG, S_IFDIR: continue
            case S_IFLNK:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), !target.hasPrefix("/"),
                      let real = realpath(path, nil) else { throw .badSignature }
                let r = String(cString: real); free(real)
                guard r == rootPath || r.hasPrefix(rootPath + "/") else { throw .badSignature }
            default: throw .badSignature
            }
        }
    }

    static func setID(_ mode: mode_t) -> Bool { mode & (S_ISUID | S_ISGID) != 0 }

    static func stripQuarantine(_ dir: URL) {
        for rel in [""] + (FileManager.default.subpaths(atPath: dir.path) ?? []) {
            removexattr(rel.isEmpty ? dir.path : dir.appendingPathComponent(rel).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static func ditto(_ from: URL, _ to: URL) throws(Refusal) {
        do { _ = try run("/usr/bin/ditto", [from.path, to.path]) } catch { throw .swapFailed("copiar o app: \(error)") }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: ["tool": tool]) }
        return data
    }
}
