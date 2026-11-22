import AppKit
import SwiftUI
import Testing
import CollieCanvas
import CollieClient
import CollieCore
@testable import CollieApp

/// M10.5: the ⤢ in a terminal's title bar on the canvas. Cause found by these tests (not the mouseUp re-add): the
/// terminal node scales its bounds by the zoom, and SwiftUI reads a click inside the title host as the unscaled window
/// offset from the host's top-left, so at any zoom ≠ 1 every SwiftUI control of the bar missed. Panels (frame only)
/// and fullscreen (scale 1) were never scaled. The re-add on mouseUp is harmless: the button fires inside `super.mouseUp`.
@MainActor @Suite(.serialized) struct TerminalFullscreenClickTests {
    static let size = CGSize(width: 640, height: 400)   // canvas pt
    /// The ⤢ in canvas pt, found by clicking along the title bar of a zoom-1 rig (node bounds = canvas pt there) from the
    /// "…" menu's left edge leftwards until fullscreen toggles. Not a constant: SwiftUI lays the bar out differently by
    /// macOS (`size.width - 46`, scanned on 15, missed on the macOS 26 runner even at zoom 1). SwiftUI's accessibility
    /// tree is empty with no AX client, so it can't be read from there. Never clicks the menu (that pops a modal menu).
    static var button: CGPoint {
        if let p = located { return p }
        let r = makeRig(zoom: 1, inFront: false); defer { r.close() }
        let menu = popUp(in: r.node).map { r.node.convert($0.bounds, from: $0).minX } ?? size.width - 30
        let y = TerminalNodeView.titleHeight / 2
        for x in stride(from: menu - 1, to: size.width / 2, by: -2) {
            r.click(CGPoint(x: x, y: y))
            if r.canvas.fullscreen != nil { located = CGPoint(x: x, y: y); break }
        }
        return located ?? .zero
    }
    private static var located: CGPoint?
    private static func popUp(in v: NSView) -> NSPopUpButton? {
        v as? NSPopUpButton ?? v.subviews.lazy.compactMap { popUp(in: $0) }.first
    }

    @MainActor final class Parent: NSView {
        var adds = 0
        override func didAddSubview(_ v: NSView) { super.didAddSubview(v); adds += 1 }
    }

    /// Events go to the view under the press and stay with it until the up, as a key window delivers them (the test
    /// window is never key: a SwiftUI host would then gate the first click on the same broken hit math).
    @MainActor final class Rig {
        let canvas: CanvasState, window: NSWindow, parent: Parent, node: TerminalNodeView, other: TerminalNodeView
        private var target: NSView?
        init(canvas: CanvasState, window: NSWindow, parent: Parent, node: TerminalNodeView, other: TerminalNodeView) {
            self.canvas = canvas; self.window = window; self.parent = parent; self.node = node; self.other = other
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let at = node.convert(NSPoint(x: p.x, y: p.y), to: nil)
            let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { target = window.contentView?.hitTest(at) }
            switch type {
            case .leftMouseDown: target?.mouseDown(with: e)
            case .leftMouseDragged: target?.mouseDragged(with: e)
            default: target?.mouseUp(with: e); target = nil
            }
        }
        func click(_ p: CGPoint = TerminalFullscreenClickTests.button) { send(.leftMouseDown, p); send(.leftMouseUp, p) }
        var nodes: [NSView] { parent.subviews.filter { $0 is TerminalNodeView } }
        func close() { node.unmount(); other.unmount(); window.close() }
    }

    private func rig(zoom: CGFloat, inFront: Bool) -> Rig {
        #expect(Self.button != .zero, "⤢ not found in the title bar")
        return Self.makeRig(zoom: zoom, inFront: inFront)
    }

    /// `node` at the zoom, and another node placed away from the click; `inFront` puts that one on top.
    private static func makeRig(zoom: CGFloat, inFront: Bool) -> Rig {
        let canvas = CanvasState(); canvas.zoom = zoom
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-fsc-\(UUID())")))
        func make() -> TerminalNodeView {
            let id = UUID()
            return TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
        }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let parent = Parent(frame: w.contentView!.bounds)
        w.contentView!.addSubview(parent)
        let node = make(), other = make()
        let s = Self.size, screen = CGSize(width: s.width * zoom, height: s.height * zoom)
        node.place(CGRect(origin: CGPoint(x: 20, y: 20), size: screen), canvasSize: s)
        other.place(CGRect(origin: CGPoint(x: 40 + screen.width, y: 40 + screen.height), size: screen), canvasSize: s)
        for v in inFront ? [node, other] : [other, node] { parent.addSubview(v) }
        parent.addSubview(Minimap(canvas: canvas))
        for v in [node, other] { v.setInteractive(true); v.layoutSubtreeIfNeeded() }
        w.makeKeyAndOrderFront(nil)
        return Rig(canvas: canvas, window: w, parent: parent, node: node, other: other)
    }

    /// Lets anything the click queued on the main queue run (no sleep, no clock).
    private func settle() async {
        for _ in 0..<5 { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } } }
    }

    /// The reported bug: another node in front, canvas zoomed. Fails before the fix (the click never reaches the button).
    @Test(arguments: [0.7, 1.0, 1.5]) func clickWithANodeInFrontFires(zoom: Double) async {
        let r = rig(zoom: zoom, inFront: true); defer { r.close() }
        r.click()
        await settle()
        #expect(r.canvas.fullscreen == r.node.id)
        #expect(r.nodes.last === r.node)   // and it came to the front
    }

    @Test(arguments: [0.5, 0.7, 1.0, 2.0]) func clickWithoutANodeInFrontStillFires(zoom: Double) async {
        let r = rig(zoom: zoom, inFront: false); defer { r.close() }
        r.click()
        await settle()
        #expect(r.canvas.fullscreen == r.node.id)
    }

    /// A drag that starts on the ⤢ moves the node: no fullscreen, and the view is never re-added mid-drag
    /// (that would cancel the mouse tracking); it comes to the front only on mouseUp.
    @Test func dragAcrossTheBarNeitherFiresNorReaddsMidDrag() async {
        let r = rig(zoom: 0.7, inFront: true); defer { r.close() }
        let adds = r.parent.adds
        var p = Self.button
        r.send(.leftMouseDown, p)
        for _ in 0..<10 { p.x -= 12; r.send(.leftMouseDragged, p) }
        #expect(r.parent.adds == adds)
        r.send(.leftMouseUp, p)
        await settle()
        #expect(r.canvas.fullscreen == nil)
        #expect(r.nodes.last === r.node)
    }

    /// Coming to the front re-adds the view, which drops the first responder: focus goes back to its terminal.
    @Test func clickKeepsTheTerminalFocused() async throws {
        let r = rig(zoom: 0.7, inFront: true); defer { r.close() }
        let t = try #require(r.node.term)
        r.window.makeFirstResponder(t)
        r.click()
        await settle()
        #expect(r.nodes.last === r.node)
        #expect(r.window.firstResponder === t)
    }
}

