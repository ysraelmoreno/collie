import AppKit
import SwiftUI
import Testing
@testable import CollieApp

/// Probe: when does the ⤢ action fire for a synthetic click, with and without the re-add on mouseUp.
@MainActor @Suite struct TerminalFullscreenClickTests {
    final class Box { var fired = 0; var hop = -1 }

    private func rig(_ box: Box) -> (NSWindow, NSView, TitleHost<FullscreenButton>, NSView) {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let parent = NSView(frame: w.contentView!.bounds)
        w.contentView!.addSubview(parent)
        let node = NSView(frame: CGRect(x: 10, y: 10, width: 200, height: 100))
        let host = TitleHost(rootView: FullscreenButton(action: { box.fired += 1 }))
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 32)
        node.addSubview(host)
        parent.addSubview(node)
        let other = NSView(frame: CGRect(x: 250, y: 150, width: 100, height: 100))   // a sibling in front, not under the click
        parent.addSubview(other)
        w.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (w, parent, host, other)
    }

    private func send(_ w: NSWindow, _ host: NSView, _ type: NSEvent.EventType) {
        let at = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        w.sendEvent(e)
    }

    private func hops(_ box: Box, _ n: Int) async {
        for i in 0..<n {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
            if box.fired > 0, box.hop < 0 { box.hop = i }
        }
    }

    @Test(arguments: [false, true]) func probe(readd: Bool) async {
        let box = Box()
        let (w, parent, host, other) = rig(box)
        let node = host.superview!
        if readd { host.onMouseUp = { parent.addSubview(node, positioned: .above, relativeTo: other) } }
        send(w, host, .leftMouseDown)
        send(w, host, .leftMouseUp)
        let sync = box.fired
        await hops(box, 20)
        print("PROBE readd=\(readd) sync=\(sync) fired=\(box.fired) hop=\(box.hop)")
        w.close()
    }
}

import CollieCanvas
import CollieClient
import CollieCore

/// Probe 2: the real terminal node, its real title bar, with and without another node in front.
@MainActor @Suite struct TerminalFullscreenRealProbe {
    @Test(arguments: [(false, 1.0), (false, 0.7), (false, 1.5)]) func probe(behind: Bool, zoom: Double) async throws {
        let canvas = CanvasState()
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-fsc-\(UUID())")))
        let id = UUID()
        let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let parent = NSView(frame: w.contentView!.bounds)
        w.contentView!.addSubview(parent)
        parent.addSubview(v)
        let size = CGSize(width: 640, height: 400)
        canvas.zoom = zoom
        v.place(CGRect(origin: CGPoint(x: 20, y: 20), size: CGSize(width: size.width * zoom, height: size.height * zoom)), canvasSize: size)
        v.setInteractive(true)
        let other = NSView(frame: CGRect(x: 900, y: 600, width: 100, height: 100))
        if behind { parent.addSubview(other) }
        let mini = Minimap(canvas: canvas); parent.addSubview(mini)
        w.makeKeyAndOrderFront(nil)
        v.layoutSubtreeIfNeeded()
        var hitX: CGFloat?
        for x in stride(from: size.width - 64, to: size.width - 10, by: 2) {
            canvas.fullscreen = nil
            if behind, parent.subviews.firstIndex(of: v)! > parent.subviews.firstIndex(of: other)! {
                parent.addSubview(other, positioned: .below, relativeTo: mini)
            }
            let at = v.convert(NSPoint(x: x, y: 16), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                w.sendEvent(NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            for _ in 0..<5 { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } } }
            print("PROBE2 zoom=\(zoom) x=\(x) hit=\(String(describing: w.contentView!.hitTest(at))) fs=\(canvas.fullscreen != nil)")
            if canvas.fullscreen != nil { hitX = x; break }
        }
        print("PROBE2 zoom=\(zoom) hitX=\(String(describing: hitX))")
        v.unmount(); w.close()
    }
}

/// Probe 3: where a scaled ancestor makes SwiftUI think the click landed.
@MainActor @Suite struct TerminalFullscreenMapProbe {
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    @Test(arguments: [1.0, 0.5, 2.0]) func map(zoom: Double) async {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let node = Flipped(frame: CGRect(x: 100, y: 100, width: 600 * zoom, height: 300 * zoom))
        node.setBoundsSize(CGSize(width: 600, height: 300))
        var fired = 0
        let host = TitleHost(rootView: FullscreenButton(action: { fired += 1 }))
        host.frame = CGRect(x: 200, y: 0, width: 40, height: 32)
        node.addSubview(host)
        w.contentView!.addSubview(node)
        w.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        var hits: [String] = []
        for wx in stride(from: 0.0, to: 1200, by: 4) {
            for wy in stride(from: 300.0, to: 800, by: 4) {
                fired = 0
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    w.sendEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: wx, y: wy), modifierFlags: [], timestamp: 0,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                if fired > 0 { hits.append("\(Int(wx)),\(Int(wy))") }
            }
        }
        let hf = host.convert(host.bounds, to: nil)
        print("PROBE3 zoom=\(zoom) hostInWindow=\(hf) hits=\(hits.count) first=\(hits.first ?? "-") last=\(hits.last ?? "-")")
        w.close()
    }
}

/// Probe 4: the same map with an AppKit-backed (borderless) button. NSButton tracks the press itself (it pulls the
/// mouseUp from the queue), so the up is posted first and the down sent.
@MainActor @Suite(.serialized) struct TerminalFullscreenBorderlessProbe {
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    struct B: View {
        let action: () -> Void
        var body: some View { Button(action: action) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless) }
    }
    private func tree(_ v: NSView, _ d: Int = 0) -> String { String(repeating: " ", count: d) + "\(type(of: v)) \(v.frame)\n" + v.subviews.map { tree($0, d + 1) }.joined() }
    @Test(arguments: [0.5]) func map(zoom: Double) async {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let node = Flipped(frame: CGRect(x: 100, y: 100, width: 600 * zoom, height: 300 * zoom))
        node.setBoundsSize(CGSize(width: 600, height: 300))
        var fired = 0
        let host = TitleHost(rootView: B(action: { fired += 1 }))
        host.frame = CGRect(x: 200, y: 0, width: 40, height: 32)
        node.addSubview(host)
        w.contentView!.addSubview(node)
        w.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        print("PROBE4 tree\n" + tree(host))
        let hf = host.convert(host.bounds, to: nil)
        var hits: [String] = []
        for wx in stride(from: hf.minX - 8, to: hf.maxX + 8, by: 2) {
            for wy in stride(from: hf.minY - 8, to: hf.maxY + 8, by: 2) {
                fired = 0
                let ev = { (t: NSEvent.EventType) in NSEvent.mouseEvent(with: t, location: NSPoint(x: wx, y: wy), modifierFlags: [], timestamp: 0,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
                NSApplication.shared.postEvent(ev(.leftMouseUp), atStart: false)
                w.sendEvent(ev(.leftMouseDown))
                if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { w.sendEvent(up) }
                if fired > 0 { hits.append("\(Int(wx)),\(Int(wy))") }
                print("PROBE4 at \(wx),\(wy) fired=\(fired)"); fflush(stdout)
            }
        }
        print("PROBE4 zoom=\(zoom) hostInWindow=\(hf) hits=\(hits.count) first=\(hits.first ?? "-") last=\(hits.last ?? "-")")
        w.close()
    }
}
