import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// `browser.screenshot` clip / ref / full page and the CLI's `--out` copy (local HTML only).
@MainActor @Suite(.serialized) struct BrowserScreenshotTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")

    func browser(html: String) async throws -> BrowserPanel {
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight, state: [:])
        let b = BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: root, workspaceId: nil, call: { _, _ in .null }) { _, _ in })
        _ = try await b.handle("browser.resize", ["width": .number(400), "height": .number(300)])
        try await b.load(html: html)
        return b
    }

    func shot(_ b: BrowserPanel, _ args: [String: JSONValue] = [:]) async throws -> (w: Int, h: Int, image: CGImage) {
        guard case .object(let o) = try await b.handle("browser.screenshot", args),
              case .string(let path)? = o["path"], case .number(let w)? = o["width"], case .number(let h)? = o["height"],
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ProtocolError(code: .internal, message: "bad screenshot reply") }
        #expect(img.width == Int(w) && img.height == Int(h))
        return (Int(w), Int(h), img)
    }

    /// RGB of the pixel at (x, y) in image pixels.
    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return px[0..<3].map(Int.init)
    }

    func js(_ b: BrowserPanel, _ code: String) async throws -> JSONValue? {
        guard case .object(let o) = try await b.handle("browser.eval", ["js": .string(code)]) else { return nil }
        return o["value"]
    }

    @Test func clipRect() async throws {
        let b = try await browser(html: "<body style='margin:0;background:#00f'>x"); defer { b.close(); try? FileManager.default.removeItem(at: root) }
        let full = try await shot(b)
        let s = full.w / 400
        let c = try await shot(b, ["clip": .string("10,20,100,50")])
        #expect(c.w == 100 * s && c.h == 50 * s)
    }

    @Test func clipOrigin() async throws {
        let b = try await browser(html: "<body style='margin:0;background:#00f'><div style='position:absolute;left:50px;top:60px;width:20px;height:20px;background:#f00'>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        let s = try await shot(b).w / 400
        let c = try await shot(b, ["clip": .string("40,50,20,20")])
        #expect(pixel(c.image, 2, 2) == [0, 0, 255])
        #expect(pixel(c.image, 15 * s, 15 * s) == [255, 0, 0])
    }

    @Test func refCropSettlesUnderSmoothScrollAndRestoresScroll() async throws {
        let b = try await browser(html: "<html style='scroll-behavior:smooth'><body style='margin:0'><div style='height:1500px'></div><button style='display:block;margin:0;border:0;padding:0;width:80px;height:40px;background:#f00'>x</button><div style='height:1500px'></div>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        _ = try await b.handle("browser.snapshot", [:])
        let s = try await shot(b).w / 400
        #expect(try await js(b, "scrollY") == .number(0))
        let c = try await shot(b, ["ref": .string("e1")])
        #expect(c.w == 80 * s && c.h == 40 * s)
        #expect(pixel(c.image, 2, 2) == [255, 0, 0])
        #expect(try await js(b, "scrollY") == .number(0))
    }

    @Test func clipValidation() async throws {
        let b = try await browser(html: "<p>x"); defer { b.close(); try? FileManager.default.removeItem(at: root) }
        for bad in ["1,2,3", "a,b,c,d", "0,0,0,10", "500,0,10,10"] {
            do { _ = try await b.handle("browser.screenshot", ["clip": .string(bad)]); Issue.record("expected invalidArgs for \(bad)") }
            catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains("--clip")) }
        }
        do { _ = try await b.handle("browser.screenshot", ["clip": .string("0,0,5,5"), "ref": .string("e1")]); Issue.record("both") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs) }
        do { _ = try await b.handle("browser.screenshot", ["full-page": .bool(true), "clip": .string("0,0,5,5")]); Issue.record("both") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs) }
    }

    @Test func clipByRef() async throws {
        let b = try await browser(html: "<body style='margin:0'><div style='height:40px'></div><button id=t style='display:block;margin:0;border:0;padding:0;width:120px;height:60px;background:#f00'>go</button>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        _ = try await b.handle("browser.snapshot", [:])
        let s = try await shot(b).w / 400
        let c = try await shot(b, ["ref": .string("e1")])
        #expect(c.w == 120 * s && c.h == 60 * s)
        #expect(pixel(c.image, c.w / 2, c.h - 1) == [255, 0, 0])
    }

    @Test func fullPageHeight() async throws {
        let b = try await browser(html: "<body style='margin:0'><div style='height:2000px;background:linear-gradient(#f00,#00f)'></div>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        let s = try await shot(b).w / 400
        _ = try await b.handle("browser.scroll", ["dy": .number(123)])
        let f = try await shot(b, ["full-page": .bool(true)])
        #expect(f.w == 400 * s && f.h == 2000 * s)
        // top is red, bottom is blue (last, partial tile included)
        #expect(pixel(f.image, 10, 2)[0] > 240)
        #expect(pixel(f.image, 10, f.h - 3)[2] > 240)
        #expect(try await js(b, "scrollY") == .number(123))   // restored
    }

    @Test func fullPageKeepsVh() async throws {
        let b = try await browser(html: "<body style='margin:0'><div style='height:100vh;background:#0f0'></div><div style='height:1000px;background:#00f'></div>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        let s = try await shot(b).w / 400
        let f = try await shot(b, ["full-page": .bool(true)])
        #expect(f.h == 1300 * s)
        #expect(pixel(f.image, 10, 300 * s - 3) == [0, 255, 0])      // hero ends at 300 (the viewport), not stretched
        #expect(pixel(f.image, 10, 300 * s + 3) == [0, 0, 255])
    }

    @Test func fullPageCap() async throws {
        let b = try await browser(html: "<body style='margin:0'><div style='height:17000px'></div>")
        defer { b.close(); try? FileManager.default.removeItem(at: root) }
        do { _ = try await b.handle("browser.screenshot", ["full-page": .bool(true)]); Issue.record("expected cap error") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains("16384")) }
    }

    func outDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func reply(_ dir: URL, name: String = "src.png") throws -> JSONValue {
        let src = dir.appendingPathComponent("daemon/\(name)")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: src)
        return .object(["path": .string(src.path)])
    }

    @Test func outDirectoryReceivesFileAndSurvives() throws {
        let dir = try outDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try reply(dir)
        let keep = dir.appendingPathComponent("keep.txt"); try Data("k".utf8).write(to: keep)
        let sub = dir.appendingPathComponent("existing"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("s".utf8).write(to: sub.appendingPathComponent("sentinel"))
        for dest in [".", "existing", "existing/"] {
            _ = try OutFile.copyPath(of: r, to: dest, cwd: dir.path)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src.png").path))
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("src.png").path))
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("sentinel").path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("daemon/src.png").path))
    }

    @Test func outRefusesDirectoryTarget() throws {
        let dir = try outDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try reply(dir)
        let clash = dir.appendingPathComponent("existing/src.png")   // a directory named like the file
        try FileManager.default.createDirectory(at: clash, withIntermediateDirectories: true)
        try Data("s".utf8).write(to: clash.appendingPathComponent("sentinel"))
        do { _ = try OutFile.copyPath(of: r, to: "existing", cwd: dir.path); Issue.record("expected error") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("--out")) }
        #expect(FileManager.default.fileExists(atPath: clash.appendingPathComponent("sentinel").path))
    }

    @Test func outCopiesRelativeToCwd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("src.png"); try Data("one".utf8).write(to: src)
        let reply: JSONValue = .object(["path": .string(src.path), "width": .number(1)])
        let r = try OutFile.copyPath(of: reply, to: "sub/dir/a.png", cwd: dir.path)
        guard case .object(let o) = r, case .string(let p)? = o["path"] else { Issue.record("no path"); return }
        #expect(URL(fileURLWithPath: p).resolvingSymlinksInPath().path == dir.appendingPathComponent("sub/dir/a.png").resolvingSymlinksInPath().path)
        #expect(o["width"] == .number(1))
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "one")
        try Data("two".utf8).write(to: src)
        _ = try OutFile.copyPath(of: reply, to: "sub/dir/a.png", cwd: dir.path)   // overwrites
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "two")
        #expect(FileManager.default.fileExists(atPath: src.path))   // the daemon's file stays
    }
}
