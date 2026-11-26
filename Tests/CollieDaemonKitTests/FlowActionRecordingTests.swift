import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieDevice
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// The fake adb's inputs (as DeviceCommandTests' `Fx`) plus a paddock folder `k` for the flow log.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-flowrec-\(UUID().uuidString.prefix(8))")
    var paddock: URL { dir.appendingPathComponent("k") }
    var actions: URL { paddock.appendingPathComponent(".collie/flows/actions.jsonl") }
    init(ui: String? = nil) throws {
        try FileManager.default.createDirectory(at: paddock, withIntermediateDirectories: true)
        try "List of devices attached\nemulator-5554          device product:sdk_gphone model:Pixel_7 device:emu\n"
            .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("logcat"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("adb.log"))
        let uiFile = dir.appendingPathComponent("ui.xml")
        if let ui { try ui.write(to: uiFile, atomically: true, encoding: .utf8) }
        setenv("COLLIE_FAKE_ADB_LOG", dir.appendingPathComponent("adb.log").path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_ADB_LOGCAT", dir.appendingPathComponent("logcat").path, 1)
        setenv("COLLIE_FAKE_ADB_PNG", fixtures.appendingPathComponent("screen.png").path, 1)
        setenv("COLLIE_FAKE_ADB_UI", ui == nil ? fixtures.appendingPathComponent("ui-dump.xml").path : uiFile.path, 1)
        unsetenv("COLLIE_FAKE_ADB_TTY")
    }
    /// The log's lines as objects.
    var lines: [[String: String]] {
        ((try? String(contentsOf: actions, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func field(_ r: Response, _ k: String) -> JSONValue? { if case .object(let o)? = r.result { o[k] } else { nil } }

/// Daemon with the fake adb, paddock `k` on `fx.paddock`, Shepherd `A` in it with an open canvas device panel;
/// `flowOn`: the user turned the log on.
private func withPaddockDevice(_ fx: Fx, flowOn: Bool = true, _ body: (Daemon, Paths, Term) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh")
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
    }) { d, p in
        #expect(try await admin(d, p, "paddock.create", ["name": "k", "folder": fx.paddock.path]).ok)
        let s = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
            args: ["name": .string("A"), "preset": .string("shell"), "paddock": .string("k"), "shepherd": .bool(true)]), to: p.socket, timeoutSeconds: 60)
        guard case .object(let so)? = s.result, case .string(let id)? = so["id"] else { Issue.record("\(s)"); return }
        let a = Term(id: id, token: try await tokenOf(d, id))
        let o = try await call(p, a, "panel.open", ["plugin": "device"])
        #expect(o.ok, "\(o)")
        if flowOn { #expect(try await admin(d, p, "device.flow", ["action": "on", "paddock": "k"]).ok) }
        try await body(d, p, a)
    }
}

/// d5: the device actions reach the paddock's `FlowActionLog`. Nested in DeviceCommandTests: serialized with it, since
/// both drive the fake adb through process-wide environment variables.
extension DeviceCommandTests {
    @Suite struct FlowActionRecordingTests {
        @Test func tapTextRecordsOriginAndBothSignatures() async throws {
            let fx = try Fx(); defer { fx.cleanup() }
            try await withPaddockDevice(fx) { d, p, a in
                guard case .string(let before)? = field(try await call(p, a, "device.screen"), "sig") else { Issue.record("no sig"); return }
                let r = try await call(p, a, "device.tap", ["text": "Login", "then": "screen", "settle": "0"])
                guard case .object(let screen)? = field(r, "screen"), case .string(let after)? = screen["sig"] else { Issue.record("\(r)"); return }
                await d.router.devices.flowFlushed()
                let l = fx.lines
                #expect(l.count == 1, "\(l)")
                #expect(l.first?["origin"] == "agent:A" && l.first?["action"] == "tap" && l.first?["target"] == "Login")
                #expect(l.first?["sigBefore"] == before && l.first?["sigAfter"] == after && !after.isEmpty)
                #expect(try await call(p, a, "device.screen").ok)   // a read is not an action
                #expect(try await call(p, a, "device.key", ["key": "back"]).ok)
                await d.router.devices.flowFlushed()
                #expect(fx.lines.count == 2 && fx.lines.last?["action"] == "key" && fx.lines.last?["sigAfter"] == "")
            }
        }

        @Test func logOffRecordsNothing() async throws {
            let fx = try Fx(); defer { fx.cleanup() }
            try await withPaddockDevice(fx, flowOn: false) { d, p, a in
                #expect(try await call(p, a, "device.tap", ["text": "Login"]).ok)
                #expect(try await call(p, a, "device.swipe", ["x1": "1", "y1": "2", "x2": "3", "y2": "4"]).ok)
                await d.router.devices.flowFlushed()
                #expect(!FileManager.default.fileExists(atPath: fx.actions.path))
            }
        }

        @Test func writeFailureDoesNotFailTheCommand() async throws {
            let fx = try Fx(); defer { fx.cleanup() }
            try await withPaddockDevice(fx) { d, p, a in
                try FileManager.default.createDirectory(at: fx.actions, withIntermediateDirectories: true)   // the file can't be written
                let r = try await call(p, a, "device.tap", ["x": "3", "y": "4"])
                #expect(r.ok && r.result == .object([:]), "\(r)")
                await d.router.devices.flowFlushed()
                #expect(fx.lines.isEmpty)
            }
        }

        @Test func panelAndAgentHaveDistinctOrigins() async throws {
            let fx = try Fx(); defer { fx.cleanup() }
            try await withPaddockDevice(fx) { d, p, a in
                #expect(try await call(p, a, "device.tap", ["x": "3", "y": "4"]).ok)
                await d.router.devices.recordPanelTap(panel: UUID(), target: "10,20", log: FlowActionLog(paddock: fx.paddock))
                await d.router.devices.flowFlushed()
                #expect(fx.lines.map { $0["origin"] } == ["agent:A", "panel"], "\(fx.lines)")
                #expect(fx.lines.map { $0["target"] } == ["3,4", "10,20"])
            }
        }

        @Test func panelTapDecodesTapsNotDrags() throws {
            var down: (x: Int32, y: Int32)?
            #expect(DeviceService.panelTap(Scrcpy.touch(.down, x: 100, y: 200, width: 720, height: 1280), ios: false, down: &down) == nil)
            #expect(DeviceService.panelTap(Scrcpy.touch(.up, x: 104, y: 198, width: 720, height: 1280), ios: false, down: &down) == "104,198")
            _ = DeviceService.panelTap(Scrcpy.touch(.down, x: 100, y: 200, width: 720, height: 1280), ios: false, down: &down)
            #expect(DeviceService.panelTap(Scrcpy.touch(.up, x: 100, y: 600, width: 720, height: 1280), ios: false, down: &down) == nil)   // a drag
            #expect(DeviceService.panelTap(Scrcpy.text("hi"), ios: false, down: &down) == nil)
            #expect(DeviceService.panelTap(try JSONEncoder().encode(SimInput.tap(x: 12.6, y: 30)), ios: true, down: &down) == "12,30")
            #expect(DeviceService.panelTap(try JSONEncoder().encode(SimInput.text("x")), ios: true, down: &down) == nil)
        }

        @Test func passwordTextStaysMaskedEndToEnd() async throws {
            let ui = """
            <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
            <hierarchy rotation="0">
              <node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">
                <node index="0" text="" resource-id="com.example:id/pw" class="android.widget.EditText" content-desc="Senha" clickable="true" focused="true" password="true" bounds="[100,500][900,600]" />
              </node>
            </hierarchy>
            """
            let fx = try Fx(ui: ui); defer { fx.cleanup() }
            try await withPaddockDevice(fx) { d, p, a in
                #expect(try await call(p, a, "device.ui").ok)
                #expect(try await call(p, a, "device.tap", ["ref": "e1"]).ok)
                #expect(try await call(p, a, "device.text", ["text": "hunter2"]).ok)
                await d.router.devices.flowFlushed()
                let raw = (try? String(contentsOf: fx.actions, encoding: .utf8)) ?? ""
                #expect(!raw.contains("hunter2"), "\(raw)")
                #expect(fx.lines.last?["action"] == "text" && fx.lines.last?["text"] == FlowActionLog.mask)
                #expect(fx.lines.first?["target"] == "Senha")
            }
        }
    }
}
