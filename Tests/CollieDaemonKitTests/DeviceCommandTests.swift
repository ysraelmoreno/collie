import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieDevice
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
        unsetenv("COLLIE_FAKE_ADB_TTY")   // default: /dev/tty prints nothing, so device.ui falls back to the file dump
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

/// Temp ANDROID_AVD_HOME + fake avdmanager/java/SDK image (as LiteAvdServiceTests); never touches ~/.android.
private struct LiteFx {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("litecmd-\(UUID().uuidString.prefix(8))")
    var avdHome: URL { dir.appendingPathComponent("avd") }
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sdk/emulator"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sdk/system-images/android-37.0/google_apis/arm64-v8a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("jdk/bin"), withIntermediateDirectories: true)
        try script("jdk/bin/java", "exit 0"); try script("sdk/emulator/emulator", "exit 0")
        try script("avdmanager", """
        if [ "$1" = create ]; then mkdir -p "$ANDROID_AVD_HOME/collie-lite.avd"; printf 'hw.ramSize=2048\\n' > "$ANDROID_AVD_HOME/collie-lite.avd/config.ini"; fi
        if [ "$1" = delete ]; then rm -rf "$ANDROID_AVD_HOME/collie-lite.avd"; fi
        """)
    }
    func script(_ name: String, _ body: String) throws {
        let u = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
    func daemon(_ body: (Daemon, Paths) async throws -> Void) async throws {
        let mgr = AvdManager(url: dir.appendingPathComponent("avdmanager"), javaHome: dir.appendingPathComponent("jdk").path)
        try await withDaemon(configure: {
            $0.adbPath = URL(fileURLWithPath: fixtures.appendingPathComponent("fake-adb.sh").path)
            $0.emulatorPath = dir.appendingPathComponent("sdk/emulator/emulator")
            $0.emulatorEnv = ["ANDROID_AVD_HOME": avdHome.path]
            $0.avdManager = { mgr }
        }, body)
    }
}

@Suite(.serialized) struct DeviceCommandTests {

    /// d4: `device flow on|off|status`; only the user turns it on; a terminal sees its own paddock.
    @Test func flowLogOptInPerPaddock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flag = dir.appendingPathComponent(".collie/flows/enabled").path
        try await withDevice { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": "k", "folder": dir.path]).ok)
            let s = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                args: ["name": .string("A"), "preset": .string("shell"), "paddock": .string("k")]), to: p.socket, timeoutSeconds: 60)
            guard case .object(let so)? = s.result, case .string(let id)? = so["id"] else { Issue.record("\(s)"); return }
            let a = Term(id: id, token: try await tokenOf(d, id))

            let st = try await call(p, a, "device.flow")
            #expect(st.ok && field(st, "enabled") == .bool(false) && field(st, "paddock") == .string("k"), "\(st)")
            let on = try await call(p, a, "device.flow", ["action": "on"])
            #expect(!on.ok && on.error?.code == .unauthorized)
            #expect(!FileManager.default.fileExists(atPath: flag))
            #expect(!(try await call(p, a, "device.flow", ["action": "status", "paddock": "k"])).ok)

            let u = try await admin(d, p, "device.flow", ["action": "on", "paddock": "k"])
            #expect(u.ok && field(u, "enabled") == .bool(true), "\(u)")
            #expect(FileManager.default.fileExists(atPath: flag))
            #expect(field(try await call(p, a, "device.flow"), "enabled") == .bool(true))
            #expect(field(try await call(p, a, "device.flow", ["action": "off"]), "enabled") == .bool(false))
            #expect(!FileManager.default.fileExists(atPath: flag))
            #expect(!(try await admin(d, p, "device.flow", ["action": "nuke", "paddock": "k"])).ok)
        }
    }

    @Test func liteCreateIsAdminOnly() async throws {
        let fx = try LiteFx(); defer { try? FileManager.default.removeItem(at: fx.dir) }
        try await fx.daemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            let r = try await call(p, m, "device.lite.create")
            #expect(!r.ok && r.error?.code == .unauthorized)
            #expect(!FileManager.default.fileExists(atPath: fx.avdHome.appendingPathComponent("collie-lite.avd").path))
        }
    }
    @Test func helperInstallIsAdminOnlyAndStatusSaysWhy() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            let r = try await call(p, m, "device.helper", ["action": "install"])
            #expect(!r.ok && r.error?.code == .unauthorized, "\(r)")
            let i = try await admin(d, p, "device.helper", ["action": "install"])   // the test daemon bundles no APK
            #expect(i.ok, "\(i)")
            #expect(field(i, "state") == .string("fallback") && field(i, "reason") == .string("collie-helper.apk is not bundled"))
            let s = try await call(p, m, "device.helper")
            #expect(s.ok && field(s, "source") == .string("uiautomator") && field(s, "serial") == .string("emulator-5554"), "\(s)")
            #expect(!(try await call(p, m, "device.helper", ["action": "nuke"])).ok)
        }
    }
    @Test func liteCreateReturnsTheRow() async throws {
        let fx = try LiteFx(); defer { try? FileManager.default.removeItem(at: fx.dir) }
        try await fx.daemon { d, p in
            let r = try await admin(d, p, "device.lite.create")
            #expect(r.ok, "\(r)")
            #expect(field(r, "name") == .string("collie-lite") && field(r, "created") == .string("true"))
            #expect(field(r, "image") == .string("system-images;android-37.0;google_apis;arm64-v8a"))
        }
    }
    @Test func liteRemoveReturnsEmpty() async throws {
        let fx = try LiteFx(); defer { try? FileManager.default.removeItem(at: fx.dir) }
        try await fx.daemon { d, p in
            _ = try await admin(d, p, "device.lite.create")
            let r = try await admin(d, p, "device.lite.remove")
            #expect(r.ok, "\(r)")
            #expect(r.result == .object([:]))
            #expect(!FileManager.default.fileExists(atPath: fx.avdHome.appendingPathComponent("collie-lite.avd").path))
        }
    }
    @Test func helpListsBothCommands() {
        for n in ["device.lite.create", "device.lite.remove"] {
            let c = Commands.spec(n)
            #expect(c?.panelFree == true && c?.timeoutSeconds == 90 && c?.exposedToMCP == false)
            #expect(c?.summary.contains("~/.android/avd") == true)
        }
        #expect(Commands.spec("device.lite.create")?.summary.contains("cmdline-tools") == true)
    }
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

    @Test func thenUiReturnsTreeAndUpdatesRefs() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.tap", ["x": "1", "y": "2"]).result == .object([:]))   // no --then: {} as before
            let r = try await call(p, m, "device.tap", ["x": "3", "y": "4", "then": "ui", "settle": "0"])
            guard case .object(let ui)? = field(r, "ui"), case .string(let tree)? = ui["tree"] else { Issue.record("\(r)"); return }
            #expect(tree.contains("[e1]") && tree.contains("Login") && ui["truncated"] == .bool(false) && ui["nodes"] != nil && ui["total"] != nil)
            #expect(fx.lines.contains("-s emulator-5554 shell input tap 3 4") && fx.lines.contains { $0.contains("uiautomator dump") })
            #expect(try await call(p, m, "device.tap", ["ref": "e1"]).ok)   // refs came from --then ui, no device.ui call
            #expect(field(try await call(p, m, "device.key", ["key": "Enter", "then": "ui", "settle": "0"]), "ui") != nil)
        }
    }

    // tap --text/--id resolution (UITree.target), on a hand-made tree
    private func node(_ ref: String, _ text: String = "", desc: String = "", id: String = "", clickable: Bool = false, depth: Int) -> UINode {
        UINode(ref: ref, cls: "android.widget.View", text: text, desc: desc, id: id, bounds: .zero, clickable: clickable, depth: depth)
    }
    private var tree: [UINode] {
        [node("e1", depth: 0),
         node("e2", id: "configuration_fab", clickable: true, depth: 1),
         node("e3", clickable: true, depth: 1),
         node("e4", "Open Deals", depth: 2),
         node("e5", "Open Deals later", clickable: true, depth: 1),
         node("e6", desc: "Settings", clickable: true, depth: 1),
         node("e7", "Settings", clickable: true, depth: 1)]
    }

    @Test func tapTextUniqueMatchIgnoresCaseAndPrefersEqual() throws {
        #expect(try UITree.target(tree, text: "open deals", id: nil, nth: nil).ref == "e3")   // equal beats "Open Deals later"
        #expect(try UITree.target(tree, text: "later", id: nil, nth: nil).ref == "e5")   // contains
        #expect(try UITree.target(tree, text: nil, id: "configuration_fab", nth: nil).ref == "e2")
    }

    @Test func tapTextClimbsToClickableAncestor() throws {
        #expect(try UITree.target(tree, text: "Open Deals", id: nil, nth: nil).ref == "e3")   // e4 isn't clickable, e3 holds it
        let lone = [node("e1", depth: 0), node("e2", "Plain", depth: 1)]
        #expect(try UITree.target(lone, text: "plain", id: nil, nth: nil).ref == "e2")   // no clickable ancestor: the node itself
    }

    @Test func tapTextAmbiguousListsCandidates() {
        #expect(throws: ProtocolError.self) { try UITree.target(tree, text: "settings", id: nil, nth: nil) }
        do { _ = try UITree.target(tree, text: "settings", id: nil, nth: nil) } catch {
            #expect(error.code == .invalidArgs && error.message.contains("e6 \"Settings\"") && error.message.contains("e7 \"Settings\"")
                    && error.message.contains("--nth"), "\(error.message)")
        }
    }

    @Test func tapTextNthPicksOne() throws {
        #expect(try UITree.target(tree, text: "settings", id: nil, nth: 2).ref == "e7")
        do { _ = try UITree.target(tree, text: "settings", id: nil, nth: 3); Issue.record("nth 3 of 2") } catch {
            #expect(error.code == .invalidArgs)
        }
    }

    @Test func tapTextNotFoundSuggestsSimilar() {
        do { _ = try UITree.target(tree, text: "Close Deals", id: nil, nth: nil); Issue.record("found") } catch {
            #expect(error.code == .notFound && error.message.contains("Open Deals") && !error.message.contains("Settings"), "\(error.message)")
        }
    }

    @Test func uiDumpsThroughDevTtyInOneAdbCall() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_TTY", "1", 1)
        defer { unsetenv("COLLIE_FAKE_ADB_TTY") }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.ui")
            guard case .string(let tree)? = field(r, "tree") else { Issue.record("\(r)"); return }
            #expect(tree.contains("[e1]") && tree.contains("Login") && field(r, "timingMs") == nil)
            #expect(fx.lines.contains("-s emulator-5554 exec-out uiautomator dump /dev/tty"))
            #expect(!fx.lines.contains { $0.contains("/sdcard/collie-ui.xml") })   // no file dump, no cat
        }
    }

    @Test func uiFallsBackToTheFileDumpWhenDevTtyGivesNoXml() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.ui", ["timing": "true"])
            guard case .string(let tree)? = field(r, "tree") else { Issue.record("\(r)"); return }
            #expect(tree.contains("[e1]") && tree.contains("Login"))
            #expect(fx.lines.contains("-s emulator-5554 shell uiautomator dump /sdcard/collie-ui.xml"))
            guard case .object(let t)? = field(r, "timingMs") else { Issue.record("\(r)"); return }
            #expect(t["dump"] == .string("file"))
            if case .number(let a)? = t["adb"], case .number(let b)? = t["parse"] { #expect(a >= 0 && b >= 0) } else { Issue.record("\(t)") }
        }
    }

    @Test func screenTimingAddsTheGroupStep() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_TTY", "1", 1)
        defer { unsetenv("COLLIE_FAKE_ADB_TTY") }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.screen", ["timing": "true"])
            guard case .object(let t)? = field(r, "timingMs") else { Issue.record("\(r)"); return }
            #expect(t["dump"] == .string("tty") && t["adb"] != nil && t["parse"] != nil && t["group"] != nil && t["sig"] == field(r, "sig"), "\(t)")
            #expect(field(try await call(p, m, "device.screen"), "timingMs") == nil)
        }
    }

    @Test func screenGroupsTheTreeAndReportsWhatChanged() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.screen")
            guard case .string(let text)? = field(r, "text") else { Issue.record("\(r)"); return }
            #expect(text.hasPrefix("Tela: Offers   [voltar]\nAbas: [Points*] [Combos]") && !text.contains("Mudou"), "\(text)")
            // d1: the screen's signature, on the text and as a field
            guard case .string(let sig)? = field(r, "sig") else { Issue.record("\(r)"); return }
            #expect(sig.count == 12 && text.contains("\nsig=\(sig)"), "\(text)")
            #expect(field(r, "changed") == .array([]) && field(r, "tree") == nil)
            guard case .array(let fab)? = field(r, "floating"), case .object(let f)? = fab.first, case .string(let ref)? = f["ref"] else { Issue.record("\(r)"); return }
            #expect(try await call(p, m, "device.tap", ["ref": ref]).ok)   // screen refs are device.ui refs
            #expect(fx.lines.contains("-s emulator-5554 shell input tap 632 136"))
            setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("ui-dump.xml").path, 1)
            let next = try await UnixSocketClient.send(Request(id: "m", terminalId: m.id, token: m.token, command: "device.screen",
                                                               args: ["all": .bool(true)]), to: p.socket, timeoutSeconds: 60)   // a flag, as the CLI sends it
            guard case .array(let changed)? = field(next, "changed") else { Issue.record("\(next)"); return }
            #expect(changed.first == .string("título Offers → -"), "\(changed)")
            guard case .string(let tree)? = field(next, "tree") else { Issue.record("\(next)"); return }
            #expect(tree.contains("Login"))   // ui-dump.xml: Welcome sits below the top 15% of the nodes' extent, so no title
        }
    }

    @Test func findReturnsTheMatchAndItsRefStaysValid() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.find", ["text": "combos"])
            guard case .string(let ref)? = field(r, "ref"), case .object(let c)? = field(r, "center") else { Issue.record("\(r)"); return }
            #expect(field(r, "found") == .bool(true) && field(r, "label") == .string("Combos") && field(r, "role") == .string("tab"), "\(r)")
            #expect(field(r, "clickable") == .bool(true) && c["x"] != nil && c["y"] != nil, "\(r)")
            let dumps = fx.lines.filter { $0.contains("uiautomator dump") }.count
            #expect(try await call(p, m, "device.tap", ["ref": ref]).ok)   // no device.ui between
            #expect(fx.lines.filter { $0.contains("uiautomator dump") }.count == dumps)
            let s = try await call(p, m, "device.find", ["text": "Filter", "then": "screen"])
            guard case .object(let screen)? = field(s, "screen"), case .string(let text)? = screen["text"] else { Issue.record("\(s)"); return }
            #expect(text.hasPrefix("Tela: Offers") && field(s, "role") == .string("button"), "\(s)")
        }
    }

    @Test func findNotFoundAndRoleFilter() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let none = try await call(p, m, "device.find", ["text": "Nope"])
            #expect(none.error?.code == .notFound && none.error?.message.contains("similar:") == true, "\(none)")
            #expect(field(try await call(p, m, "device.find", ["text": "Combos", "role": "tab"]), "role") == .string("tab"))
            #expect(try await call(p, m, "device.find", ["text": "Combos", "role": "button"]).error?.code == .notFound)
            #expect(try await call(p, m, "device.find", ["text": "Combos", "role": "list"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.find", ["text": "Combos", "then": "ui"]).error?.code == .invalidArgs)
        }
    }

    /// A list page: a clickable list [0,0][1080,2000] (so find --scroll swipes x 540, y 1500 -> 700) holding `items`.
    private func page(_ fx: Fx, _ name: String, _ items: [String]) throws -> String {
        let rows = items.enumerated().map { i, t in
            "<node index=\"\(i)\" text=\"\(t)\" resource-id=\"\" class=\"android.widget.TextView\" content-desc=\"\" clickable=\"true\" bounds=\"[0,\(i * 200)][1080,\(i * 200 + 200)]\" />"
        }.joined(separator: "\n")
        let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <hierarchy rotation="0"><node index="0" text="" resource-id="com.x:id/list" class="androidx.recyclerview.widget.RecyclerView" content-desc="" clickable="false" scrollable="true" bounds="[0,0][1080,2000]">
        \(rows)
        </node></hierarchy>
        """
        let f = fx.dir.appendingPathComponent(name)
        try xml.write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }
    /// `COLLIE_FAKE_ADB_UI` shows `first`; each swipe moves to the next of `then` (none left: the tree stays).
    private func scrollPages(_ fx: Fx, first: String, then: [String]) throws {
        let ui = fx.dir.appendingPathComponent("ui.xml")
        try Data(contentsOf: URL(fileURLWithPath: first)).write(to: ui)
        setenv("COLLIE_FAKE_ADB_UI", ui.path, 1)
        let list = fx.dir.appendingPathComponent("scroll")
        try then.map { $0 + "\n" }.joined().write(to: list, atomically: true, encoding: .utf8)
        setenv("COLLIE_FAKE_ADB_SCROLL", list.path, 1)
    }
    private let scrollSwipe = "-s emulator-5554 shell input swipe 540 1500 540 700 300"

    @Test func findScrollFindsItOnTheThirdRound() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_SCROLL") }
        try scrollPages(fx, first: try page(fx, "p1", ["Apple", "Banana"]), then: [try page(fx, "p2", ["Cherry", "Date"]), try page(fx, "p3", ["Elder", "Target row"])])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.find", ["text": "target", "scroll": "true"])
            guard case .string(let ref)? = field(r, "ref") else { Issue.record("\(r)"); return }
            #expect(field(r, "label") == .string("Target row") && field(r, "scrolls") == .number(2) && field(r, "endReached") == .bool(false), "\(r)")
            #expect(fx.lines.filter { $0 == scrollSwipe }.count == 2, "\(fx.lines)")
            #expect(try await call(p, m, "device.tap", ["ref": ref]).ok)   // the last dump set the refs
            #expect(fx.lines.contains("-s emulator-5554 shell input tap 540 300"), "\(fx.lines)")
        }
    }

    @Test func findScrollStopsAtTheEndOfTheList() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_SCROLL") }
        try scrollPages(fx, first: try page(fx, "p1", ["Apple", "Banana"]), then: [try page(fx, "p2", ["Cherry", "Date"])])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.find", ["text": "Nope", "scroll": "true"])
            #expect(r.error?.code == .notFound && r.error?.message.contains("(scrolls: 2, endReached: true)") == true, "\(r)")
            #expect(r.error?.message.contains("similar:") == true, "\(r)")
            #expect(fx.lines.filter { $0 == scrollSwipe }.count == 2)   // the 2nd swipe moved nothing
        }
    }

    @Test func findScrollStopsAtMaxAndChecksArgs() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_SCROLL") }
        try scrollPages(fx, first: try page(fx, "p1", ["Apple"]), then: [try page(fx, "p2", ["Cherry"]), try page(fx, "p3", ["Target"])])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.find", ["text": "Target", "scroll": "true", "max": "1", "dir": "up"])
            #expect(r.error?.code == .notFound && r.error?.message.contains("(scrolls: 1, endReached: false)") == true, "\(r)")
            #expect(fx.lines.contains("-s emulator-5554 shell input swipe 540 700 540 1500 300"), "\(fx.lines)")   // up: the other way
            for a in [["max": "0", "scroll": "true"], ["max": "31", "scroll": "true"], ["dir": "left", "scroll": "true"], ["max": "2"], ["dir": "up"]] {
                #expect(try await call(p, m, "device.find", a.merging(["text": "Target"]) { x, _ in x }).error?.code == .invalidArgs, "\(a)")
            }
            let s = try await call(p, m, "device.find", ["text": "Cherry", "scroll": "true", "then": "screen"])   // on screen (p2): no swipe
            #expect(field(s, "scrolls") == .number(0) && field(s, "screen") != nil, "\(s)")
            #expect(fx.lines.filter { $0.contains("input swipe") }.count == 1)
        }
    }

    @Test func tapTextDumpsFreshAndTaps() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.tap", ["text": "login"]).result == .object([:]))   // no device.ui before
            #expect(fx.lines.contains { $0.contains("uiautomator dump") } && fx.lines.contains("-s emulator-5554 shell input tap 540 1210"))
            #expect(try await call(p, m, "device.tap", ["id": "login", "then": "ui", "settle": "0"]).ok)
            #expect(try await call(p, m, "device.tap", ["text": "Nope"]).error?.code == .notFound)
            #expect(try await call(p, m, "device.tap", ["text": "Login", "x": "1", "y": "2"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.tap", ["text": "Login", "ref": "e1"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.tap").error?.code == .invalidArgs)
        }
    }

    @Test func thenRejectsOtherValuesBeforeActing() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "device.tap", ["x": "5", "y": "6", "then": "screenshot"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "device.tap", ["x": "5", "y": "6", "then": "ui", "settle": "3001"]).error?.code == .invalidArgs)
            #expect(!fx.lines.contains("-s emulator-5554 shell input tap 5 6"))
        }
    }

    @Test func waitTextShownGoneAndStableReturnWaitedMs() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            for a in [["text": "login"], ["text": "Nope", "gone": "true"], ["stable": "true"], ["text": "Login", "stable": "true"]] {
                let r = try await call(p, m, "device.wait", a)
                guard case .number(let ms)? = field(r, "waitedMs") else { Issue.record("\(a): \(r)"); continue }
                #expect(field(r, "ok") == .bool(true) && ms >= 0, "\(a)")
            }
            #expect(try await call(p, m, "device.tap", ["ref": "e1"]).ok)   // the wait's dumps updated the refs
        }
    }

    @Test func waitTextSeesTheScreenChange() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let ui = fx.dir.appendingPathComponent("ui.xml")
        try Data(contentsOf: fixtures.appendingPathComponent("offers-ui.xml")).write(to: ui)
        setenv("COLLIE_FAKE_ADB_UI", ui.path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let later = Task {
                try await Task.sleep(for: .milliseconds(600))
                try Data(contentsOf: fixtures.appendingPathComponent("ui-dump.xml")).write(to: ui, options: .atomic)
            }
            let r = try await call(p, m, "device.wait", ["text": "Login", "timeout": "10"])
            try await later.value
            guard case .number(let ms)? = field(r, "waitedMs") else { Issue.record("\(r)"); return }
            #expect(ms >= 500, "\(r)")
            #expect(try await call(p, m, "device.wait", ["text": "Combos", "gone": "true", "timeout": "2"]).ok)   // Offers left
        }
    }

    @Test func waitTimeoutIsATimeoutErrorWithTheLastScreen() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.wait", ["text": "Nope", "timeout": "1"])
            #expect(r.error?.code == .timeout, "\(r)")
            #expect(r.error?.message.contains("Last screen:\nTela: Offers") == true, "\(r)")
        }
    }

    @Test func waitTimeoutParses() throws {
        for (v, ms) in [(JSONValue.string("30"), 30_000), (.string("30s"), 30_000), (.string("500ms"), 500), (.number(60), 60_000), (.string("60000ms"), 60_000)] {
            #expect(try DeviceService.waitTimeoutMs(v).map { [$0.ms] } == [ms] && DeviceService.waitTimeoutMs(v)?.clamped == false, "\(v)")
        }
        #expect(try DeviceService.waitTimeoutMs(nil) == nil)
        // P3: above 60 s (the agent's 120000ms, a bare 120000) waits 60 s with clamped, not invalidArgs
        for v in [JSONValue.string("120000ms"), .string("120000"), .number(120_000), .string("61s"), .string("60001ms"), .string("99999999999999")] {
            let t = try DeviceService.waitTimeoutMs(v)
            #expect(t?.ms == 60_000 && t?.clamped == true, "\(v)")
        }
        let w = try DeviceService.waitSpec(["stable": .bool(true), "timeout": .string("120000ms")])
        #expect(w.timeoutMs == 60_000 && w.clamped)
        for v in [JSONValue.string("30sec"), .string("0"), .string("-5"), .string("0ms"), .string("abc"), .number(1.5)] {
            let e = #expect(throws: ProtocolError.self) { try DeviceService.waitTimeoutMs(v) }
            #expect(e?.code == .invalidArgs && e?.message.hasPrefix("--timeout takes 30, 30s or 500ms") == true && e?.message.contains("\n") == false, "\(v)")
        }
    }

    @Test func waitThenScreen() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.wait", ["text": "Combos", "timeout": "2s", "then": "screen"])
            guard case .object(let screen)? = field(r, "screen"), case .string(let text)? = screen["text"] else { Issue.record("\(r)"); return }
            #expect(field(r, "ok") == .bool(true) && field(r, "waitedMs") != nil && text.hasPrefix("Tela: Offers"), "\(r)")
            let u = try await call(p, m, "device.wait", ["stable": "true", "timeout": "500ms", "then": "ui"])
            guard case .object(let ui)? = field(u, "ui") else { Issue.record("\(u)"); return }
            #expect(ui["tree"] != nil && field(u, "screen") == nil, "\(u)")
            let before = fx.lines.filter { $0.contains("uiautomator dump") }.count
            #expect(try await call(p, m, "device.wait", ["text": "Combos", "then": "screenshot"]).error?.code == .invalidArgs)
            #expect(fx.lines.filter { $0.contains("uiautomator dump") }.count == before)   // bad --then: no dump
        }
    }

    @Test func waitRejectsBadArgsBeforeDumping() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            for a in [[:], ["gone": "true"], ["text": "x", "timeout": "-1"], ["stable": "true", "timeout": "0"], ["text": "x", "timeout": "30sec"]] {
                #expect(try await call(p, m, "device.wait", a).error?.code == .invalidArgs, "\(a)")
            }
            #expect(!fx.lines.contains { $0.contains("uiautomator dump") })
        }
    }

    @Test func thenScreenWithSettleStableReturnsTheGroups() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("offers-ui.xml").path, 1)
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.tap", ["x": "3", "y": "4", "then": "screen", "settle": "stable"])
            guard case .object(let screen)? = field(r, "screen"), case .string(let text)? = screen["text"] else { Issue.record("\(r)"); return }
            #expect(text.hasPrefix("Tela: Offers") && field(r, "settled") == .bool(true) && field(r, "ui") == nil, "\(r)")
            let ui = try await call(p, m, "device.key", ["key": "Enter", "then": "ui", "settle": "stable"])
            #expect(field(ui, "ui") != nil && field(ui, "settled") == .bool(true), "\(ui)")
            #expect(try await call(p, m, "device.tap", ["x": "5", "y": "6", "then": "screen", "settle": "fast"]).error?.code == .invalidArgs)
            #expect(!fx.lines.contains("-s emulator-5554 shell input tap 5 6"))
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

    /// `query-activities --brief` output for `com.example`, one component per launcher.
    private func launchers(_ fx: Fx, _ comps: [String]) throws {
        let f = fx.dir.appendingPathComponent("launchers")
        try comps.enumerated().map { "  Activity #\($0.offset):\n    priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\n    \($0.element)" }
            .joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        setenv("COLLIE_FAKE_ADB_LAUNCHERS", f.path, 1)
    }

    @Test func launchWithTwoLauncherActivitiesStartsTheFirst() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_LAUNCHERS") }
        try launchers(fx, ["com.example/.BrowseActivity", "com.example/leakcanary.internal.activity.LeakLauncherActivity"])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.launch", ["package": "com.example"])
            #expect(r.ok && field(r, "activity") == .string(".BrowseActivity"), "\(r)")
            #expect(fx.lines.contains("-s emulator-5554 shell am start -n com.example/.BrowseActivity"))
            #expect(!fx.lines.contains { $0.contains("monkey") || $0.contains("LeakLauncherActivity") })
        }
    }

    @Test func launchWithOneLauncherActivityStartsIt() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_LAUNCHERS") }
        try launchers(fx, ["com.example/com.example.MainActivity"])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.launch", ["package": "com.example"])
            #expect(r.ok && field(r, "activity") == .string("com.example.MainActivity"), "\(r)")
            #expect(fx.lines.contains("-s emulator-5554 shell am start -n com.example/com.example.MainActivity"))
        }
    }

    @Test func launchWithNoLauncherListFallsBackToMonkey() async throws {
        let fx = try Fx(); defer { fx.cleanup(); unsetenv("COLLIE_FAKE_ADB_LAUNCHERS") }
        try launchers(fx, [])
        try await withDevice { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "device.launch", ["package": "com.example"])
            #expect(r.ok && field(r, "activity") == nil, "\(r)")
            #expect(fx.lines.contains { $0.contains("query-activities") })
            #expect(fx.lines.contains("-s emulator-5554 shell monkey -p com.example -c android.intent.category.LAUNCHER 1"))
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
