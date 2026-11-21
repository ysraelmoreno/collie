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
