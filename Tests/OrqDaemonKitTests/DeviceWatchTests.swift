import Testing
import Foundation
import Darwin
import OrqCore
import OrqProtocol
@testable import OrqDaemonKit

private let fakeAdb = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-adb.sh")

/// Fake adb inputs for the watchers: the device list (rewritable), the crash text, the logcat pid log.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/orq-watch-\(UUID().uuidString.prefix(8))")
    var log: URL { dir.appendingPathComponent("adb.log") }
    var pidsFile: URL { dir.appendingPathComponent("pids") }
    init(crash: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: log); try Data().write(to: pidsFile)
        setenv("ORQ_FAKE_ADB_LOG", log.path, 1)
        setenv("ORQ_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("ORQ_FAKE_ADB_PIDS", pidsFile.path, 1)
        if let crash { setenv("ORQ_FAKE_ADB_CRASH", crash, 1) } else { unsetenv("ORQ_FAKE_ADB_CRASH") }
        try setDevices(["emulator-5554 device product:p model:Pixel_7"])
    }
    func setDevices(_ d: [String]) throws {
        try (["List of devices attached"] + d).joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
    }
    var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }
    /// Pids of the fake's `logcat -b crash` runs (each the leader of its group).
    var pids: [pid_t] {
        ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }
    func cleanup() { pids.forEach { kill(-$0, SIGKILL) }; try? FileManager.default.removeItem(at: dir) }
}

private func withWatch(_ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.adbPath = fakeAdb; $0.emulatorPath = URL(fileURLWithPath: "/nonexistent"); $0.devicePollInterval = .milliseconds(200) }, body)
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 30)
}
/// (name, payload) of every plugin event so far, oldest first.
private func events(_ d: Daemon, _ p: Paths) async throws -> [(String, [String: JSONValue])] {
    let r = try await admin(d, p, "events")
    guard case .object(let o)? = r.result, case .array(let rows)? = o["events"] else { return [] }
    return rows.compactMap {
        guard case .object(let e) = $0, case .string(let n)? = e["name"], case .object(let pl)? = e["payload"] else { return nil }
        return (n, pl)
    }
}
private func dead(_ pids: [pid_t]) -> Bool { !pids.isEmpty && pids.allSatisfy { kill(-$0, 0) != 0 && kill($0, 0) != 0 } }
private func pidfiles(_ p: Paths) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: p.runDir.appendingPathComponent("terminals").path)) ?? []
}

/// Nested in `DeviceCommandTests` (serialized): both drive the fake through process-wide environment variables.
extension DeviceCommandTests { @Suite struct DeviceWatchTests {
    @Test func connectAndDisconnectEvents() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withWatch { d, p in
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right"]).ok)
            #expect(await waitFor(5) { !fx.pids.isEmpty })   // first poll saw it online
            try fx.setDevices([])
            #expect(await waitFor(5) { (try? await events(d, p))?.contains { $0.0 == "device.disconnected" } == true })
            try fx.setDevices(["emulator-5554 device"])
            #expect(await waitFor(5) { (try? await events(d, p))?.contains { $0.0 == "device.connected" } == true })
            try fx.setDevices([])
            #expect(await waitFor(5) { (try? await events(d, p))?.filter { $0.0 == "device.disconnected" }.count == 2 })
            let names = try await events(d, p).map(\.0)
            #expect(names == ["device.disconnected", "device.connected", "device.disconnected"], "\(names)")
            #expect(try await events(d, p).allSatisfy { $0.1["serial"] == .string("emulator-5554") })
        }
    }

    @Test func crashLogBecomesEvent() async throws {
        let crash = """
            E/AndroidRuntime( 4321): FATAL EXCEPTION: main
            E/AndroidRuntime( 4321): Process: com.foo, PID: 4321
            E/AndroidRuntime( 4321): java.lang.RuntimeException: boom
            """
        let fx = try Fx(crash: crash); defer { fx.cleanup() }
        try await withWatch { d, p in
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right"]).ok)
            #expect(await waitFor(5) { (try? await events(d, p))?.contains { $0.0 == "device.crash" } == true })
            guard let e = try await events(d, p).first(where: { $0.0 == "device.crash" })?.1 else { return }
            #expect(e["package"] == .string("com.foo") && e["serial"] == .string("emulator-5554"))
            #expect(e["text"].map { if case .string(let s) = $0 { s.contains("RuntimeException: boom") } else { false } } == true)
            #expect(fx.lines.contains("-s emulator-5554 logcat -b crash -v brief -T 1700000000.000"), "\(fx.lines)")
        }
    }

    @Test func closingLastPanelKillsWatchers() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withWatch { d, p in
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right", "name": "a"]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right", "name": "b"]).ok)
            #expect(await waitFor(5) { !fx.pids.isEmpty })
            #expect(!pidfiles(p).isEmpty)
            #expect(try await admin(d, p, "panel.close", ["name": "a"]).ok)
            try await Task.sleep(for: .milliseconds(600))
            #expect(fx.pids.allSatisfy { kill($0, 0) == 0 })   // b still holds the serial
            #expect(try await admin(d, p, "panel.close", ["name": "b"]).ok)
            #expect(await waitFor(3) { dead(fx.pids) })
            #expect(await waitFor(2) { pidfiles(p).isEmpty }, "\(pidfiles(p))")
        }
    }

    @Test func daemonStopKillsWatchers() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let p = Paths(root: URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: p.root) }
        var c = testConfig(p); c.adbPath = fakeAdb; c.emulatorPath = URL(fileURLWithPath: "/nonexistent"); c.devicePollInterval = .milliseconds(200)
        let d = try Daemon(config: c)
        try await d.start()
        #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right"]).ok)
        #expect(await waitFor(5) { !fx.pids.isEmpty })
        await d.stop()
        #expect(await waitFor(3) { dead(fx.pids) })
        #expect(pidfiles(p).isEmpty)
    }

    @Test func watcherDescendantIsRefusedAdmin() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withWatch { d, p async throws in
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right"]).ok)
            #expect(await waitFor(5) { !fx.pids.isEmpty })
            guard let pid = fx.pids.first else { return }
            do {
                try await d.router.adminOnly(Request(id: "x", token: d.adminToken, command: "admin.list"), peer: pid)
                Issue.record("admin allowed from the logcat watcher")
            } catch { #expect((error as? ProtocolError)?.code == .unauthorized) }
        }
    }

    @Test func restartedDaemonReapsOrphanWatcher() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        // a watcher left behind by a crashed daemon: never terminated, its pidfile still on disk
        let orphan = try LongProcess(executable: fakeAdb, args: ["-s", "x", "logcat", "-b", "crash"],
                                     env: ProcessInfo.processInfo.environment, runDir: paths.runDir,
                                     onLine: { _ in }, onExit: { _ in })
        #expect(await waitFor(5) { fx.pids == [orphan.pid] })
        #expect(pidfiles(paths).count == 1)
        let d = try Daemon(config: testConfig(paths))
        try await d.start()
        #expect(await waitFor(3) { dead([orphan.pid]) })
        await d.stop()
    }
    /// A client that auto-starts the adb server would leave it in our process group (group kills would take it down):
    /// the server is started once, detached, before any other adb call.
    @Test func adbServerStartedOnceFirst() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withWatch { d, p async throws in
            #expect(try await admin(d, p, "device.list").ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right"]).ok)
            #expect(await waitFor(5) { !fx.pids.isEmpty })
            #expect(try await admin(d, p, "device.list").ok)
            #expect(fx.lines.first == "start-server", "\(fx.lines)")
            #expect(fx.lines.filter { $0 == "start-server" }.count == 1)
        }
    }

    /// The last panels close while a poll is emitting (`watch` re-entered from `emit`): no watcher may start afterwards.
    @Test func watchDuringPollEmitStartsNoWatcher() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let serials = ["a", "b", "c", "d", "e"]
        try fx.setDevices(serials.map { "\($0) device" })
        let run = URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: run) }
        final class Box: @unchecked Sendable { var svc: DeviceService? }
        let box = Box()
        let svc = DeviceService(root: run, runDir: run, pollInterval: .milliseconds(100), adb: { fakeAdb }) { _, name, _ in
            if name == "device.disconnected" { await box.svc?.watch(panels: []) }
        }
        box.svc = svc
        await svc.watch(panels: serials.map { Panel(id: UUID(), name: $0, pluginId: "device", placement: .canvas, state: ["serial": .string($0)]) })
        #expect(await waitFor(5) { fx.pids.count == serials.count })
        try fx.setDevices(["a offline"] + serials.dropFirst().map { "\($0) device" })
        #expect(await waitFor(3) { dead(fx.pids) })
        try await Task.sleep(for: .seconds(1))   // room for a stray `date` + logcat spawn
        #expect(fx.pids.count == serials.count && dead(fx.pids), "\(fx.pids)")
        await svc.stop()
    }
}
}
