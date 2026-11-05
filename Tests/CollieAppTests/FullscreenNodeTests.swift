import AppKit
import Testing
import SwiftTerm
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme
@testable import CollieApp

@MainActor private final class PtySink: TerminalViewDelegate {
    var sizes: [(Int, Int)] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizes.append((newCols, newRows)) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor private func dims(_ t: TerminalView) -> (Int, Int) { (t.terminalDimensions.cols, t.terminalDimensions.rows) }

@MainActor @Suite struct FullscreenNodeTests {
    private func node(_ canvas: CanvasState, size: CGSize) throws -> (TerminalNodeView, NSWindow, NodeTerminal) {
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-fs-\(UUID())")))
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

    /// The node fills the area under the bar, its own title tucked under it; the size is screen size at any zoom.
    @Test func fullscreenFrameFillsTheViewportUnderTheBar() {
        let r = CanvasViewport.fullscreenFrame(viewport: CGSize(width: 1400, height: 900))
        #expect(r.minX == 0 && r.width == 1400 && r.maxY == 900)
        #expect(r.minY == CanvasViewport.fullscreenBarHeight - TerminalNodeView.titleHeight)
    }

    /// Entering resizes the PTY to the full area; leaving puts back exactly the grid it had, zoom untouched.
    @Test func ptyResizesInFullscreenAndRestoresOnExit() throws {
        let canvas = CanvasState(); canvas.zoom = 0.7
        let small = CGSize(width: 640, height: 400)
        let (v, _, t) = try node(canvas, size: small); defer { v.unmount() }
        let before = dims(t)
        let sink = PtySink(); t.terminalDelegate = sink

        let full = CanvasViewport.fullscreenFrame(viewport: CGSize(width: 1600, height: 1000))
        v.place(full, canvasSize: full.size)
        v.layoutSubtreeIfNeeded()
        let big = dims(t)
        #expect(big.0 > before.0 && big.1 > before.1)
        #expect(sink.sizes.last.map { $0 == big } == true)

        v.place(CGRect(x: 30, y: 30, width: small.width * 0.7, height: small.height * 0.7), canvasSize: small)
        v.layoutSubtreeIfNeeded()
        #expect(dims(t) == before)
        #expect(sink.sizes.last.map { $0 == before } == true)
        #expect(canvas.zoom == 0.7)
    }

    /// Esc leaves fullscreen, except while a terminal has focus: there it belongs to the process (Claude Code interrupts).
    @Test func escLeavesExceptWithTheTerminalFocused() throws {
        let canvas = CanvasState()
        let (v, _, t) = try node(canvas, size: CGSize(width: 640, height: 400)); defer { v.unmount() }
        #expect(!CanvasViewport.escExitsFullscreen(t))
        #expect(CanvasViewport.escExitsFullscreen(v))   // e.g. its title bar
        #expect(CanvasViewport.escExitsFullscreen(PanelBody()))
        #expect(CanvasViewport.escExitsFullscreen(nil))
    }

    /// ⌘⏎ acts on the node holding the focus.
    @Test func focusedNodeIsTheOneAroundTheResponder() throws {
        let canvas = CanvasState()
        let (v, _, t) = try node(canvas, size: CGSize(width: 640, height: 400)); defer { v.unmount() }
        #expect(CanvasViewport.node(of: t) == v.id)
        #expect(CanvasViewport.node(of: NSView()) == nil)
        #expect(CanvasViewport.node(of: nil) == nil)
    }
}
