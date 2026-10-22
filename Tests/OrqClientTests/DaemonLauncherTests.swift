import Testing
import Foundation
import Synchronization
import OrqCore
@testable import OrqClient

@Suite struct DaemonLauncherTests {
    /// Fake launchctl returning realistic (status, stdout) pairs.
    final class Calls: Sendable {
        let log = Mutex<[[String]]>([])
        let printResult: (Int32, String)
        let kickstartStatus: Int32
        let bootstrapStatuses: Mutex<[Int32]>   // consumed per bootstrap call; empty -> 0
        init(print: (Int32, String) = (0, "state = running"), kickstart: Int32 = 0, bootstrap: [Int32] = []) {
            printResult = print; kickstartStatus = kickstart; bootstrapStatuses = Mutex(bootstrap)
        }
        var runner: DaemonLauncher.Launchctl {
            { args in
                self.log.withLock { $0.append(args) }
                switch args[0] {
                case "print": return self.printResult
                case "kickstart": return (self.kickstartStatus, "")
                case "bootstrap": return (self.bootstrapStatuses.withLock { $0.isEmpty ? 0 : $0.removeFirst() }, "")
                default: return (0, "")
                }
            }
        }
        var verbs: [String] { log.withLock { $0.map { $0[0] } } }
    }
    static let notLoaded: (Int32, String) = (113, "Could not find service")
    static let loadedIdle: (Int32, String) = (0, "state = not running")

    func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("orq-launcher-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func plistHasKeepAliveAndRoot() throws {
        let data = DaemonLauncher.plist(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r"))
        let d = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(d["Label"] as? String == "dev.orq.daemon")
        #expect(d["ProgramArguments"] as? [String] == ["/x/orqd", "--root", "/r"])
        #expect(d["KeepAlive"] as? Bool == true)
        #expect(d["RunAtLoad"] as? Bool == true)
        #expect(d["ProcessType"] as? String == "Interactive")
        #expect((d["StandardErrorPath"] as? String)?.hasSuffix("Library/Logs/Orq/orqd.log") == true)   // default logDir
        #expect(d["StandardOutPath"] as? String == d["StandardErrorPath"] as? String)
        #expect(data == DaemonLauncher.plist(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r")))
    }

    @Test func ensureRunningIsIdempotent() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = Calls()
        let root = URL(fileURLWithPath: "/r")
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: root, agentsDir: dir, logDir: dir, launchctl: c.runner)
        #expect(c.verbs == ["bootout", "bootstrap"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dev.orq.daemon.plist").path))
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: root, agentsDir: dir, logDir: dir, launchctl: c.runner)
        #expect(c.verbs == ["bootout", "bootstrap", "print"])   // running -> no bootstrap, no kickstart
    }

    func seed(_ dir: URL) throws {
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r"), agentsDir: dir, logDir: dir, launchctl: Calls().runner)
    }
    func again(_ dir: URL, _ c: Calls) throws {
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r"), agentsDir: dir, logDir: dir, launchctl: c.runner)
    }

    @Test func loadedButIdleKickstarts() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        let c = Calls(print: Self.loadedIdle)
        try again(dir, c)
        #expect(c.verbs == ["print", "kickstart"])
    }

    @Test func notLoadedBootstraps() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        let c = Calls(print: Self.notLoaded)
        try again(dir, c)
        #expect(c.verbs == ["print", "bootstrap"])
    }

    @Test func kickstartFailureFallsBackToBootstrap() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        let c = Calls(print: Self.loadedIdle, kickstart: 113)
        try again(dir, c)
        #expect(c.verbs == ["print", "kickstart", "bootstrap"])
    }

    @Test func bootstrapFailureThrows() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = Calls(bootstrap: [1])
        #expect(throws: DaemonLauncher.LaunchError.bootstrapFailed(1)) { try again(dir, c) }
        #expect(c.verbs == ["bootout", "bootstrap"])   // non-I/O errors are not retried
    }

    @Test func bootstrapRetriesOnIOError() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = Calls(bootstrap: [5, 5, 0])
        try again(dir, c)
        #expect(c.verbs == ["bootout", "bootstrap", "bootstrap", "bootstrap"])
        let d2 = tmp(); defer { try? FileManager.default.removeItem(at: d2) }
        let f = Calls(bootstrap: [5, 5, 5, 5])
        #expect(throws: DaemonLauncher.LaunchError.bootstrapFailed(5)) { try again(d2, f) }
        #expect(f.verbs.filter { $0 == "bootstrap" }.count == 4)
    }

    @Test func writtenPlistIs0644() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("dev.orq.daemon.plist").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o644)
    }

    @Test func rejectsBadLabels() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        for l in ["a/b", "..", "x..y", ""] {
            #expect(throws: DaemonLauncher.LaunchError.invalidLabel(l)) {
                try DaemonLauncher.ensureRunning(orqdPath: "/x", root: URL(fileURLWithPath: "/r"), label: l, agentsDir: dir, logDir: dir, launchctl: Calls().runner)
            }
            #expect(throws: DaemonLauncher.LaunchError.invalidLabel(l)) { try DaemonLauncher.stop(label: l, launchctl: Calls().runner) }
        }
    }

    @Test func changedPlistRebootstraps() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = Calls()
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r"), agentsDir: dir, logDir: dir, launchctl: c.runner)
        try DaemonLauncher.ensureRunning(orqdPath: "/y/orqd", root: URL(fileURLWithPath: "/r"), agentsDir: dir, logDir: dir, launchctl: c.runner)
        #expect(c.verbs == ["bootout", "bootstrap", "bootout", "bootstrap"])
    }

    @Test func customLabelNamesPlistAndTarget() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = Calls()
        try DaemonLauncher.ensureRunning(orqdPath: "/x/orqd", root: URL(fileURLWithPath: "/r"), label: "dev.orq.daemon.t", agentsDir: dir, logDir: dir, launchctl: c.runner)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dev.orq.daemon.t.plist").path))
        #expect(c.log.withLock { $0[0].last }?.hasSuffix("/dev.orq.daemon.t") == true)
        try DaemonLauncher.stop(label: "dev.orq.daemon.t", launchctl: c.runner)
        #expect(c.verbs.last == "bootout")
    }
}

@Suite struct StaleDaemonTests {
    @Test func staleDecision() {
        #expect(!DaemonLauncher.isStale(daemonBuild: "aa", bundledBuild: "aa"))
        #expect(DaemonLauncher.isStale(daemonBuild: "aa", bundledBuild: "bb"))
        #expect(DaemonLauncher.isStale(daemonBuild: nil, bundledBuild: "bb"))      // pre-fix daemon
        #expect(!DaemonLauncher.isStale(daemonBuild: "aa", bundledBuild: nil))     // bundled unreadable
    }

    @Test func restartKickstartsWithKill() throws {
        let seen = Mutex<[[String]]>([])
        try DaemonLauncher.restart(launchctl: { a in seen.withLock { $0.append(a) }; return (0, "") })
        #expect(seen.withLock { $0 } == [["kickstart", "-k", "gui/\(getuid())/dev.orq.daemon"]])
        #expect(throws: DaemonLauncher.LaunchError.restartFailed(3)) { try DaemonLauncher.restart(launchctl: { _ in (3, "") }) }
    }

    @Test func buildIdTracksFileContent() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("orq-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: f) }
        try Data("one".utf8).write(to: f)
        let a = BuildID.of(f)
        #expect(a?.count == 16 && a == BuildID.of(f))
        try Data("two".utf8).write(to: f)
        #expect(BuildID.of(f) != a)
        #expect(BuildID.of(f.appendingPathExtension("missing")) == nil)
    }
}
