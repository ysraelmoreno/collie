import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// Scratch dir with the fake adb's inputs; the fake reads them from the environment (the daemon runs in-process).
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-adb-\(UUID().uuidString.prefix(8))")
    var log: URL { dir.appendingPathComponent("adb.log") }
    init(devices: [String] = ["emulator-5554          device product:sdk_gphone model:Pixel_7 device:emu"],
         logcat: String = "I/a: hello\nE/b: boom\nI/c: fine\n") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (["List of devices attached"] + devices).joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try logcat.write(to: dir.appendingPathComponent("logcat"), atomically: true, encoding: .utf8)
        try Data().write(to: log)
        setenv("COLLIE_FAKE_ADB_LOG", log.path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_ADB_LOGCAT", dir.appendingPathComponent("logcat").path, 1)
        setenv("COLLIE_FAKE_ADB_PNG", fixtures.appendingPathComponent("screen.png").path, 1)
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("ui-dump.xml").path, 1)
    }
    /// Logged adb invocations, tab-joined args shown space-joined.
    var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func withDevice(adb: String? = nil, _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = URL(fileURLWithPath: adb ?? fixtures.appendingPathComponent("fake-adb.sh").path)
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
    }, body)
}
private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]),
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
/// Shepherd `M` with an open canvas device panel `device-1` (leashed to it).
private func shepherdWithPanel(_ d: Daemon, _ p: Paths, placement: String = "canvas") async throws -> Term {
    let m = try await term(d, p, "M", shepherd: true)
    let r = try await call(p, m, "panel.open", ["plugin": "device", "placement": placement])
    #expect(r.ok, "\(r)")
    return m
}

@Suite(.serialized) struct DeviceCommandTests {
    @Test func listShowsUnauthorized() async throws {
        let fx = try Fx(devices: ["emulator-5554 device product:p model:Pixel_7", "R58 unauthorized"]); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            #expect(try await call(p, m, "panel.open", ["plugin": "device", "serial": "emulator-5554", "placement": "dock.right"]).ok)
            let r = try await call(p, m, "device.list")
            guard case .array(let rows)? = r.result, rows.count == 2, case .object(let a) = rows[0], case .object(let b) = rows[1] else {
                Issue.record("\(r)"); return
            }
            #expect(a["serial"] == .string("emulator-5554") && a["state"] == .string("device") && a["model"] == .string("Pixel_7")
                    && a["panels"] == .array([.string("device-1")]))
            #expect(b["state"] == .string("unauthorized") && b["panels"] == .array([]))
        }
    }

    @Test func missingAdbIsUnavailable() async throws {
        try await withDevice(adb: "/nonexistent/adb") { d, p in
            let r = try await admin(d, p, "device.list")
            #expect(r.error?.code == .unavailable)
            #expect(r.error?.message == "adb not found. Install Android platform-tools (brew install --cask android-platform-tools) or set COLLIE_ADB.")
        }
    }

    @Test func openWithoutSerialNeedsExactlyOne() async throws {
        for (devs, want) in [([], "No device online"),
                             (["a device", "b device"], "Several devices online (a, b); pass --serial")] as [([String], String)] {
            let fx = try Fx(devices: devs); defer { fx.cleanup() }
            try await withDevice { d, p in
                let r = try await admin(d, p, "panel.open", ["plugin": "device"])
                #expect(r.error?.code == .invalidArgs && r.error?.message.hasPrefix(want) == true, "\(r)")
            }
        }
        let fx = try Fx(devices: ["a device", "b device"]); defer { fx.cleanup() }
        try await withDevice { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "b"])
            #expect(r.ok, "\(r)")
        }
        let one = try Fx(devices: ["only device"]); defer { one.cleanup() }
        try await withDevice { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device"])
            guard case .object(let o)? = r.result, case .object(let st)? = o["state"] else { Issue.record("\(r)"); return }
            #expect(st["serial"] == .string("only"))
        }
    }

    @Test func openWithUnknownSerialFails() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let r = try await admin(d, p, "panel.open", ["plugin": "device", "serial": "nope"])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("nope") == true, "\(r)")
        }
    }

    @Test func canvasDeviceNeedsLeash() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            _ = try await shepherdWithPanel(d, p)
            let w = try await term(d, p, "w")
            #expect(try await call(p, w, "device.tap", ["x": "1", "y": "1", "panel": "device-1"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "admin.leash", ["a": "w", "b": "device-1"]).ok)
            let r = try await call(p, w, "device.tap", ["x": "1", "y": "1", "panel": "device-1"])
            #expect(r.ok, "\(r)")
        }
    }

    @Test func dockDeviceReachableByAll() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            _ = try await shepherdWithPanel(d, p, placement: "dock.right")
            let w = try await term(d, p, "w")
            let r = try await call(p, w, "device.tap", ["x": "3", "y": "4"])
            #expect(r.ok, "\(r)")
            #expect(fx.lines.contains("-s emulator-5554 shell input tap 3 4"))
        }
    }

    @Test func screenshotWritesPngWithSize() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.screenshot")
            guard case .string(let path)? = field(r, "path") else { Issue.record("\(r)"); return }
            #expect(field(r, "width") == .number(4) && field(r, "height") == .number(8))
            #expect(path.hasPrefix(p.root.appendingPathComponent("screens").path) && path.hasSuffix(".png"))
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path)))?.count == (try Data(contentsOf: fixtures.appendingPathComponent("screen.png"))).count)
        }
    }

    @Test func uiReturnsTreeAndTapByRef() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.tap", ["ref": "e1"]).error?.code == .notFound)   // no ui yet
            let r = try await call(p, m, "device.ui")
            guard case .string(let tree)? = field(r, "tree") else { Issue.record("\(r)"); return }
            #expect(tree.contains("[e1]") && tree.contains("Login") && field(r, "truncated") == .bool(false))
            #expect(try await call(p, m, "device.tap", ["ref": "e1"]).ok)
            #expect(fx.lines.contains("-s emulator-5554 shell input tap 540 1210"))
            let bad = try await call(p, m, "device.tap", ["ref": "e9"])
            #expect(bad.error?.code == .notFound && bad.error?.message == "Unknown ref e9; run device.ui first")
            #expect(try await call(p, m, "device.tap", ["x": "100001", "y": "1"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.tap", ["x": "1"]).error?.code == .invalidArgs)
        }
    }

    @Test func swipeKeyTextLogcat() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.swipe", ["x1": "1", "y1": "2", "x2": "3", "y2": "4"]).ok)
            #expect(try await call(p, m, "device.swipe", ["x1": "1", "y1": "2", "x2": "3", "y2": "4", "ms": "500"]).ok)
            #expect(try await call(p, m, "device.swipe", ["x1": "1", "y1": "2", "x2": "3", "y2": "4", "ms": "20000"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.key", ["key": "Enter"]).ok)
            #expect(try await call(p, m, "device.key", ["key": "Nope"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.text", ["text": "a b'c"]).ok)
            #expect(try await call(p, m, "device.text", ["text": "a%sb"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.logcat", ["lines": "50"]).ok)
            let g = try await call(p, m, "device.logcat", ["grep": "boom"])
            guard case .string(let text)? = field(g, "text") else { Issue.record("\(g)"); return }
            #expect(text == "E/b: boom")
            #expect(try await call(p, m, "device.logcat", ["lines": "5000"]).error?.code == .invalidArgs)
            let l = fx.lines
            #expect(l.contains("-s emulator-5554 shell input swipe 1 2 3 4 300"))
            #expect(l.contains("-s emulator-5554 shell input swipe 1 2 3 4 500"))
            #expect(l.contains("-s emulator-5554 shell input keyevent 66"))
            #expect(l.contains("-s emulator-5554 shell input text 'a%sb'\\''c'"))
            #expect(l.contains("-s emulator-5554 logcat -d -t 50"))
            #expect(l.contains("-s emulator-5554 logcat -d -t 200"))
        }
    }

    @Test func textRejectsNonASCII() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.text", ["text": "olá"]).error?.code == .invalidArgs)
            #expect(!fx.lines.contains { $0.contains("input text") })
        }
    }

    @Test func installResolvesRelativeToCallerCwd() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try "x".write(to: fx.dir.appendingPathComponent("app.apk"), atomically: true, encoding: .utf8)
        try "x".write(to: fx.dir.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.install", ["path": "app.apk"], cwd: fx.dir.path)
            #expect(r.ok, "\(r)")
            #expect(fx.lines.contains { $0.hasPrefix("-s emulator-5554 install -r ") && $0.hasSuffix("/app.apk") })
            #expect(try await call(p, m, "device.install", ["path": "app.txt"], cwd: fx.dir.path).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.install", ["path": "gone.apk"], cwd: fx.dir.path).error?.code == .notFound)
        }
    }

    @Test func launchEmitsAppLaunched() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.launch", ["package": "com.example"]).ok)
            #expect(try await call(p, m, "device.launch", ["package": "com.example", "activity": ".Main"]).ok)
            #expect(try await call(p, m, "device.launch", ["package": "x; reboot"]).error?.code == .invalidArgs)
            #expect(fx.lines.contains("-s emulator-5554 shell monkey -p com.example -c android.intent.category.LAUNCHER 1"))
            #expect(fx.lines.contains("-s emulator-5554 shell am start -n com.example/.Main"))
            let ev = try await call(p, m, "events")
            guard case .object(let o)? = ev.result, case .array(let es)? = o["events"],
                  case .object(let e)? = es.first, case .object(let pl)? = e["payload"] else { Issue.record("\(ev)"); return }
            #expect(e["name"] == .string("device.app_launched") && pl["package"] == .string("com.example") && es.count == 2)
        }
    }

    @Test func closingPanelDeletesScreenshots() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.screenshot")
            guard case .string(let path)? = field(r, "path") else { Issue.record("\(r)"); return }
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try await call(p, m, "panel.close", ["name": "device-1"]).ok)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func closeDuringScreenshotLeavesNoFile() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_SLEEP", "5", 1); defer { unsetenv("COLLIE_FAKE_ADB_SLEEP") }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            async let shot = call(p, m, "device.screenshot")
            #expect(await waitFor(20) { fx.lines.contains { $0.hasSuffix("exec-out screencap -p") } })   // the fake is now sleeping inside screencap
            #expect(try await call(p, m, "panel.close", ["name": "device-1"]).ok)
            let r = try await shot
            #expect(r.error?.code == .notFound && r.error?.message.contains("closed meanwhile") == true, "\(r)")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: p.root.appendingPathComponent("screens").path)) ?? []
            #expect(left.isEmpty, "\(left)")
        }
    }
}
