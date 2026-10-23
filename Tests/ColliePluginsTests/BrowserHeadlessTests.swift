import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// A headless browser panel: the store hosts its view in a never-ordered `BrowserInput.HostWindow` (Review Focus 1:
/// rAF and timers keep running, screenshots aren't blank). Local HTML only.
@MainActor @Suite(.serialized) struct BrowserHeadlessTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-\(UUID().uuidString)")

    func obj(_ v: JSONValue) -> [String: JSONValue] { if case .object(let o) = v { return o }; return [:] }

    @Test func headlessPageKeepsRunningAndRendering() async throws {
        _ = NSApplication.shared
        PluginViews.register("browser", BrowserPanel.self)
        let panel = Panel(id: UUID(), name: "qa", pluginId: "browser", placement: .headless, state: [:])
        var panels = [panel]
        let store = PanelViewStore(panels: { panels }) { PanelHostContext(panel: $0, root: root, workspaceId: nil, call: { _, _ in .null }, emit: { _, _ in }) }
        defer { store.closeAll(); try? FileManager.default.removeItem(at: root) }
        let b = try #require(store.instance(for: panel.id) as? BrowserPanel)
        let window = try #require(b.webView?.window)
        func onScreen() -> Bool { NSWindow.windowNumbers(options: [])?.contains(NSNumber(value: window.windowNumber)) == true }
        #expect(window is BrowserInput.HostWindow && !onScreen())   // never ordered in
        _ = try await b.handle("browser.resize", ["width": .number(360), "height": .number(640)])
        try await b.load(html: """
            <body style='margin:0;background:#00f'><div id=box style='width:100px;height:100px;background:#00f'></div>
            <script>
              window.frames_ = 0; window.ticks = 0
              requestAnimationFrame(function f() { frames_++; if (frames_ == 5) box.style.background = '#f00'; requestAnimationFrame(f) })
              setInterval(() => ticks++, 20)
            </script>
            """)
        func value(_ js: String) async throws -> Double {
            if case .number(let n)? = obj(try await b.handle("browser.eval", ["js": .string(js)]))["value"] { return n }
            return -1
        }
        let f0 = try await value("frames_")
        try await Task.sleep(for: .seconds(1))
        let f1 = try await value("frames_"), ticks = try await value("ticks")
        // throttled (no window, or a window WebKit takes as hidden): 0 frames and ~7 ticks; healthy: ~60 and ~50.
        // Loose bounds for a loaded machine.
        #expect(f1 - f0 > 5, "rAF advanced \(f1 - f0) frames in 1 s")
        #expect(ticks > 15, "setInterval ran \(ticks) times in ~1 s")
        #expect(try await value("innerWidth") == 360)
        // the screenshot shows the page (the rAF-painted box), not a blank frame
        let shot = obj(try await b.handle("browser.screenshot", [:]))
        guard case .string(let path)? = shot["path"], let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { Issue.record("no screenshot: \(shot)"); return }
        let s = img.width / 360
        #expect(pixel(img, 50 * s, 50 * s) == [255, 0, 0] && pixel(img, 200 * s, 300 * s) == [0, 0, 255])
        // in a window: trusted input
        #expect(obj(try await b.handle("browser.key", ["key": .string("Tab")]))["trusted"] == .bool(true))
        // closed: the view and its host window go
        panels = []; store.sync([])
        #expect(b.webView == nil && b.view.window == nil && !onScreen())
    }

    @Test func dockedPanelGetsNoHostWindow() {
        PluginViews.register("browser", BrowserPanel.self)
        let panel = Panel(id: UUID(), name: "d", pluginId: "browser", placement: .dockRight, state: [:])
        let store = PanelViewStore(panels: { [panel] }) { PanelHostContext(panel: $0, root: root, workspaceId: nil, call: { _, _ in .null }, emit: { _, _ in }) }
        defer { store.closeAll() }
        #expect(store.instance(for: panel.id)?.view.window == nil)
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return px[0..<3].map(Int.init)
    }
}
