import AppKit
import Testing
import SwiftTerm
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme
@testable import CollieApp

@MainActor private final class SizeSink: TerminalViewDelegate {
    var sizes: [(Int, Int)] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizes.append((newCols, newRows)) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A node mounted in an offscreen window (never ordered front, so SwiftTerm's frame driver never ticks).
@MainActor private func makeNode(_ canvas: CanvasState = CanvasState(), size: CGSize) throws -> (TerminalNodeView, NSWindow, NodeTerminal) {
    let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-grid-\(UUID())")))
    let id = UUID()
    let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
    let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2000, height: 1400), styleMask: [.titled, .resizable],
                     backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView?.addSubview(v)
    v.place(CGRect(origin: .zero, size: size), canvasSize: size)
    v.setInteractive(true)
    v.layoutSubtreeIfNeeded()
    return (v, w, try #require(v.term))
}

/// The grid SwiftTerm itself computes for a node of `size` (its frame path, with the node's font).
@MainActor private func gridFor(_ size: CGSize) -> (Int, Int) {
    let body = CGSize(width: size.width, height: size.height - TerminalNodeView.titleHeight)
    let t = TerminalView(frame: CGRect(origin: .zero, size: body), font: AppearanceSettings(defaults: .standard).terminalFont.font)
    t.setFrameSize(.zero); t.setFrameSize(body)
    return (t.terminalDimensions.cols, t.terminalDimensions.rows)
}

@MainActor private func dims(_ t: TerminalView) -> (Int, Int) { (t.terminalDimensions.cols, t.terminalDimensions.rows) }

// ponytail: AppKit's own live-resize entry points (private). Overriding `inLiveResize` doesn't reach SwiftTerm:
// NSView keeps a per-view flag that only these set and clear.
@MainActor private func liveResize(_ w: NSWindow, _ on: Bool) { w.perform(Selector(on ? "_startLiveResize" : "_endLiveResize")) }

private let small = CGSize(width: 640, height: 400), big = CGSize(width: 1000, height: 700)

/// A node resized during a window live resize: SwiftTerm only queues the size for its next frame tick and
/// has no end-of-resize flush. The grid must follow the frame once the gesture ends, tick or not.
@MainActor @Test func liveResizeSizeIsAppliedWhenTheGestureEnds() throws {
    let (v, w, t) = try makeNode(size: small); defer { v.unmount() }
    liveResize(w, true)
    v.place(CGRect(origin: .zero, size: big), canvasSize: big)
    v.layoutSubtreeIfNeeded()
    #expect(dims(t) == gridFor(small))   // queued, not applied: the reproduction
    liveResize(w, false)
    #expect(dims(t) == gridFor(big))
}

/// A stale grid (frame big, grid small) is repaired through the frame path, with exactly one `sizeChanged`;
/// a second reconcile changes nothing.
@MainActor @Test func reconcileRepairsAStaleGridOnce() throws {
    let (v, _, t) = try makeNode(size: big); defer { v.unmount() }
    // stale as a late frame tick leaves it: an old queued size applied over the current frame
    let old = gridFor(small)
    t.resize(cols: old.0, rows: old.1)   // test-only: production resizes go through the frame path
    #expect(dims(t) == old)
    let sink = SizeSink(); t.terminalDelegate = sink
    v.reconcileGrid()
    #expect(dims(t) == gridFor(big))
    #expect(sink.sizes.count == 1 && sink.sizes.first.map { $0 == gridFor(big) } == true)
    #expect(t.frame.size == CGSize(width: big.width, height: big.height - TerminalNodeView.titleHeight))
    v.reconcileGrid()
    v.needsLayout = true; v.layoutSubtreeIfNeeded()
    #expect(sink.sizes.count == 1)
}

/// A grid that already matches: reconcile (and the layout that calls it) never resizes; neither does zoom (2H).
@MainActor @Test func reconcileIsANoOpWhenTheGridMatches() throws {
    let canvas = CanvasState()
    let (v, _, t) = try makeNode(canvas, size: big); defer { v.unmount() }
    let sink = SizeSink(); t.terminalDelegate = sink
    let before = dims(t)
    #expect(before == gridFor(big))
    v.reconcileGrid()
    for z in [2.0, 1.0, 0.6, 1.37] {   // crosses 1.0 (raster scale 2→4) both ways
        canvas.zoom = z
        v.place(CGRect(x: 10, y: 10, width: big.width * z, height: big.height * z), canvasSize: big)
        v.needsLayout = true; v.layoutSubtreeIfNeeded()
    }
    #expect(sink.sizes.isEmpty)
    #expect(dims(t) == before)
}

/// Zoom below 0.5 unmounts the terminal; the remount at the same node size gets the same grid.
@MainActor @Test func remountAfterZoomOutKeepsTheGrid() throws {
    let canvas = CanvasState()
    let (v, _, t) = try makeNode(canvas, size: big); defer { v.unmount() }
    let before = dims(t)
    canvas.zoom = 0.4
    v.place(CGRect(x: 0, y: 0, width: big.width * 0.4, height: big.height * 0.4), canvasSize: big)
    v.setInteractive(false); v.layoutSubtreeIfNeeded()
    canvas.zoom = 0.8
    v.place(CGRect(x: 0, y: 0, width: big.width * 0.8, height: big.height * 0.8), canvasSize: big)
    v.setInteractive(true); v.layoutSubtreeIfNeeded()
    let t2 = try #require(v.term)
    #expect(t2 !== t && dims(t2) == before)
}

/// A body just under a whole number of cells: SwiftTerm floors to one row/col fewer, which is correct,
/// so reconcile must not read it as stale (it sits in the zoom hot path).
@MainActor @Test func reconcileMatchesSwiftTermsFloorJustUnderAWholeCell() throws {
    let (v, _, t) = try makeNode(size: big); defer { v.unmount() }
    let grid = t.getOptimalFrameSize().size, d = t.terminalDimensions
    let cellW = grid.width / CGFloat(d.cols), cellH = grid.height / CGFloat(d.rows)
    let under = CGSize(width: cellW * 100 - 0.001, height: cellH * 30 - 0.001 + TerminalNodeView.titleHeight)
    v.place(CGRect(origin: .zero, size: under), canvasSize: under)
    v.layoutSubtreeIfNeeded()
    #expect(dims(t) == gridFor(under))
    let sink = SizeSink(); t.terminalDelegate = sink
    #expect(v.reconcileGrid() == false)
    #expect(sink.sizes.isEmpty)
}
