import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// `<tmp>/<rel>` as an executable file; returns `<tmp>`.
private func tmpExecutable(_ rel: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-emu-\(UUID().uuidString)")
    let f = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return dir
}

@Test func locatePrefersOverrideThenSdk() throws {
    let dir = try tmpExecutable("emulator/emulator")
    #expect(Emulator.locate(env: ["ANDROID_HOME": dir.path], home: "/nonexistent")?.path == dir.appendingPathComponent("emulator/emulator").path)
    #expect(Emulator.locate(env: [:], home: "/nonexistent") == nil)
}

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

/// Nested in `DeviceCommandTests` (serialized): the fakes are driven through process-wide environment variables.
extension DeviceCommandTests { @Suite struct EmulatorTests {
    /// Fake adb + emulator inputs in a scratch dir; `running`: adb device lines; `names`: `<serial> <avd>` lines.
    private func deviceList(running: [String] = [], names: [String] = [], emulator: String? = nil, failOthers: Bool = false) async throws -> [[String: String]] {
        let dir = URL(fileURLWithPath: "/tmp/collie-emu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func put(_ n: String, _ lines: [String]) throws { try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        try put("devices", ["List of devices attached"] + running); try put("avds", ["Pixel_7_API_34", "Tablet_API_33"]); try put("names", names)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_ADB_AVDNAMES", dir.appendingPathComponent("names").path, 1)
        setenv("COLLIE_FAKE_EMULATOR_AVDS", dir.appendingPathComponent("avds").path, 1)
        let emu = emulator ?? fixtures.appendingPathComponent("fake-emulator.sh").path
        var out: [[String: String]] = []
        try await withDaemon(configure: {
            $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh"); $0.emulatorPath = URL(fileURLWithPath: emu)
            $0.emulatorEnv = ProcessInfo.processInfo.environment   // the fakes read their inputs from it
            if failOthers { $0.adbPath = URL(fileURLWithPath: "/usr/bin/false"); $0.xcrunPath = URL(fileURLWithPath: "/usr/bin/false") }
        }) { d, p in
            let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "device.list"), to: p.socket, timeoutSeconds: 60)
            guard case .array(let rows)? = r.result else { Issue.record("\(r)"); return }
            out = rows.compactMap { if case .object(let o) = $0 { o.compactMapValues { if case .string(let s) = $0 { s } else { nil } } } else { nil } }
        }
        return out
    }

    @Test func listShowsOffAvds() async throws {
        let rows = try await deviceList()
        let off = rows.filter { $0["state"] == "off" }
        #expect(off.map { $0["serial"] } == ["avd:Pixel_7_API_34", "avd:Tablet_API_33"])
        #expect(off.first?["model"] == "Pixel 7 API 34" && off.first?["platform"] == "android")
    }
    @Test func listHidesRunningAvd() async throws {
        let rows = try await deviceList(running: ["emulator-5554 device product:sdk model:Pixel_7"], names: ["emulator-5554 Pixel_7_API_34"])
        #expect(!rows.contains { $0["serial"] == "avd:Pixel_7_API_34" })
        #expect(rows.contains { $0["serial"] == "avd:Tablet_API_33" })
        #expect(rows.contains { $0["serial"] == "emulator-5554" && $0["state"] == "device" })
    }
    @Test func offAvdsSurviveAdbAndSimctlFailing() async throws {
        let rows = try await deviceList(failOthers: true)
        #expect(rows.map { $0["serial"] } == ["avd:Pixel_7_API_34", "avd:Tablet_API_33"])
    }
    @Test func avdNameWithOkFirst() async throws {
        setenv("COLLIE_FAKE_ADB_OK_FIRST", "1", 1); defer { unsetenv("COLLIE_FAKE_ADB_OK_FIRST") }
        let rows = try await deviceList(running: ["emulator-5554 device product:sdk model:Pixel_7"], names: ["emulator-5554 Pixel_7_API_34"])
        #expect(!rows.contains { $0["serial"] == "avd:Pixel_7_API_34" })
    }
    @Test func missingEmulatorListsAsToday() async throws {
        let rows = try await deviceList(running: ["emulator-5554 device product:sdk model:Pixel_7"], emulator: "/nonexistent")
        #expect(!rows.contains { $0["state"] == "off" } && rows.contains { $0["serial"] == "emulator-5554" })
    }

    // MARK: boot (Task 3)

    /// A daemon with the fakes (`emulatorBoot` 5 s; the fake emulator boots as emulator-5556 after 1 s). `running`/`names`
    /// as in `deviceList`; `env`: extra fake knobs, unset afterwards. Kills every fake emulator it launched, even on failure.
    private func withBoot(running: [String] = [], names: [String] = [], env: [String: String] = [:], emulator: String? = nil,
                          _ body: (Daemon, Paths) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-emu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func put(_ n: String, _ lines: [String]) throws { try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        try put("devices", ["List of devices attached"] + running); try put("avds", ["Pixel_7_API_34", "Tablet_API_33"]); try put("names", names)
        let all = env.merging(["COLLIE_FAKE_ADB_DEVICES": dir.appendingPathComponent("devices").path,
                               "COLLIE_FAKE_ADB_AVDNAMES": dir.appendingPathComponent("names").path,
                               "COLLIE_FAKE_EMULATOR_AVDS": dir.appendingPathComponent("avds").path,
                               "COLLIE_FAKE_EMULATOR_LOG": dir.appendingPathComponent("emulator.log").path,
                               "COLLIE_FAKE_EMULATOR_DELAY": "1", "COLLIE_FAKE_EMULATOR_SERIAL": "emulator-5556"]) { a, _ in a }
        for (k, v) in all { setenv(k, v, 1) }
        defer {
            for pid in launchedPids() { kill(pid, SIGKILL) }
            for k in all.keys { unsetenv(k) }
            try? FileManager.default.removeItem(at: dir)
        }
        let emu = emulator ?? fixtures.appendingPathComponent("fake-emulator.sh").path
        try await withDaemon(configure: {
            $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh"); $0.emulatorPath = URL(fileURLWithPath: emu)
            $0.emulatorBoot = .seconds(5); $0.emulatorEnv = ProcessInfo.processInfo.environment   // the fakes read their inputs from it
        }, body)
    }
    /// The fake emulator's `launch <name> <pid>` lines.
    private func emulatorLog() -> [String] {
        guard let f = ProcessInfo.processInfo.environment["COLLIE_FAKE_EMULATOR_LOG"] else { return [] }
        return ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private func launchedPids() -> [pid_t] { emulatorLog().compactMap { $0.split(separator: " ").last.flatMap { pid_t($0) } } }
    private func fakeEmulatorPid() -> pid_t { launchedPids().first ?? -1 }
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                        to: p.socket, timeoutSeconds: 60)
    }
    private func panelState(_ r: Response) -> [String: String] {
        guard case .object(let o)? = r.result, case .object(let st)? = o["state"] else { Issue.record("\(r)"); return [:] }
        return st.compactMapValues { if case .string(let s) = $0 { s } else { nil } }
    }

    @Test func openOffAvdBootsAndUsesSerial() async throws {
        try await withBoot { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "placement": "dock.right"])
            #expect(panelState(r)["serial"] == "emulator-5556")
            #expect(emulatorLog().filter { $0.hasPrefix("launch Pixel_7_API_34") }.count == 1)
        }
    }
    @Test func concurrentOpensLaunchOnce() async throws {
        try await withBoot { d, p in
            async let a = admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "a"])
            async let b = admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "b"])
            let (ra, rb) = try await (a, b)
            #expect(ra.ok && rb.ok, "\(ra) \(rb)")
            #expect(emulatorLog().filter { $0.hasPrefix("launch") }.count == 1)
        }
    }
    @Test func openRunningAvdDoesNotLaunch() async throws {
        try await withBoot(running: ["emulator-5554 device product:sdk model:Pixel_7"], names: ["emulator-5554 Pixel_7_API_34"]) { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            #expect(panelState(r)["serial"] == "emulator-5554" && emulatorLog().isEmpty)
        }
    }
    @Test func openBootingAvdWaitsWithoutLaunch() async throws {
        try await withBoot(running: ["emulator-5554 offline"], names: ["emulator-5554 Pixel_7_API_34"]) { d, p in
            let devs = ProcessInfo.processInfo.environment["COLLIE_FAKE_ADB_DEVICES"]!
            async let r = admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            try await Task.sleep(for: .milliseconds(1500))
            try "List of devices attached\nemulator-5554 device product:sdk model:Pixel_7\n".write(toFile: devs, atomically: true, encoding: .utf8)
            #expect(panelState(try await r)["serial"] == "emulator-5554" && emulatorLog().isEmpty)
        }
    }
    @Test func picksSerialByAvdName() async throws {
        try await withBoot(running: ["emulator-5554 device product:sdk model:Tablet"], names: ["emulator-5554 Tablet_API_33"]) { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            #expect(panelState(r)["serial"] == "emulator-5556")
        }
    }
    @Test func unknownAvdListsKnown() async throws {
        try await withBoot { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Nope"])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("Pixel_7_API_34, Tablet_API_33") == true, "\(r)")
            #expect(emulatorLog().isEmpty)
        }
    }
    @Test func emulatorExitsEarlyFails() async throws {
        try await withBoot(env: ["COLLIE_FAKE_EMULATOR_FAIL": "1"]) { d, p in
            let started = ContinuousClock.now
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            #expect(r.error?.message.contains("broken AVD") == true && ContinuousClock.now - started < .seconds(4), "\(r)")
            #expect(r.error?.message.hasPrefix("Emulator 'Pixel_7_API_34' exited: ") == true)
        }
    }
    @Test func bootTimeoutLeavesEmulatorRunning() async throws {
        try await withBoot(env: ["COLLIE_FAKE_ADB_BOOTED": "0"]) { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            #expect(r.error?.code == .timeout)
            #expect(r.error?.message == "Emulator 'Pixel_7_API_34' did not finish booting in 5 s (it is left running)")
            #expect(kill(fakeEmulatorPid(), 0) == 0)
        }
    }
    @Test func closePanelLeavesEmulatorRunning() async throws {
        try await withBoot { d, p in
            let o = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "d"]); #expect(o.ok, "\(o)")
            let c = try await admin(d, p, "panel.close", ["name": "d"]); #expect(c.ok, "\(c)")
            #expect(kill(fakeEmulatorPid(), 0) == 0)
        }
    }
    @Test func daemonStopLeavesEmulatorRunning() async throws {
        try await withBoot { d, p in
            let o = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"]); #expect(o.ok, "\(o)")
            await d.stop()
            let pid = fakeEmulatorPid()
            #expect(kill(pid, 0) == 0)
            #expect(getsid(pid) != getsid(0) && getpgid(pid) != getpgrp())   // own session: launchd ending the job can't take it
        }
    }
    @Test func openAvdWithoutEmulatorFails() async throws {
        try await withBoot(emulator: "/nonexistent") { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
            #expect(r.error?.code == .unavailable)
        }
    }
} }
