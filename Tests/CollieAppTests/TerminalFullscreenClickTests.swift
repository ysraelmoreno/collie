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
    /// The ⤢ in canvas pt: right padding 10, the "…" menu, spacing 8, then the button (found by scanning at zoom 1).
    static let button = CGPoint(x: size.width - 46, y: TerminalNodeView.titleHeight / 2)

    @MainActor final class Parent: NSView {
        var adds = 0
        override func didAddSubview(_ v: NSView) { super.didAddSubview(v); adds += 1 }
    }

    @MainActor struct Rig {
        let canvas: CanvasState, window: NSWindow, parent: Parent, node: TerminalNodeView, other: TerminalNodeView
        func at(_ p: CGPoint) -> NSPoint { node.convert(NSPoint(x: p.x, y: p.y), to: nil) }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: at(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func click(_ p: CGPoint = TerminalFullscreenClickTests.button) { send(.leftMouseDown, p); send(.leftMouseUp, p) }
        var nodes: [NSView] { parent.subviews.filter { $0 is TerminalNodeView } }
        func close() { node.unmount(); other.unmount(); window.close() }
    }

    /// `node` at the zoom, and another node placed away from the click; `inFront` puts that one on top.
    private func rig(zoom: CGFloat, inFront: Bool) -> Rig {
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

@MainActor @Suite struct TerminalFullscreenHitProbe {
    @Test(arguments: [0.5, 0.7, 1.0, 1.5]) func hit(zoom: Double) {
        let canvas = CanvasState(); canvas.zoom = zoom
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-fsh-\(UUID())")))
        let id = UUID()
        let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView!.addSubview(v)
        let s = CGSize(width: 640, height: 400)
        v.place(CGRect(origin: CGPoint(x: 20, y: 20), size: CGSize(width: s.width * zoom, height: s.height * zoom)), canvasSize: s)
        v.setInteractive(true); v.layoutSubtreeIfNeeded()
        var line = ""
        for x in stride(from: 20.0, to: 640, by: 60) {
            let at = v.convert(NSPoint(x: x, y: 16), to: nil)
            line += " \(Int(x)):\(w.contentView!.hitTest(at).map { "\(type(of: $0))".prefix(12) } ?? "nil")"
        }
        print("PROBE5 zoom=\(zoom)\(line)")
        v.unmount(); w.close()
    }
}

@MainActor @Suite struct TerminalFullscreenUpProbe {
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    @Test(arguments: [0.7, 1.0]) func up(zoom: Double) {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let node = Flipped(frame: CGRect(x: 100, y: 100, width: 600 * zoom, height: 300 * zoom))
        node.setBoundsSize(CGSize(width: 600, height: 300))
        var log: [String] = []
        let host = TitleHost(rootView: FullscreenButton(action: { log.append("action") }))
        host.frame = CGRect(x: 200, y: 0, width: 400, height: 32)
        host.onClick = { log.append("down") }
        host.onMouseUp = { log.append("up") }
        node.addSubview(host)
        w.contentView!.addSubview(node)
        w.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let at = host.convert(NSPoint(x: 100, y: 16), to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            w.sendEvent(NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        print("PROBE6 zoom=\(zoom) \(log) hit=\(String(describing: w.contentView!.hitTest(at).map { type(of: $0) }))")
        w.close()
    }
}
