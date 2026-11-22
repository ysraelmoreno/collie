import Testing
import Foundation
import CoreGraphics
import ImageIO
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// H6b: `device screen` with the OCR fallback, on a fake `OCRProvider` (no device, no Vision).
@Suite struct DeviceOCRTests {
    @Test func aPoorTreeFiresTheOCRAndMergesItsText() async throws {
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))])
        let fx = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
        let s = obj(try await fx.run("device.screen", ["timing": .bool(true)]))
        guard case .array(let lists)? = s["lists"], case .string(let text)? = s["text"] else { Issue.record("\(s)"); await fx.cleanup(); return }
        #expect(lists.contains { obj($0)["label"] == .string("Iniciar partida") && obj($0)["source"] == .string("ocr") }, "\(lists)")
        #expect(text.contains("\"Iniciar partida\" (ocr)") && !text.contains("ocr: unavailable"), "\(text)")
        let t = obj(s["timingMs"])
        #expect(t["trigger"] == .string("labels") && t["ocrLevel"] == .string("accurate") && t["ocrMs"] != nil, "\(t)")
        #expect(await ocr.sizes == [CGSize(width: 1080, height: 2400)])
        #expect(fx.adb.contains { $0.contains("exec-out screencap -p") })
        #expect(!FileManager.default.fileExists(atPath: fx.dir.appendingPathComponent("screens").path))   // the image is never written
        await fx.cleanup()
    }

    @Test func aGoodTreeAndNoOcrSkipTheScreenshot() async throws {
        let ocr = FakeOCR([OCRItem(text: "Extra", confidence: 0.9, box: CGRect(x: 0, y: 0, width: 50, height: 20))])
        let good = try OCRSvc(tree: goodTree, png: textPNG, ocr: ocr)
        let s = obj(try await good.run("device.screen", ["timing": .bool(true)]))
        #expect(obj(s["timingMs"])["trigger"] == nil && s["ocr"] == nil, "\(s)")
        #expect(!good.adb.contains { $0.contains("screencap") })
        await good.cleanup()
        let poor = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
        _ = try await poor.run("device.screen", ["no-ocr": .bool(true)])
        #expect(await ocr.sizes.isEmpty)
        #expect(!poor.adb.contains { $0.contains("screencap") })
        await expectInvalid(try await poor.run("device.screen", ["no-ocr": .bool(true), "ocr": .bool(true)]))
        await poor.cleanup()
    }

    @Test func noProviderOrAnErrorLeavesTheTreeWithANote() async throws {
        for ocr in [nil, FakeOCR([], fail: true)] as [FakeOCR?] {
            let fx = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
            let s = obj(try await fx.run("device.screen"))
            guard case .string(let text)? = s["text"] else { Issue.record("\(s)"); await fx.cleanup(); return }
            #expect(text.hasSuffix("\nocr: unavailable") && s["ocr"] == .string("unavailable"), "\(text)")
            #expect(text.contains("Jogo"))   // the tree still there
            await fx.cleanup()
        }
    }

    @Test func aBlackScreenNeverReachesTheOCR() async throws {
        let ocr = FakeOCR([OCRItem(text: "Fantasma", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))])
        let fx = try OCRSvc(tree: poorTree, png: try png(1080, 2400, stripe: false), ocr: ocr)
        let s = obj(try await fx.run("device.screen", ["ocr": .bool(true)]))
        #expect(await ocr.sizes.isEmpty)
        guard case .string(let text)? = s["text"] else { Issue.record("\(s)"); await fx.cleanup(); return }
        #expect(!text.contains("Fantasma") && !text.contains("ocr: unavailable"), "\(text)")
        await fx.cleanup()
    }

    @Test func regionCropsTheImageAndMovesTheBoxesBack() async throws {
        let ocr = FakeOCR([OCRItem(text: "Recorte", confidence: 0.9, box: CGRect(x: 10, y: 10, width: 50, height: 20))])
        let fx = try OCRSvc(tree: goodTree, png: textPNG, ocr: ocr)   // --region forces the OCR on a good tree
        let s = obj(try await fx.run("device.screen", ["region": .string("100,200,300,400"), "timing": .bool(true)]))
        #expect(obj(s["timingMs"])["trigger"] == .string("flag"), "\(s)")
        #expect(await ocr.sizes == [CGSize(width: 200, height: 200)])
        guard case .array(let lists)? = s["lists"], let item = lists.map(obj).first(where: { $0["source"] == .string("ocr") }),
              case .string(let ref)? = item["ref"] else { Issue.record("\(s)"); await fx.cleanup(); return }
        _ = try await fx.run("device.tap", ["ref": .string(ref)])
        #expect(fx.adb.contains { $0.hasSuffix("shell input tap 135 220") }, "\(fx.adb)")   // (100+10+25, 200+10+10)
        await expectInvalid(try await fx.run("device.screen", ["region": .string("300,200,100,400")]))
        await fx.cleanup()
    }

    // H6c (O4): find and tap --text fall back to the OCR when the tree has no match.

    @Test func findFallsBackToTheOCRWithViaAndTiming() async throws {
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))])
        let fx = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
        let o = obj(try await fx.run("device.find", ["text": .string("iniciar"), "timing": .bool(true)]))
        #expect(o["found"] == .bool(true) && o["via"] == .string("ocr") && o["role"] == .string("text") && o["clickable"] == .bool(false), "\(o)")
        #expect(obj(o["center"]) == ["x": .number(300), "y": .number(1040)], "\(o)")
        guard case .string(let w)? = o["warning"] else { Issue.record("\(o)"); await fx.cleanup(); return }
        #expect(w.contains("no click confirmation"))
        #expect(obj(o["timingMs"])["trigger"] == .string("find") && obj(o["timingMs"])["ocrMs"] != nil, "\(o)")
        #expect(await ocr.sizes.count == 1)
        guard case .string(let ref)? = o["ref"] else { Issue.record("\(o)"); await fx.cleanup(); return }
        _ = try await fx.run("device.tap", ["ref": .string(ref)])   // refs updated: the OCR ref taps next
        #expect(fx.adb.contains { $0.hasSuffix("shell input tap 300 1040") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func tapTextFallsBackToTheOCRAndTapsTheBoxCentre() async throws {
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))])
        let fx = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
        let o = obj(try await fx.run("device.tap", ["text": .string("Iniciar partida")]))
        #expect(o["via"] == .string("ocr") && o["warning"] != nil, "\(o)")
        #expect(fx.adb.contains { $0.hasSuffix("shell input tap 300 1040") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func roleAndNoOcrIgnoreTheOCR() async throws {
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 100, y: 1000, width: 400, height: 80))])
        let fx = try OCRSvc(tree: poorTree, png: textPNG, ocr: ocr)
        await expectNotFound(try await fx.run("device.find", ["text": .string("iniciar"), "role": .string("button")]))
        await expectNotFound(try await fx.run("device.find", ["text": .string("iniciar"), "no-ocr": .bool(true)]))
        await expectNotFound(try await fx.run("device.tap", ["text": .string("iniciar"), "no-ocr": .bool(true)]))
        #expect(await ocr.sizes.isEmpty)
        #expect(!fx.adb.contains { $0.contains("screencap") || $0.contains("input tap") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func aTreeMatchNeverCallsTheProvider() async throws {
        let ocr = FakeOCR([OCRItem(text: "Item 1", confidence: 0.9, box: CGRect(x: 0, y: 0, width: 50, height: 20))])
        let fx = try OCRSvc(tree: goodTree, png: textPNG, ocr: ocr)
        let o = obj(try await fx.run("device.find", ["text": .string("Item 1")]))
        #expect(o["found"] == .bool(true) && o["via"] == nil && o["warning"] == nil, "\(o)")
        let t = obj(try await fx.run("device.tap", ["text": .string("Item 2")]))
        #expect(t["via"] == nil, "\(t)")
        #expect(fx.adb.contains { $0.hasSuffix("shell input tap 540 1600") }, "\(fx.adb)")   // [0,1400][1080,1800]
        #expect(await ocr.sizes.isEmpty)
        #expect(!fx.adb.contains { $0.contains("screencap") })
        await fx.cleanup()
    }
}

private func expectNotFound(_ f: @autoclosure () async throws -> JSONValue) async {
    do { _ = try await f(); Issue.record("expected notFound") } catch let e as ProtocolError { #expect(e.code == .notFound, "\(e)") } catch { Issue.record("\(error)") }
}

private func expectInvalid(_ f: @autoclosure () async throws -> JSONValue) async {
    do { _ = try await f(); Issue.record("expected invalidArgs") } catch let e as ProtocolError { #expect(e.code == .invalidArgs) } catch { Issue.record("\(error)") }
}

/// Records the size of each PNG it gets; returns `items` or fails.
private actor FakeOCR: OCRProvider {
    let items: [OCRItem], fail: Bool
    var sizes: [CGSize] = []
    init(_ items: [OCRItem], fail: Bool = false) { self.items = items; self.fail = fail }
    func recognize(png: Data, level: OCRLevel, languages: [String]) async throws -> [OCRItem] {
        sizes.append(AdbParsing.pngSize(png).map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
        if fail { throw ProtocolError(code: .internal, message: "vision failed") }
        return items
    }
}

/// A 1080×2400 screen: black, or black with a white stripe (not uniform).
private func png(_ w: Int, _ h: Int, stripe: Bool) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if stripe { ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 3, width: w, height: h / 3)) }
    let out = NSMutableData()
    let dst = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dst, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dst))
    return out as Data
}
private var textPNG: Data { (try? png(1080, 2400, stripe: true)) ?? Data() }

private func node(_ text: String, _ cls: String, _ b: String, clickable: Bool = false) -> String {
    #"<node index="0" text="\#(text)" resource-id="" class="android.widget.\#(cls)" content-desc="" clickable="\#(clickable)" bounds="\#(b)" />"#
}
private func dump(_ nodes: [String]) -> String {
    #"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">"#
        + nodes.joined() + "</node></hierarchy>"
}
/// A game screen: one label, a SurfaceView.
private let poorTree = dump([node("Jogo", "TextView", "[0,1200][300,1300]"), node("", "SurfaceView", "[0,0][1080,2400]")])
private let goodTree = dump((0..<4).map { node("Item \($0)", "Button", "[0,\(400 + $0 * 500)][1080,\(800 + $0 * 500)]", clickable: true) })

private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }

/// A `DeviceService` on an adb script of its own (uiautomator, no helper): `uiautomator dump /dev/tty` prints `tree`,
/// `screencap -p` prints `png`.
private struct OCRSvc {
    let dir = URL(fileURLWithPath: "/tmp/collie-h6b-\(UUID().uuidString.prefix(8))")
    let svc: DeviceService
    let panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string("R58M")])
    init(tree: String, png: Data, ocr: (any OCRProvider)?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = dir.appendingPathComponent("adb"), log = dir.appendingPathComponent("adb.log").path
        let ui = dir.appendingPathComponent("ui.xml"), shot = dir.appendingPathComponent("in.png")
        try tree.write(to: ui, atomically: true, encoding: .utf8)
        try png.write(to: shot)
        try """
        #!/bin/sh
        echo "$*" >> '\(log)'
        case "$*" in
          "devices -l") printf 'List of devices attached\\nR58M device product:x\\n' ;;
          *"uiautomator dump /dev/tty") cat '\(ui.path)'; echo 'UI hierchary dumped to: /dev/tty' ;;
          *"exec-out screencap -p") cat '\(shot.path)' ;;
        esac
        exit 0
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { adb }, ocr: ocr) { _, _, _ in }
    }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await svc.run(c, panel: panel, args: a, cwd: nil)
    }
    var adb: [String] { ((try? String(contentsOf: dir.appendingPathComponent("adb.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}

// A3: the OCR on iOS. The tree and taps are points, the simulator's screenshot pixels (scale 3 here: 390×844 points,
// 1170×2532 pixels); the boxes come back in points.
extension DeviceOCRTests {
    @Test func iosPoorTreeReadsTheScreenshotAndConvertsPixelsToPoints() async throws {
        // pixels (300,1500)-(900,1620) → points (100,500)-(300,540), centre (200,520)
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 300, y: 1500, width: 600, height: 120))])
        let fx = try IOSOCRSvc(tree: iosPoorTree, ocr: ocr)
        let s = obj(try await fx.run("device.screen", ["timing": .bool(true)]))
        guard case .array(let lists)? = s["lists"], case .string(let text)? = s["text"] else { Issue.record("\(s)"); await fx.cleanup(); return }
        #expect(text.contains("\"Iniciar partida\" (ocr)") && !text.contains("ocr: un"), "\(text)")
        let t = obj(s["timingMs"])
        #expect(t["trigger"] == .string("labels") && t["ocrLevel"] == .string("accurate") && t["ocrMs"] != nil, "\(t)")
        #expect(await ocr.sizes == [CGSize(width: 1170, height: 2532)])
        guard let shot = fx.xcrun.first(where: { $0.hasPrefix("simctl io \(fx.udid) screenshot ") }) else { Issue.record("\(fx.xcrun)"); await fx.cleanup(); return }
        #expect(!FileManager.default.fileExists(atPath: String(shot.split(separator: " ").last ?? "")))   // the temporary file is gone
        guard let item = lists.map(obj).first(where: { $0["source"] == .string("ocr") }), case .string(let ref)? = item["ref"] else {
            Issue.record("\(lists)"); await fx.cleanup(); return
        }
        _ = try await fx.run("device.tap", ["ref": .string(ref)])
        #expect(fx.axe.contains("tap -x 200 -y 520 --udid \(fx.udid)"), "\(fx.axe)")
        await fx.cleanup()
    }

    @Test func iosGoodTreeTakesNoScreenshot() async throws {
        let ocr = FakeOCR([OCRItem(text: "Extra", confidence: 0.9, box: CGRect(x: 0, y: 0, width: 150, height: 60))])
        let fx = try IOSOCRSvc(tree: iosGoodTree, ocr: ocr)
        let s = obj(try await fx.run("device.screen", ["timing": .bool(true)]))
        #expect(obj(s["timingMs"])["trigger"] == nil && s["ocr"] == nil, "\(s)")
        #expect(await ocr.sizes.isEmpty && !fx.xcrun.contains { $0.contains("screenshot") }, "\(fx.xcrun)")
        await fx.cleanup()
    }

    @Test func iosRegionIsPointsAndTheCropIsPixels() async throws {
        // region (100,810)-(300,840) pt, below the buttons → crop (300,2430) 600×90 px; box (30,30,150,60) in it → (110,820,50,20) pt
        let ocr = FakeOCR([OCRItem(text: "Recorte", confidence: 0.9, box: CGRect(x: 30, y: 30, width: 150, height: 60))])
        let fx = try IOSOCRSvc(tree: iosGoodTree, ocr: ocr)
        let s = obj(try await fx.run("device.screen", ["region": .string("100,810,300,840"), "timing": .bool(true)]))
        #expect(obj(s["timingMs"])["trigger"] == .string("flag"), "\(s)")
        #expect(await ocr.sizes == [CGSize(width: 600, height: 90)])
        guard case .array(let lists)? = s["lists"], let item = lists.map(obj).first(where: { $0["source"] == .string("ocr") }),
              case .string(let ref)? = item["ref"] else { Issue.record("\(s)"); await fx.cleanup(); return }
        _ = try await fx.run("device.tap", ["ref": .string(ref)])
        #expect(fx.axe.contains("tap -x 135 -y 830 --udid \(fx.udid)"), "\(fx.axe)")
        await fx.cleanup()
    }

    @Test func iosFindAndTapTextFallBackToTheOCRInPoints() async throws {
        let ocr = FakeOCR([OCRItem(text: "Iniciar partida", confidence: 0.9, box: CGRect(x: 300, y: 1500, width: 600, height: 120))])
        let fx = try IOSOCRSvc(tree: iosPoorTree, ocr: ocr)
        let o = obj(try await fx.run("device.find", ["text": .string("iniciar"), "timing": .bool(true)]))
        #expect(o["found"] == .bool(true) && o["via"] == .string("ocr") && o["warning"] != nil, "\(o)")
        #expect(obj(o["center"]) == ["x": .number(200), "y": .number(520)], "\(o)")
        #expect(obj(o["timingMs"])["trigger"] == .string("find") && obj(o["timingMs"])["ocrMs"] != nil, "\(o)")
        let t = obj(try await fx.run("device.tap", ["text": .string("Iniciar partida")]))
        guard case .string(let w)? = t["warning"] else { Issue.record("\(t)"); await fx.cleanup(); return }
        #expect(t["via"] == .string("ocr") && w.contains("no click confirmation"), "\(t)")
        #expect(fx.axe.contains("tap -x 200 -y 520 --udid \(fx.udid)"), "\(fx.axe)")
        await fx.cleanup()
    }

    @Test func iosNoProviderOrAnErrorLeavesTheTree() async throws {
        for ocr in [nil, FakeOCR([], fail: true)] as [FakeOCR?] {
            let fx = try IOSOCRSvc(tree: iosPoorTree, ocr: ocr)
            let s = obj(try await fx.run("device.screen"))
            guard case .string(let text)? = s["text"] else { Issue.record("\(s)"); await fx.cleanup(); return }
            #expect(text.hasSuffix("\nocr: unavailable") && s["ocr"] == .string("unavailable") && text.contains("Jogo"), "\(text)")
            await expectNotFound(try await fx.run("device.find", ["text": .string("iniciar")]))
            await fx.cleanup()
        }
    }
}

private func axNode(_ type: String, _ label: String, _ f: (Int, Int, Int, Int)) -> String {
    #"{"type":"\#(type)","AXLabel":"\#(label)","enabled":true,"frame":{"x":\#(f.0),"y":\#(f.1),"width":\#(f.2),"height":\#(f.3)},"children":[]}"#
}
private func axTree(_ children: [String]) -> String {
    #"[{"type":"Application","frame":{"x":0,"y":0,"width":390,"height":844},"children":["# + children.joined(separator: ",") + "]}]"
}
/// One label: the content is poor (O2 rule 1).
private let iosPoorTree = axTree([axNode("StaticText", "Jogo", (0, 400, 100, 30))])
private let iosGoodTree = axTree((0..<4).map { axNode("Button", "Item \($0)", (0, 100 + $0 * 180, 390, 160)) })

/// A `DeviceService` on an iOS panel with its own xcrun (a booted simulator, `io screenshot` copies a 1170×2532 PNG)
/// and AXe (`describe-ui` prints `tree`) scripts.
private struct IOSOCRSvc {
    let dir = URL(fileURLWithPath: "/tmp/collie-a3-\(UUID().uuidString.prefix(8))")
    let udid = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163"
    let svc: DeviceService
    let panel: Panel
    init(tree: String, ocr: (any OCRProvider)?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string(udid), "platform": .string("ios")])
        let xcrun = dir.appendingPathComponent("xcrun"), axe = dir.appendingPathComponent("axe")
        let ui = dir.appendingPathComponent("ui.json"), shot = dir.appendingPathComponent("in.png"), sims = dir.appendingPathComponent("sims.json")
        try tree.write(to: ui, atomically: true, encoding: .utf8)
        try png(1170, 2532, stripe: true).write(to: shot)
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
        [ "$1" = describe-ui ] && cat '\(ui.path)'
        exit 0
        """.write(to: axe, atomically: true, encoding: .utf8)
        for f in [xcrun, axe] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { nil }, xcrun: xcrun, axe: { axe }, ocr: ocr) { _, _, _ in }
    }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await svc.run(c, panel: panel, args: a, cwd: nil)
    }
    private func lines(_ f: String) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    var xcrun: [String] { lines("xcrun.log") }
    var axe: [String] { lines("axe.log") }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}
