import Testing
import Foundation
import CollieCore
@testable import CollieClient

/// Two fake `.app` bundles in a temp dir; `mount`, `verify` and free space injected. Never touches /Applications.
@Suite struct AppUpdateSwapTests {
    final class Box: @unchecked Sendable {
        var verify = true
        var detached = 0
        var free: Int64? = .max
    }

    let tmp: URL
    let parent: URL
    let app: URL
    let volume: URL
    let box = Box()
    let defaults: UserDefaults
    let suite = "AppUpdateSwapTests-\(UUID().uuidString)"

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aus-\(UUID().uuidString)")
        parent = tmp.appendingPathComponent("Applications")
        app = parent.appendingPathComponent("Collie.app")
        volume = tmp.appendingPathComponent("Volume")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try Self.makeApp(app, version: "0.1.0")
        try Self.makeApp(volume.appendingPathComponent("Collie.app"), version: "0.2.0")
        defaults = UserDefaults(suiteName: suite)!
    }

    static func makeApp(_ at: URL, version: String, minimum: String = "15.0") throws {
        let contents = at.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "LSMinimumSystemVersion": minimum,
                                    "CFBundleIdentifier": "dev.collie.app"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Collie"))
    }

    func cleanup() {
        chmod(parent.path, 0o755)
        try? FileManager.default.removeItem(at: tmp)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func swapper(app: URL? = nil) -> AppUpdateSwap {
        let box = box, volume = volume
        return AppUpdateSwap(app: app ?? self.app,
                             mount: { _ in (point: volume, detach: { box.detached += 1 }) },
                             verify: { _ in box.verify },
                             freeSpace: { _ in box.free },
                             defaults: defaults)
    }

    func manifest(_ version: String = "0.2.0", size: Int64 = 1000) -> UpdateManifest {
        let json = """
        {"format":1,"version":"\(version)","tag":"v\(version)","dmg":"Collie-\(version).dmg","size":\(size),
         "sha256":"\(String(repeating: "a", count: 64))","minimumSystemVersion":"15.0","teamId":"\(CodeSignature.team)",
         "figcraftEngine":"0.7.0","page":"https://github.com/ysraelmoreno/collie/releases/tag/v\(version)"}
        """
        return try! UpdateManifest.decode(Data(json.utf8))
    }

    let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
    var dmg: URL { tmp.appendingPathComponent("Collie-0.2.0.dmg") }

    func version(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func siblings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(".Collie-update-") }
    }

    func expectRefusal(_ r: AppUpdateSwap.Refusal, _ body: () throws(AppUpdateSwap.Refusal) -> Void) {
        do { try body(); Issue.record("expected \(r)") } catch { #expect(error == r) }
    }

    @Test func swapsAtomically() throws {
        defer { cleanup() }
        let s = swapper()
        let prepared = try s.prepare(dmg: dmg, manifest: manifest(), system: system)
        #expect(prepared.lastPathComponent == "Collie.app")
        #expect(prepared.deletingLastPathComponent().lastPathComponent.hasPrefix(".Collie-update-"))
        #expect(prepared.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        try s.swap(prepared: prepared)
        #expect(version(app) == "0.2.0")
        #expect(version(prepared) == "0.1.0")
        #expect(defaults.string(forKey: "update.previous") == prepared.path)
        #expect(defaults.string(forKey: "update.previousVersion") == "0.1.0")
        #expect(defaults.integer(forKey: "update.healthyLaunches") == 0)
    }

    @Test func siblingNeverReused() throws {
        defer { cleanup() }
        // Planted: every name a guess might hit already exists with foreign content.
        let planted = parent.appendingPathComponent(".Collie-update-AAAAAA")
        try Self.makeApp(planted.appendingPathComponent("Collie.app"), version: "0.2.0")
        try Data("evil".utf8).write(to: planted.appendingPathComponent("Collie.app/Contents/MacOS/evil"))
        let prepared = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        #expect(prepared.deletingLastPathComponent().standardizedFileURL != planted.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: prepared.appendingPathComponent("Contents/MacOS/evil").path))
        var st = stat()
        #expect(lstat(prepared.deletingLastPathComponent().path, &st) == 0 && st.st_mode & 0o777 == 0o700)
    }

    @Test func postSwapCheckFailsSwapsBack() throws {
        defer { cleanup() }
        let s = swapper()
        let prepared = try s.prepare(dmg: dmg, manifest: manifest(), system: system)
        box.verify = false
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in try s.swap(prepared: prepared) }
        #expect(version(app) == "0.1.0")
        #expect(siblings().isEmpty)
        #expect(defaults.string(forKey: "update.previous") == nil)
    }

    @Test func badVersionRefused() throws {
        defer { cleanup() }
        try FileManager.default.removeItem(at: volume.appendingPathComponent("Collie.app"))
        try Self.makeApp(volume.appendingPathComponent("Collie.app"), version: "0.1.9")
        expectRefusal(.badVersion("0.1.9")) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
        #expect(siblings().isEmpty)
    }

    @Test func minimumSystemRefused() throws {
        defer { cleanup() }
        try FileManager.default.removeItem(at: volume.appendingPathComponent("Collie.app"))
        try Self.makeApp(volume.appendingPathComponent("Collie.app"), version: "0.2.0", minimum: "15.3")
        expectRefusal(.badVersion("macOS 15.3")) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
        #expect(siblings().isEmpty)
    }

    @Test func absoluteSymlinkRefused() throws {
        defer { cleanup() }
        let new = volume.appendingPathComponent("Collie.app/Contents")
        try FileManager.default.createSymbolicLink(atPath: new.appendingPathComponent("abs").path, withDestinationPath: "/bin/sh")
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
        #expect(siblings().isEmpty)
    }

    @Test func relativeSymlinkEscapingRefusedInsideAccepted() throws {
        defer { cleanup() }
        let contents = volume.appendingPathComponent("Collie.app/Contents")
        try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("ok").path, withDestinationPath: "MacOS/Collie")
        _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        // Lexically inside (`s/../..` = Contents), really outside: `s` points at the bundle root.
        try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("MacOS/s").path, withDestinationPath: "../..")
        try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("MacOS/t").path, withDestinationPath: "s/../..")
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
    }

    @Test func setuidModeRefused() {
        #expect(AppUpdateSwap.setID(S_IFREG | 0o4755))
        #expect(AppUpdateSwap.setID(S_IFREG | 0o2755))
        #expect(!AppUpdateSwap.setID(S_IFREG | 0o755))
    }

    /// Needs a filesystem that lets this user set setuid (an agent sandbox returns EPERM: the test is then a no-op).
    @Test func setuidRefused() throws {
        defer { cleanup() }
        let bin = volume.appendingPathComponent("Collie.app/Contents/MacOS/Collie").path
        chmod(bin, 0o4755)
        var st = stat()
        guard lstat(bin, &st) == 0, st.st_mode & S_ISUID != 0 else { return }
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
        #expect(siblings().isEmpty)
    }

    @Test func quarantineStripped() throws {
        defer { cleanup() }
        let bin = volume.appendingPathComponent("Collie.app/Contents/MacOS/Collie").path
        let q = "0081;00000000;Test;"
        #expect(setxattr(bin, "com.apple.quarantine", q, q.utf8.count, 0, 0) == 0)
        let prepared = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        #expect(getxattr(prepared.appendingPathComponent("Contents/MacOS/Collie").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        #expect(getxattr(prepared.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0)
    }

    @Test func translocatedRefused() throws {
        defer { cleanup() }
        let moved = tmp.appendingPathComponent("AppTranslocation/X/d/Collie.app")
        try Self.makeApp(moved, version: "0.1.0")
        #expect(swapper(app: moved).destinationRefusal(tccWarning: false) == .translocated)
    }

    @Test func notWritableRefused() throws {
        defer { cleanup() }
        chmod(parent.path, 0o555)
        #expect(swapper().destinationRefusal(tccWarning: false) == .notWritable)
    }

    @Test func tccWarningRefused() throws {
        defer { cleanup() }
        #expect(swapper().destinationRefusal(tccWarning: true) == .tccFolder)
    }

    @Test func localBuildRefused() throws {
        defer { cleanup() }
        #expect(swapper().destinationRefusal(tccWarning: false) == nil)
        box.verify = false
        #expect(swapper().destinationRefusal(tccWarning: false) == .localBuild)
    }

    @Test func lowSpaceRefused() throws {
        defer { cleanup() }
        box.free = 2999
        expectRefusal(.lowSpace) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(size: 1000), system: system)
        }
        #expect(box.detached == 0)   // refused before mounting
        box.free = 3000
        _ = try swapper().prepare(dmg: dmg, manifest: manifest(size: 1000), system: system)
    }

    @Test func detachAlwaysCalled() throws {
        defer { cleanup() }
        _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        #expect(box.detached == 1)
        box.verify = false
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest(), system: system)
        }
        #expect(box.detached == 2)
        expectRefusal(.badVersion("0.2.0")) { () throws(AppUpdateSwap.Refusal) in
            _ = try swapper().prepare(dmg: dmg, manifest: manifest("0.3.0"), system: system)
        }
        #expect(box.detached == 3)
    }

    @Test func previousKeptUntilSecondHealthyLaunch() throws {
        defer { cleanup() }
        let s = swapper()
        let prepared = try s.prepare(dmg: dmg, manifest: manifest(), system: system)
        try s.swap(prepared: prepared)
        s.launched(healthy: true)
        s.launched(healthy: false)
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        #expect(defaults.integer(forKey: "update.healthyLaunches") == 1)
        s.launched(healthy: true)
        #expect(!FileManager.default.fileExists(atPath: prepared.deletingLastPathComponent().path))
        #expect(defaults.string(forKey: "update.previous") == nil)
        #expect(defaults.string(forKey: "update.previousVersion") == nil)
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test func launchedNeverDeletesOutsideASibling() throws {
        defer { cleanup() }
        let elsewhere = tmp.appendingPathComponent("keep/Collie.app")
        try Self.makeApp(elsewhere, version: "0.1.0")
        defaults.set(elsewhere.path, forKey: "update.previous")
        defaults.set(1, forKey: "update.healthyLaunches")
        swapper().launched(healthy: true)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test func rollbackRestoresPrevious() throws {
        defer { cleanup() }
        let s = swapper()
        let prepared = try s.prepare(dmg: dmg, manifest: manifest(), system: system)
        try s.swap(prepared: prepared)
        box.verify = false
        expectRefusal(.badSignature) { () throws(AppUpdateSwap.Refusal) in try s.rollback() }
        #expect(version(app) == "0.2.0")
        #expect(version(prepared) == "0.1.0")   // a failed rollback keeps the previous
        box.verify = true
        try s.rollback()
        #expect(version(app) == "0.1.0")
        #expect(version(prepared) == "0.2.0")
        #expect(defaults.string(forKey: "update.previousVersion") == "0.2.0")
    }

    @Test func relauncherArgs() {
        #expect(AppUpdateSwap.relauncher(pid: 42, app: URL(fileURLWithPath: "/Applications/Collie.app"))
                == ["-c", "while kill -0 42; do sleep 0.2; done; /usr/bin/open '/Applications/Collie.app'"])
        #expect(AppUpdateSwap.relauncher(pid: 7, app: URL(fileURLWithPath: "/Users/a'b/Apps/Collie.app"))
                == ["-c", "while kill -0 7; do sleep 0.2; done; /usr/bin/open '/Users/a'\\''b/Apps/Collie.app'"])
    }

    @Test func cleanupKeepsPrevious() throws {
        defer { cleanup() }
        let keep = parent.appendingPathComponent(".Collie-update-keep1/Collie.app")
        try Self.makeApp(keep, version: "0.1.0")
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(".Collie-update-old1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        AppUpdateSwap.cleanupOrphans(parent: parent, keep: keep)
        #expect(siblings() == [".Collie-update-keep1"])
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Other.app").path))
        AppUpdateSwap.cleanupOrphans(parent: parent, keep: nil)
        #expect(siblings().isEmpty)
    }
}
