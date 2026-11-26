import Testing
import Foundation
import CoreGraphics
import ImageIO
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

// wf1: `device.tap`/`device.swipe` with `guard: "destructive"` classify the node they resolved in their own read and refuse
// it before touching. Every test but the OCR-without-label one goes through the real `DeviceService` with a fake device
// (adb + uiautomator, adb + the helper, xcrun + AXe).

private let guarded: [String: JSONValue] = ["guard": .string("destructive")]
private func with(_ a: [String: JSONValue]) -> [String: JSONValue] { a.merging(guarded) { x, _ in x } }

/// The error `f` throws (nil: none).
private func failure(_ f: () async throws -> JSONValue) async -> ProtocolError? {
    do { _ = try await f(); return nil } catch let e as ProtocolError { return e } catch { return ProtocolError(code: .internal, message: "\(error)") }
}
private func destructive(_ e: ProtocolError?) -> Bool { e?.code == .conflict && e?.message.hasPrefix(FlowClassifier.refusedPrefix) == true }

// MARK: Android, uiautomator

private func ax(_ text: String = "", id: String = "", cls: String = "Button", _ b: String, clickable: Bool = false, _ children: [String] = []) -> String {
    #"<node index="0" text="\#(text)" resource-id="\#(id)" class="android.widget.\#(cls)" content-desc="" clickable="\#(clickable)" bounds="\#(b)">"#
        + children.joined() + "</node>"
}
private func xml(_ nodes: [String]) -> String {
    #"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">"#
        + ax(id: "android:id/content", cls: "FrameLayout", "[0,0][1080,2400]", nodes) + "</hierarchy>"
}

/// A `DeviceService` on an adb script of its own (uiautomator, no helper): `uiautomator dump /dev/tty` prints the
/// current `tree` (`show` rewrites it: the screen changes), `screencap -p` a striped PNG; every call is logged.
private struct Droid {
    let dir = URL(fileURLWithPath: "/tmp/collie-wf1-\(UUID().uuidString.prefix(8))")
    let svc: DeviceService
    let panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string("R58M")])
    init(_ tree: String, ocr: (any OCRProvider)? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = dir.appendingPathComponent("adb"), log = dir.appendingPathComponent("adb.log").path
        let shot = dir.appendingPathComponent("in.png")
        try striped(1080, 2400).write(to: shot)
        try """
        #!/bin/sh
        echo "$*" >> '\(log)'
        case "$*" in
          "devices -l") printf 'List of devices attached\\nR58M device product:x\\n' ;;
          *"uiautomator dump /dev/tty") cat '\(dir.path)/ui.xml'; echo 'UI hierchary dumped to: /dev/tty' ;;
          *"exec-out screencap -p") cat '\(shot.path)' ;;
        esac
        exit 0
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { adb }, ocr: ocr) { _, _, _ in }
        try show(tree)
    }
    func show(_ tree: String) throws { try tree.write(to: dir.appendingPathComponent("ui.xml"), atomically: true, encoding: .utf8) }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue { try await svc.run(c, panel: panel, args: a, cwd: nil) }
    var adb: [String] { ((try? String(contentsOf: dir.appendingPathComponent("adb.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var touches: [String] { adb.filter { $0.contains("shell input") } }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}

// MARK: iOS, AXe

private func el(_ type: String, _ label: String = "", id: String = "", _ f: (Int, Int, Int, Int), _ children: [String] = []) -> String {
    #"{"type":"\#(type)","AXLabel":"\#(label)","AXUniqueId":"\#(id)","enabled":true,"frame":{"x":\#(f.0),"y":\#(f.1),"width":\#(f.2),"height":\#(f.3)},"children":["#
        + children.joined(separator: ",") + "]}"
}
/// A labelled `Application` root: the screen `FlowClassifier`'s 90 % cut measures against.
private func app(_ children: [String]) -> String { "[" + el("Application", "Loja", (0, 0, 390, 844), children) + "]" }

/// A `DeviceService` on an iOS panel with its own xcrun (a booted simulator, `io screenshot` copies a 1170×2532 PNG)
/// and AXe (`describe-ui` prints the current `tree`, `show` rewrites it) scripts.
private struct Sim {
    let dir = URL(fileURLWithPath: "/tmp/collie-wf1i-\(UUID().uuidString.prefix(8))")
    let udid = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163"
    let svc: DeviceService
    let panel: Panel
    init(_ tree: String, ocr: (any OCRProvider)? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string(udid), "platform": .string("ios")])
        let xcrun = dir.appendingPathComponent("xcrun"), axe = dir.appendingPathComponent("axe")
        let shot = dir.appendingPathComponent("in.png"), sims = dir.appendingPathComponent("sims.json")
        try striped(1170, 2532).write(to: shot)
        try #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-3":[{"udid":"\#(udid)","name":"iPhone 16e","state":"Booted","isAvailable":true}]}}"#
            .write(to: sims, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        echo "$*" >> '\(dir.path)/xcrun.log'
        case "$2" in
          list) cat '\(sims.path)' ;;
          io) cp '\(shot.path)' "$5" ;;
        esac
        exit 0
        """.write(to: xcrun, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        echo "$*" >> '\(dir.path)/axe.log'
        [ "$1" = describe-ui ] && cat '\(dir.path)/ui.json'
        exit 0
        """.write(to: axe, atomically: true, encoding: .utf8)
        for f in [xcrun, axe] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { nil }, xcrun: xcrun, axe: { axe }, ocr: ocr) { _, _, _ in }
        try show(tree)
    }
    func show(_ tree: String) throws { try tree.write(to: dir.appendingPathComponent("ui.json"), atomically: true, encoding: .utf8) }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue { try await svc.run(c, panel: panel, args: a, cwd: nil) }
    var axe: [String] { ((try? String(contentsOf: dir.appendingPathComponent("axe.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var touches: [String] { axe.filter { $0.hasPrefix("tap ") || $0.hasPrefix("swipe ") } }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}

// MARK: Android, the helper

private func hn(_ p: [Int]?, _ text: String = "", id: String = "", cls: String = "Button", _ b: [Int], clk: Bool = false) -> String {
    let path = p.map { #""p":\#($0),"# } ?? ""
    return #"{\#(path)"text":"\#(text)","desc":"","id":"\#(id)","cls":"android.widget.\#(cls)","b":\#(b),"clk":\#(clk),"sel":false,"chk":false,"en":true,"foc":false,"scr":false,"pw":false}"#
}
private func dumpOf(_ nodes: [String]) -> String {
    "[" + ([hn([], id: "android:id/content", cls: "FrameLayout", [0, 0, 1080, 2400])] + nodes).joined(separator: ",") + "]"
}

/// A `DeviceService` on an adb script whose `forward` reaches `srv` (the helper already listed and enabled).
private struct Helped {
    let dir = URL(fileURLWithPath: "/tmp/collie-wf1h-\(UUID().uuidString.prefix(8))")
    let svc: DeviceService
    let panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string("emulator-5554")])
    init(_ srv: FakeHelper) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = dir.appendingPathComponent("adb"), log = dir.appendingPathComponent("adb.log").path
        try """
        #!/bin/sh
        echo "$*" >> '\(log)'
        case "$*" in
          "devices -l") printf 'List of devices attached\\nemulator-5554 device product:x\\n' ;;
          *"forward tcp:0 localabstract:collie-helper") echo \(srv.port) ;;
          *"settings get secure enabled_accessibility_services") echo '\(HelperProtocol.service)' ;;
        esac
        exit 0
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { adb }, helperApk: { URL(fileURLWithPath: "/bundle/collie-helper.apk") }) { _, _, _ in }
    }
    func ready() async { await svc.helper("emulator-5554").start(install: true) }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue { try await svc.run(c, panel: panel, args: a, cwd: nil) }
    var adb: [String] { ((try? String(contentsOf: dir.appendingPathComponent("adb.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}

// MARK: OCR

private actor FakeOCR: OCRProvider {
    let items: [OCRItem]
    init(_ items: [OCRItem]) { self.items = items }
    func recognize(png: Data, level: OCRLevel, languages: [String]) async throws -> [OCRItem] { items }
}

/// Black with a white stripe (not uniform: the OCR reads it).
private func striped(_ w: Int, _ h: Int) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 3, width: w, height: h / 3))
    let out = NSMutableData()
    let dst = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dst, try #require(ctx.makeImage()), nil)
    _ = CGImageDestinationFinalize(dst)
    return out as Data
}

/// A game screen: one label and a SurfaceView, so the tree misses any other text.
private let game = xml([ax("Jogo", cls: "TextView", "[0,1200][300,1300]"), ax(id: "com.game:id/surface", cls: "SurfaceView", "[0,0][1080,2400]")])
private let iosGame = "[" + el("Application", "", (0, 0, 390, 844), [el("StaticText", "Jogo", (0, 400, 100, 30))]) + "]"   // no label: the OCR is not masked

struct FlowGuardTests {
    // Android and iOS: `tap "Pagar"` refused untouched, `tap "Voltar"` touched.

    @Test func androidGuardRefusesPagarAndTapsVoltar() async throws {
        let fx = try Droid(xml([ax("Voltar", "[0,0][300,100]", clickable: true), ax("Pagar", "[0,2000][1080,2200]", clickable: true)]))
        let e = await failure { try await fx.run("device.tap", with(["text": .string("Pagar")])) }
        #expect(destructive(e), "\(String(describing: e))")
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        #expect(try await fx.run("device.tap", with(["text": .string("Voltar")])) == .object([:]))
        #expect(fx.touches == ["-s R58M shell input tap 150 50"], "\(fx.touches)")
        await fx.cleanup()
    }

    @Test func iosGuardRefusesPagarAndTapsVoltar() async throws {
        let fx = try Sim(app([el("Button", "Voltar", (0, 40, 100, 40)), el("Button", "Pagar", (0, 700, 390, 60))]))
        let e = await failure { try await fx.run("device.tap", with(["text": .string("Pagar")])) }
        #expect(destructive(e), "\(String(describing: e))")
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        #expect(try await fx.run("device.tap", with(["text": .string("Voltar")])) == .object([:]))
        #expect(fx.touches == ["tap -x 50 -y 60 --udid \(fx.udid)"], "\(fx.touches)")
        await fx.cleanup()
    }

    // The screen changes after the last read: what is classified is what is touched, the tap's own read.

    @Test func androidAChangedScreenIsClassifiedInTheTapsReadByTextIdAndPoint() async throws {
        let fx = try Droid(xml([ax("Voltar", id: "com.shop:id/back", "[0,0][300,100]", clickable: true)]))
        _ = try await fx.run("device.screen")   // the old read: "Voltar" at the top
        try fx.show(xml([ax("Pagar", id: "com.shop:id/pay", "[0,0][300,100]", clickable: true),
                         ax("Voltar", id: "com.shop:id/back", "[0,900][300,1000]", clickable: true)]))
        #expect(try await fx.run("device.tap", with(["text": .string("Voltar")])) == .object([:]))
        #expect(try await fx.run("device.tap", with(["id": .string("back")])) == .object([:]))
        #expect(fx.touches == ["-s R58M shell input tap 150 950", "-s R58M shell input tap 150 950"], "\(fx.touches)")
        let e = await failure { try await fx.run("device.tap", with(["x": .number(150), "y": .number(50)])) }   // "Voltar" in the old read
        #expect(destructive(e), "\(String(describing: e))")
        #expect(fx.touches.count == 2, "\(fx.touches)")
        // "Voltar" moved into a clickable row that also says "Excluir": the click acts for both, refused
        try fx.show(xml([ax(id: "com.shop:id/row", cls: "LinearLayout", "[0,900][1080,1100]", clickable: true,
                            [ax("Voltar", cls: "TextView", "[0,900][300,1000]"), ax("Excluir", cls: "TextView", "[800,900][1080,1000]")])]))
        #expect(destructive(await failure { try await fx.run("device.tap", with(["text": .string("Voltar")])) }))
        #expect(fx.touches.count == 2, "\(fx.touches)")
        await fx.cleanup()
    }

    @Test func iosAChangedScreenIsClassifiedInTheTapsReadByTextIdAndPoint() async throws {
        let fx = try Sim(app([el("Button", "Voltar", id: "back", (0, 40, 100, 40))]))
        _ = try await fx.run("device.screen")
        try fx.show(app([el("Button", "Pagar", id: "pay", (0, 40, 100, 40)), el("Button", "Voltar", id: "back", (0, 400, 100, 40))]))
        #expect(try await fx.run("device.tap", with(["text": .string("Voltar")])) == .object([:]))
        #expect(try await fx.run("device.tap", with(["id": .string("back")])) == .object([:]))
        #expect(fx.touches == ["tap -x 50 -y 420 --udid \(fx.udid)", "tap -x 50 -y 420 --udid \(fx.udid)"], "\(fx.touches)")
        let e = await failure { try await fx.run("device.tap", with(["x": .number(50), "y": .number(60)])) }
        #expect(destructive(e), "\(String(describing: e))")
        #expect(fx.touches.count == 2, "\(fx.touches)")
        await fx.cleanup()
    }

    // Android, the helper: a stale path is read again; the node gone, or found again with no path, is refused, never
    // touched at its old centre; found again inside a destructive row, refused by the new read.

    @Test func androidHelperStalePathWithTheNodeGoneIsRefusedNotTappedAtItsOldCentre() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Helped(srv)
        await fx.ready()
        let voltar = dumpOf([hn([0], "Voltar", [0, 0, 300, 100], clk: true)])
        srv.set(nodes: voltar, goneClicks: 1)
        srv.set(dumps: [voltar, dumpOf([hn([0], "Menu", [0, 500, 300, 600], clk: true)])])   // the tap's read, then the read again
        let e = await failure { try await fx.run("device.tap", with(["text": .string("Voltar")])) }
        #expect(e?.code == .conflict && e?.message.contains("old centre not touched") == true, "\(String(describing: e))")
        #expect(!destructive(e))
        #expect(srv.ops.filter { $0.contains(#""op":"click""#) }.count == 1, "\(srv.ops)")
        #expect(!srv.ops.contains { $0.contains(#""op":"tap""#) } && !fx.adb.contains { $0.contains("input tap") }, "\(srv.ops) \(fx.adb)")
        await fx.cleanup()
    }

    @Test func androidHelperNodeFoundAgainWithoutAPathIsNotTappedAtItsOldCentre() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Helped(srv)
        await fx.ready()
        let voltar = dumpOf([hn([0], "Voltar", [0, 0, 300, 100], clk: true)])
        srv.set(nodes: voltar, goneClicks: 1)
        srv.set(dumps: [voltar, dumpOf([hn(nil, "Voltar", [0, 0, 300, 100], clk: true)])])   // found again, no `p`
        let e = await failure { try await fx.run("device.tap", with(["text": .string("Voltar")])) }
        #expect(e?.code == .conflict, "\(String(describing: e))")
        #expect(!srv.ops.contains { $0.contains(#""op":"tap""#) } && !fx.adb.contains { $0.contains("input tap") }, "\(srv.ops) \(fx.adb)")
        await fx.cleanup()
    }

    @Test func androidHelperNodeFoundAgainInADestructiveRowIsRefusedByTheNewRead() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Helped(srv)
        await fx.ready()
        let voltar = dumpOf([hn([0], "Voltar", cls: "TextView", [0, 0, 300, 100], clk: true)])
        let row = dumpOf([hn([0], id: "com.shop:id/row", cls: "LinearLayout", [0, 900, 1080, 1100], clk: true),
                          hn([0, 0], "Voltar", cls: "TextView", [0, 900, 300, 1000]),
                          hn([0, 1], "Excluir conta", cls: "TextView", [800, 900, 1080, 1000])])
        srv.set(nodes: voltar, goneClicks: 1)
        srv.set(dumps: [voltar, row])
        #expect(destructive(await failure { try await fx.run("device.tap", with(["text": .string("Voltar")])) }))
        #expect(srv.ops.filter { $0.contains(#""op":"click""#) }.count == 1, "\(srv.ops)")   // the click on the row never sent
        await fx.cleanup()
    }

    // A swipe on the thumb of a slider that is not clickable is refused.

    @Test func androidSwipeOnTheThumbOfDeslizeParaPagarIsRefused() async throws {
        let fx = try Droid(xml([ax(id: "com.bank:id/slider", cls: "FrameLayout", "[0,2000][1080,2200]",
                                   [ax(id: "com.bank:id/thumb", cls: "ImageView", "[0,2000][200,2200]"),
                                    ax("Deslize para pagar", cls: "TextView", "[300,2050][800,2150]")])]))
        let swipe = ["x1": JSONValue.number(100), "y1": .number(2100), "x2": .number(1000), "y2": .number(2100)]
        #expect(destructive(await failure { try await fx.run("device.swipe", with(swipe)) }))
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        let scroll = ["x1": JSONValue.number(540), "y1": .number(1500), "x2": .number(540), "y2": .number(300)]
        #expect(try await fx.run("device.swipe", with(scroll)) == .object([:]))   // the bare screen above it
        #expect(fx.touches == ["-s R58M shell input swipe 540 1500 540 300 300"], "\(fx.touches)")
        await fx.cleanup()
    }

    @Test func iosSwipeOnTheThumbOfDeslizeParaPagarIsRefused() async throws {
        let fx = try Sim(app([el("Other", id: "slider", (0, 760, 390, 60),
                                 [el("Image", id: "thumb", (0, 760, 60, 60)), el("StaticText", "Deslize para pagar", (100, 775, 200, 30))])]))
        let swipe = ["x1": JSONValue.number(30), "y1": .number(790), "x2": .number(370), "y2": .number(790)]
        #expect(destructive(await failure { try await fx.run("device.swipe", with(swipe)) }))
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        await fx.cleanup()
    }

    // OCR: the label the OCR read is classified; an OCR node with no label is refused.

    @Test func androidAnOCRReadDestructiveLabelIsRefusedAndABenignOneTapped() async throws {
        let fx = try Droid(game, ocr: FakeOCR([OCRItem(text: "Pagar agora", confidence: 0.9, box: CGRect(x: 100, y: 1600, width: 400, height: 80)),
                                               OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))]))
        #expect(destructive(await failure { try await fx.run("device.tap", with(["text": .string("Pagar agora")])) }))
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        let o = try await fx.run("device.tap", with(["text": .string("Iniciar partida")]))
        guard case .object(let r) = o else { Issue.record("\(o)"); await fx.cleanup(); return }
        #expect(r["via"] == .string("ocr"), "\(r)")
        #expect(fx.touches == ["-s R58M shell input tap 300 1040"], "\(fx.touches)")
        await fx.cleanup()
    }

    @Test func iosAnOCRReadDestructiveLabelIsRefused() async throws {
        // pixels (300,1500)-(900,1620) → points (100,500)-(300,540)
        let fx = try Sim(iosGame, ocr: FakeOCR([OCRItem(text: "Confirmar compra", confidence: 0.9, box: CGRect(x: 300, y: 1500, width: 600, height: 120))]))
        _ = try await fx.run("device.ui")   // the point size the OCR scales by
        #expect(destructive(await failure { try await fx.run("device.tap", with(["text": .string("Confirmar compra")])) }))
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        await fx.cleanup()
    }

    @Test func anOCRNodeTheTapResolvesWithNoLabelIsRefused() throws {
        let root = UINode(ref: "e1", cls: "android.widget.FrameLayout", text: "", desc: "", id: "content",
                          bounds: CGRect(x: 0, y: 0, width: 1080, height: 2400), clickable: false, depth: 0)
        var blank = UINode(ref: "o1", cls: "ocr", text: "", desc: "", id: "", bounds: CGRect(x: 300, y: 2000, width: 400, height: 100),
                           clickable: false, depth: 0)
        blank.ocr = true
        for s in [FlowPlan.Step(action: "tap", target: "ref:o1"), FlowPlan.Step(action: "tap", target: "500,2050")] {
            #expect(throws: ProtocolError.self) { try FlowClassifier.guardCheck(s, nodes: [root, blank], touching: blank) }
            do { try FlowClassifier.guardCheck(s, nodes: [root, blank], touching: blank) } catch {
                #expect(error.code == .conflict && error.message.contains("the OCR read no label"), "\(error)")
            }
        }
        var read = blank; read.text = "Iniciar"   // the same node with the label the OCR read runs
        try FlowClassifier.guardCheck(FlowPlan.Step(action: "tap", target: "ref:o1"), nodes: [root, read], touching: read)
    }

    // Fail-closed: no read to classify on.

    @Test func iosAScreenThatCannotBeReadRefusesAGuardedPoint() async throws {
        let fx = try Sim("not json")
        let e = await failure { try await fx.run("device.tap", with(["x": .number(50), "y": .number(60)])) }
        #expect(e?.code == .conflict && e?.message.contains("cannot read the screen") == true, "\(String(describing: e))")
        #expect(fx.touches.isEmpty, "\(fx.touches)")
        await fx.cleanup()
    }

    // Without guard (an agent's own `device tap`), nothing changes.

    @Test func withoutGuardNothingChanges() async throws {
        let fx = try Droid(xml([ax("Pagar", "[0,2000][1080,2200]", clickable: true)]))
        #expect(try await fx.run("device.tap", ["text": .string("Pagar")]) == .object([:]))
        #expect(try await fx.run("device.tap", ["x": .number(540), "y": .number(2100)]) == .object([:]))
        #expect(fx.touches == ["-s R58M shell input tap 540 2100", "-s R58M shell input tap 540 2100"], "\(fx.touches)")
        #expect(fx.adb.filter { $0.contains("uiautomator") }.count == 1, "\(fx.adb)")   // the point reads nothing, as before
        let e = await failure { try await fx.run("device.tap", ["x": .number(540), "y": .number(2100), "guard": .string("off")]) }
        #expect(e?.code == .invalidArgs, "\(String(describing: e))")   // never read as off
        #expect(fx.touches.count == 2)
        await fx.cleanup()
    }

    // The runner sends the guard on every tap and swipe of an unconfirmed plan, and turns its refusal into `refused`.

    @Test func theRunnerGuardsTapsAndSwipesAndReportsTheDevicesRefusal() async throws {
        let fx = try Droid(xml([ax("Voltar", "[0,0][300,100]", clickable: true), ax("Pagar", "[0,2000][1080,2200]", clickable: true)]))
        let svc = fx.svc, panel = fx.panel
        // the plan's own classification lets everything through: the command's guard alone refuses
        var runner = FlowRunner(resolve: { s async throws(ProtocolError) in (false, s) }) { c, a async throws(ProtocolError) in
            try await svc.run(c, panel: panel, args: a, cwd: nil)
        }
        runner.guarded = true
        let plan = try FlowPlan.parse(Data(#"{"steps":[{"action":"tap","target":"Voltar"},{"action":"tap","target":"540,2100"},{"action":"key","target":"Back"}]}"#.utf8))
        #expect(try await runner.run(plan) == .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(2), "done": .number(1)]))
        #expect(fx.touches == ["-s R58M shell input tap 150 50"], "\(fx.touches)")
        // what it sends: guard on tap and swipe, not on key; none once the user confirmed
        actor Sent { var args: [[String: JSONValue]] = []; func add(_ a: [String: JSONValue]) { args.append(a) } }
        for confirmed in [false, true] {
            let sent = Sent()
            var r = FlowRunner(confirmed: confirmed) { _, a async throws(ProtocolError) in await sent.add(a); return .object([:]) }
            r.guarded = true
            _ = try await r.run(try FlowPlan.parse(Data(#"{"steps":[{"action":"tap","target":"Voltar"},{"action":"swipe","target":"1,2,3,4"},{"action":"key","target":"Back"}]}"#.utf8)))
            #expect(await sent.args.map { $0["guard"] } == (confirmed ? [nil, nil, nil] : [.string("destructive"), .string("destructive"), nil]))
        }
        await fx.cleanup()
    }
}
