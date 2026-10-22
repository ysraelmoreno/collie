import Testing
import Foundation
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
private let booted = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163", off = "08A7691B-D06D-4FA3-ACA4-CA260E75DFB1"

/// Scratch dir with the fakes' inputs (adb devices, simctl list, simulator log) and their logs.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-sim-\(UUID().uuidString.prefix(8))")
    var xcrunLog: URL { dir.appendingPathComponent("xcrun.log") }
    var axeLog: URL { dir.appendingPathComponent("axe.log") }
    /// `sims`: (udid, name, simctl state).
    init(android: [String] = [], sims: [(String, String, String)] = [(booted, "iPhone 16e", "Booted"), (off, "iPhone 17 Pro", "Shutdown")]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (["List of devices attached"] + android).joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        let list: [[String: Any]] = sims.map { ["udid": $0.0, "name": $0.1, "state": $0.2, "isAvailable": true] }
        try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-3": list]])
            .write(to: dir.appendingPathComponent("sims.json"))
        try "line one\nE boom here\nline three\n".write(to: dir.appendingPathComponent("sim.log"), atomically: true, encoding: .utf8)
        try Data().write(to: xcrunLog); try Data().write(to: axeLog)
        setenv("COLLIE_FAKE_ADB_LOG", dir.appendingPathComponent("adb.log").path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_ADB_PNG", fixtures.appendingPathComponent("screen.png").path, 1)
        setenv("COLLIE_FAKE_XCRUN_LOG", xcrunLog.path, 1)
        setenv("COLLIE_FAKE_SIM_DEVICES", dir.appendingPathComponent("sims.json").path, 1)
        setenv("COLLIE_FAKE_SIM_LOG", dir.appendingPathComponent("sim.log").path, 1)
        setenv("COLLIE_FAKE_AXE_LOG", axeLog.path, 1)
    }
    private func lines(_ u: URL) -> [String] {
        ((try? String(contentsOf: u, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }
    var xcrun: [String] { lines(xcrunLog) }
    var axe: [String] { lines(axeLog) }
    /// The other suites must not see simulators.
    func cleanup() {
        for k in ["COLLIE_FAKE_XCRUN_LOG", "COLLIE_FAKE_SIM_DEVICES", "COLLIE_FAKE_SIM_LOG", "COLLIE_FAKE_AXE_LOG"] { unsetenv(k) }
        try? FileManager.default.removeItem(at: dir)
    }
}

private func withSim(adb: String? = nil, axe: String? = nil, xcrun: String? = nil, logCap: Int? = nil, _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = URL(fileURLWithPath: adb ?? fixtures.appendingPathComponent("fake-adb.sh").path)
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
        if let axe { $0.axePath = URL(fileURLWithPath: axe) }
        if let xcrun { $0.xcrunPath = URL(fileURLWithPath: xcrun) }
        if let logCap { $0.deviceLogCap = logCap }
    }, body)
}
private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, maestro: Bool = false) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "maestro": .bool(maestro)]),
        to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd,
                                            args: args.mapValues { .string($0) }, cwd: cwd), to: p.socket, timeoutSeconds: 60)
}
private func field(_ r: Response, _ k: String) -> JSONValue? {
    if case .object(let o)? = r.result { return o[k] } else { return nil }
}
/// Maestro `M` with an open canvas panel `device-1` on simulator `udid` (corded to it).
private func maestroWithSim(_ d: Daemon, _ p: Paths, _ udid: String = booted) async throws -> Term {
    let m = try await term(d, p, "M", maestro: true)
    let r = try await call(p, m, "panel.open", ["plugin": "device", "serial": udid])
    #expect(r.ok, "\(r)")
    return m
}

/// Nested in `DeviceCommandTests` (serialized): all of them drive the fakes through process-wide environment variables.
extension DeviceCommandTests { @Suite struct SimCommandTests {
    @Test func listMergesPlatforms() async throws {
        let fx = try Fx(android: ["emulator-5554 device product:p model:Pixel_7"]); defer { fx.cleanup() }
        try await withSim { d, p in
            let r = try await admin(d, p, "device.list")
            guard case .array(let rows)? = r.result else { Issue.record("\(r)"); return }
            let objs = rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
            #expect(objs.count == 3, "\(r)")
            #expect(objs.contains { $0["serial"] == .string("emulator-5554") && $0["platform"] == .string("android") })
            #expect(objs.contains { $0["serial"] == .string(booted) && $0["platform"] == .string("ios") && $0["state"] == .string("booted")
                                    && $0["model"] == .string("iPhone 16e") && $0["product"] == .string("iOS 26.3") && $0["panels"] == .array([]) })
            #expect(objs.contains { $0["serial"] == .string(off) && $0["state"] == .string("shutdown") })
        }
        try await withSim(adb: "/nonexistent/adb") { d, p in
            let r = try await admin(d, p, "device.list")
            guard case .array(let rows)? = r.result else { Issue.record("\(r)"); return }
            #expect(rows.count == 2)
        }
    }

    @Test func openShutdownSimulatorBootsIt() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": off])
            guard case .object(let o)? = r.result, case .object(let st)? = o["state"] else { Issue.record("\(r)"); return }
            #expect(st["platform"] == .string("ios") && st["serial"] == .string(off))
            #expect(fx.xcrun.contains("simctl bootstatus \(off) -b") && !fx.xcrun.contains { $0.hasPrefix("simctl boot ") }, "\(fx.xcrun)")
            _ = try await admin(d, p, "panel.open", ["plugin": "device", "serial": booted])
            #expect(!fx.xcrun.contains("simctl bootstatus \(booted) -b"))
        }
    }

    @Test func openUdidWithoutXcodeIsUnavailable() async throws {
        let fx = try Fx(android: ["emulator-5554 device"]); defer { fx.cleanup() }
        try await withSim(xcrun: "/nonexistent/xcrun") { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": booted])
            #expect(r.error?.code == .unavailable, "\(r)")
            #expect(r.error?.message == "xcrun simctl not available. Install Xcode and run xcode-select --switch.")
            #expect(try await admin(d, p, "panel.open", ["plugin": "device", "serial": "emulator-5554"]).ok)
        }
    }

    @Test func openWithoutSerialAmongSimulators() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device"])
            guard case .object(let o)? = r.result, case .object(let st)? = o["state"] else { Issue.record("\(r)"); return }
            #expect(st["serial"] == .string(booted) && st["platform"] == .string("ios"))
        }
        let both = try Fx(android: ["emulator-5554 device"]); defer { both.cleanup() }
        try await withSim { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device"])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("emulator-5554") == true
                    && r.error?.message.contains(booted) == true, "\(r)")
        }
    }

    @Test func iosCommandsMapToTools() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let m = try await maestroWithSim(d, p)
            #expect(try await call(p, m, "device.tap", ["x": "10", "y": "20"]).ok)
            #expect(try await call(p, m, "device.swipe", ["x1": "1", "y1": "2", "x2": "3", "y2": "4", "ms": "500"]).ok)
            #expect(try await call(p, m, "device.key", ["key": "Enter"]).ok)
            #expect(try await call(p, m, "device.key", ["key": "Home"]).ok)
            let shot = try await call(p, m, "device.screenshot")
            guard case .string(let path)? = field(shot, "path") else { Issue.record("\(shot)"); return }
            #expect(field(shot, "width") == .number(4) && field(shot, "height") == .number(8))
            // points for tap/swipe: describe-ui's 390x844 root; scale = pixels / points
            #expect(field(shot, "pointWidth") == .number(390) && field(shot, "pointHeight") == .number(844) && field(shot, "scale") == .number(4.0 / 390))
            #expect(path.hasPrefix(p.root.appendingPathComponent("screens").path) && FileManager.default.fileExists(atPath: path))
            let ui = try await call(p, m, "device.ui")
            guard case .string(let tree)? = field(ui, "tree") else { Issue.record("\(ui)"); return }
            #expect(tree.contains("[e1]") && field(ui, "truncated") == .bool(false))
            #expect(try await call(p, m, "device.tap", ["ref": "e1"]).ok)
            let n = AXeTree.parse(try Data(contentsOf: fixtures.appendingPathComponent("ios/describe-ui.json"))).nodes[0]
            let g = try await call(p, m, "device.logcat", ["grep": "boom"])
            #expect(field(g, "text") == .string("E boom here") && field(g, "truncated") == .bool(false), "\(g)")
            let a = fx.axe
            #expect(a.contains("tap -x 10 -y 20 --udid \(booted)"), "\(a)")
            #expect(a.contains("swipe --start-x 1 --start-y 2 --end-x 3 --end-y 4 --duration 0.5 --udid \(booted)"))
            #expect(a.contains("key 40 --udid \(booted)") && a.contains("button home --udid \(booted)"))
            #expect(a.contains("describe-ui --udid \(booted)"))
            #expect(a.contains("tap -x \(n.center.x) -y \(n.center.y) --udid \(booted)"))
            #expect(fx.xcrun.contains { $0.hasPrefix("simctl io \(booted) screenshot \(p.root.path)/screens/") })
            #expect(fx.xcrun.contains("simctl spawn \(booted) log show --last 5m --style compact"))
        }
    }

    @Test func iosLogcatRetriesShorterWhenCapped() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let big = (0..<20).map { "old line \($0)" }.joined(separator: "\n") + "\n"
        try big.write(to: fx.dir.appendingPathComponent("sim.log"), atomically: true, encoding: .utf8)
        try "recent line\n".write(to: fx.dir.appendingPathComponent("sim30.log"), atomically: true, encoding: .utf8)
        setenv("COLLIE_FAKE_SIM_LOG30", fx.dir.appendingPathComponent("sim30.log").path, 1); defer { unsetenv("COLLIE_FAKE_SIM_LOG30") }
        try await withSim(logCap: 64) { d, p in
            let m = try await maestroWithSim(d, p)
            let g = try await call(p, m, "device.logcat")
            #expect(field(g, "text") == .string("recent line") && field(g, "truncated") == .bool(false), "\(g)")
            #expect(fx.xcrun.contains("simctl spawn \(booted) log show --last 30s --style compact"))
            try big.write(to: fx.dir.appendingPathComponent("sim30.log"), atomically: true, encoding: .utf8)   // still too much
            #expect(field(try await call(p, m, "device.logcat"), "truncated") == .bool(true))
        }
    }

    @Test func iosTextPassesLiterally() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let m = try await maestroWithSim(d, p)
            #expect(try await call(p, m, "device.text", ["text": "a; $(x) 'b'"]).ok)
            #expect(try await call(p, m, "device.text", ["text": "olá"]).error?.code == .invalidArgs)
            let raw = (try String(contentsOf: fx.axeLog, encoding: .utf8)).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            #expect(raw.contains { $0.first == "type" && $0.contains("a; $(x) 'b'") && $0.contains(booted) }, "\(raw)")
            #expect(raw.filter { $0.first == "type" }.count == 1)
        }
    }

    @Test func iosRejectsAndroidOnlyArgs() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try "x".write(to: fx.dir.appendingPathComponent("foo.apk"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fx.dir.appendingPathComponent("Foo.app"), withIntermediateDirectories: true)
        try await withSim { d, p in
            let m = try await maestroWithSim(d, p)
            let k = try await call(p, m, "device.key", ["key": "Back"])
            #expect(k.error?.code == .invalidArgs && k.error?.message
                    == "Key 'Back' has no iOS equivalent (Enter, Escape, Backspace, Tab, Space, arrows, Home, Lock or a HID usage 0-255)")
            let l = try await call(p, m, "device.launch", ["package": "com.x", "activity": ".Main"])
            #expect(l.error?.code == .invalidArgs && l.error?.message == "--activity is Android-only")
            let i = try await call(p, m, "device.install", ["path": "foo.apk"], cwd: fx.dir.path)
            #expect(i.error?.code == .invalidArgs && i.error?.message == "iOS installs .app bundles")
            #expect(try await call(p, m, "device.launch", ["package": "x; reboot"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.install", ["path": "Foo.app"], cwd: fx.dir.path).ok)
            #expect(fx.xcrun.contains("simctl install \(booted) \(fx.dir.appendingPathComponent("Foo.app").path)"), "\(fx.xcrun)")
            #expect(!fx.xcrun.contains { $0.hasPrefix("simctl launch") })
        }
    }

    @Test func launchEmitsAppLaunchedIOS() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let m = try await maestroWithSim(d, p)
            #expect(try await call(p, m, "device.launch", ["package": "com.example.app"]).ok)
            #expect(fx.xcrun.contains("simctl launch \(booted) com.example.app"))
            let ev = try await call(p, m, "events")
            guard case .object(let o)? = ev.result, case .array(let es)? = o["events"],
                  case .object(let e)? = es.first, case .object(let pl)? = e["payload"] else { Issue.record("\(ev)"); return }
            #expect(e["name"] == .string("device.app_launched") && pl["package"] == .string("com.example.app") && pl["serial"] == .string(booted))
        }
    }

    @Test func missingAXeIsUnavailable() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim(axe: "/nonexistent/axe") { d, p in
            let m = try await maestroWithSim(d, p)
            let r = try await call(p, m, "device.tap", ["x": "1", "y": "1"])
            #expect(r.error?.code == .unavailable)
            #expect(r.error?.message == "AXe not found. Install it with brew install cameroncooke/axe/axe or set COLLIE_AXE.")
        }
    }

    @Test func canvasSimulatorNeedsCord() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            _ = try await maestroWithSim(d, p)
            let w = try await term(d, p, "w")
            #expect(try await call(p, w, "device.tap", ["x": "1", "y": "1", "panel": "device-1"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "admin.connect", ["a": "w", "b": "device-1"]).ok)
            let r = try await call(p, w, "device.tap", ["x": "1", "y": "1", "panel": "device-1"])
            #expect(r.ok, "\(r)")
            #expect(fx.axe.contains("tap -x 1 -y 1 --udid \(booted)"))
        }
    }
} }
