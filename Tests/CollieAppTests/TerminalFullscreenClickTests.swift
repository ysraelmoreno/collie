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
    @Test(arguments: [false, true]) func probe(behind: Bool) async throws {
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
        v.place(CGRect(origin: CGPoint(x: 20, y: 20), size: size), canvasSize: size)
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
            print("PROBE2 behind=\(behind) x=\(x) hit=\(String(describing: w.contentView!.hitTest(at))) fs=\(canvas.fullscreen != nil)")
            if canvas.fullscreen != nil { hitX = x; break }
        }
        print("PROBE2 behind=\(behind) hitX=\(String(describing: hitX))")
        v.unmount(); w.close()
    }
}
