import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
private let udid = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163"

/// Fake simctl inputs (rewritable device state), its log, and a temp crash-reports dir.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-simw-\(UUID().uuidString.prefix(8))")
    var reports: URL { dir.appendingPathComponent("reports") }
    var log: URL { dir.appendingPathComponent("xcrun.log") }
    init(state: String = "Booted") throws {
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try Data().write(to: log)
        setenv("COLLIE_FAKE_XCRUN_LOG", log.path, 1)
        setenv("COLLIE_FAKE_SIM_DEVICES", dir.appendingPathComponent("sims.json").path, 1)
        setenv("COLLIE_FAKE_ADB_LOG", dir.appendingPathComponent("adb.log").path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        try "List of devices attached\n".write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try set(state)
    }
    func set(_ state: String) throws {
        let list: [[String: Any]] = [["udid": udid, "name": "iPhone 16e", "state": state, "isAvailable": true]]
        try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-3": list]])
            .write(to: dir.appendingPathComponent("sims.json"), options: .atomic)
    }
    var xcrun: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    /// A report from the fixture; `forUdid` rewrites its simulator path; `age` seconds in the past.
    func ips(_ name: String, forUdid u: String = udid, age: TimeInterval = 0) throws {
        let t = try String(contentsOf: fixtures.appendingPathComponent("ios/crash.ips"), encoding: .utf8)
            .replacingOccurrences(of: udid, with: u)
        let f = reports.appendingPathComponent(name)
        try t.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: f.path)
    }
    func cleanup() {
        for k in ["COLLIE_FAKE_XCRUN_LOG", "COLLIE_FAKE_SIM_DEVICES", "COLLIE_FAKE_ADB_LOG", "COLLIE_FAKE_ADB_DEVICES"] { unsetenv(k) }
        try? FileManager.default.removeItem(at: dir)
    }
}

private func withSimWatch(_ fx: Fx, open: Bool = true, _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh")
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
        $0.xcrunPath = fixtures.appendingPathComponent("fake-xcrun.sh")
        $0.devicePollInterval = .milliseconds(200)
        $0.crashReportsDir = fx.reports
    }) { d, p in
        if open { #expect(try await admin(d, p, "panel.open", ["plugin": "device", "serial": udid]).ok) }
        try await body(d, p)
    }
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 30)
}
private func events(_ d: Daemon, _ p: Paths) async throws -> [(String, [String: JSONValue])] {
    let r = try await admin(d, p, "events")
    guard case .object(let o)? = r.result, case .array(let rows)? = o["events"] else { return [] }
    return rows.compactMap {
        guard case .object(let e) = $0, case .string(let n)? = e["name"], case .object(let pl)? = e["payload"] else { return nil }
        return (n, pl)
    }
}
private func count(_ d: Daemon, _ p: Paths, _ name: String) async -> Int { ((try? await events(d, p)) ?? []).filter { $0.0 == name }.count }
/// Two more watcher polls (`simctl list`) have started, so at least one ran start to finish from here: under load a fixed
/// sleep may elapse before the first poll (which sets the booted baseline and scans the crash reports).
private func polled(_ fx: Fx) async -> Bool {
    let lists = { fx.xcrun.filter { $0.hasPrefix("simctl\tlist") }.count }
    let n = lists()
    return await waitFor(20) { lists() >= n + 2 }
}

extension DeviceCommandTests { @Suite struct SimWatchTests {
    @Test func bootedToShutdownEmitsDisconnected() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            #expect(await polled(fx))   // baseline
            #expect(await count(d, p, "device.disconnected") == 0)
            try fx.set("Shutdown")
            #expect(await waitFor(5) { await count(d, p, "device.disconnected") == 1 })
            #expect(try await events(d, p).first?.1["serial"] == .string(udid))
        }
    }

    @Test func shutdownToBootedEmitsConnected() async throws {
        let fx = try Fx(state: "Shutdown"); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            #expect(await polled(fx))   // baseline
            #expect(await count(d, p, "device.connected") == 0)
            try fx.set("Booted")
            #expect(await waitFor(5) { await count(d, p, "device.connected") == 1 })
        }
    }

    @Test func newIpsForPanelSimulatorEmitsCrash() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            try fx.ips("Foo-1.ips")
            #expect(await waitFor(5) { await count(d, p, "device.crash") == 1 })
            let e = try await events(d, p).first { $0.0 == "device.crash" }?.1
            #expect(e?["serial"] == .string(udid) && e?["package"] == .string("com.example.foo"))
            #expect(e?["path"] == .string(fx.reports.appendingPathComponent("Foo-1.ips").path))
            if case .string(let t)? = e?["text"] { #expect(t.contains("com.example.foo") && t.utf8.count <= 4096) } else { Issue.record("no text") }
        }
    }

    @Test func ipsForOtherUdidIgnored() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            try fx.ips("Other.ips", forUdid: "11111111-2222-3333-4444-555555555555")
            try fx.ips("Mine.ips")
            #expect(await waitFor(5) { await count(d, p, "device.crash") == 1 })
            try await Task.sleep(for: .milliseconds(600))
            #expect(await count(d, p, "device.crash") == 1)
        }
    }

    @Test func oldIpsBeforeWatchIgnored() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try fx.ips("Old.ips", age: 3600)
        try await withSimWatch(fx) { d, p in
            try fx.ips("New.ips")
            #expect(await waitFor(5) { await count(d, p, "device.crash") == 1 })
            try await Task.sleep(for: .milliseconds(600))
            #expect(await count(d, p, "device.crash") == 1)
        }
    }

    @Test func sameIpsReportedOnce() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            try fx.ips("Foo-1.ips")
            #expect(await waitFor(5) { await count(d, p, "device.crash") == 1 })
            try await Task.sleep(for: .milliseconds(800))
            #expect(await count(d, p, "device.crash") == 1)
        }
    }

    @Test func freshIpsWaitsUntilComplete() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { d, p in
            let f = fx.reports.appendingPathComponent("Half.ips")
            try Data(contentsOf: fixtures.appendingPathComponent("ios/crash.ips")).prefix(150).write(to: f)   // truncated, fresh mtime
            #expect(await polled(fx))   // the half-written report was scanned
            #expect(await count(d, p, "device.crash") == 0)
            try fx.ips("Half.ips")   // completed
            #expect(await waitFor(6) { await count(d, p, "device.crash") == 1 })
        }
    }

    @Test func noIosPanelNoSimctlPolling() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try "List of devices attached\nemulator-5554 device product:p model:Pixel_7\n"
            .write(to: fx.dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try await withSimWatch(fx, open: false) { d, p async throws in
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "serial": "emulator-5554"]).ok)
            let adbLog = fx.dir.appendingPathComponent("adb.log")
            let polls = { ((try? String(contentsOf: adbLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("devices") }.count }
            #expect(await waitFor(5) { polls() >= 3 })   // the poller is running
            let lists = { fx.xcrun.filter { $0.hasPrefix("simctl\tlist") }.count }
            let before = lists()   // panel.open itself lists once to resolve the serial
            let p0 = polls()
            #expect(await waitFor(20) { polls() >= p0 + 3 })   // three more device polls, however slow the machine
            #expect(lists() == before, "\(fx.xcrun)")
        }
    }

    @Test func iosPanelPollsSimctl() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSimWatch(fx) { _, _ in
            let n = { fx.xcrun.filter { $0.hasPrefix("simctl\tlist") }.count }
            #expect(await waitFor(5) { n() >= 3 })
        }
    }
} }
