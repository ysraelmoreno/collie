import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// The page viewport is independent of the slot: bounds = viewport, frame = fitted rect (local HTML only).
@MainActor @Suite(.serialized) struct BrowserViewportTests {
    func browser(slot: CGSize = CGSize(width: 600, height: 400)) async throws -> (BrowserPanel, NSView) {
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight, state: [:])
        let b = BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory,
                                                                  workspaceId: nil, call: { _, _ in .null }) { _, _ in })
        try await b.load(html: "<p>x</p>")
        let slotView = NSView(frame: CGRect(origin: .zero, size: slot))
        b.container.frame = slotView.bounds
        slotView.addSubview(b.container)
        slotView.layoutSubtreeIfNeeded()
        return (b, slotView)
    }

    func resize(_ b: BrowserPanel, _ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard case .object(let o) = try await b.handle("browser.resize", args) else { return [:] }
        return o
    }

    @Test func viewportKeepsNodeSize() async throws {
        let (b, slot) = try await browser(); defer { b.close() }
        let r = try await resize(b, ["width": .number(360), "height": .number(800)])
        #expect(r["scale"] == .number(0.5))
        #expect(b.webView?.frame.size == CGSize(width: 360, height: 800))
        #expect(slot.frame.size == CGSize(width: 600, height: 400))
        #expect(b.container.frame.size == CGSize(width: 600, height: 400))
        #expect(b.container.scale == 0.5)
        #expect(b.container.page.frame == CGRect(x: 210, y: 0, width: 180, height: 400))
    }

    @Test func viewportWiderThanSlotScalesDown() async throws {
        let (b, _) = try await browser(); defer { b.close() }
        let r = try await resize(b, ["width": .number(1200), "height": .number(400)])
        #expect(r["scale"] == .number(0.5))
        #expect(b.container.page.frame.size == CGSize(width: 600, height: 200))
        let small = try await resize(b, ["width": .number(300), "height": .number(200)])
        #expect(small["scale"] == .number(1))   // never scaled up
    }

    @Test func resetFillsSlot() async throws {
        let (b, _) = try await browser(); defer { b.close() }
        _ = try await resize(b, ["width": .number(360), "height": .number(800)])
        let r = try await resize(b, ["reset": .bool(true)])
        #expect(r["scale"] == .number(1))
        #expect(b.webView?.frame.size == CGSize(width: 600, height: 400))
    }

    @Test func innerWidthIsViewport() async throws {
        let (b, _) = try await browser(); defer { b.close() }
        _ = try await resize(b, ["width": .number(360)])
        var width: JSONValue?
        for _ in 0..<100 {
            if case .object(let o) = try await b.handle("browser.eval", ["js": .string("window.innerWidth")]) { width = o["value"] }
            if width == .number(360) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(width == .number(360))
    }

    @Test func widthBounds() async throws {
        let (b, _) = try await browser(); defer { b.close() }
        _ = try await resize(b, ["width": .number(200)])
        for w in [199.0, 4097.0] {
            do { _ = try await resize(b, ["width": .number(w)]); Issue.record("expected invalidArgs for \(w)") }
            catch let e as ProtocolError { #expect(e.code == .invalidArgs) }
        }
    }
}
