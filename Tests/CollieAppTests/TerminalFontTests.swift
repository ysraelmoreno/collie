import AppKit
import Testing
import SwiftTerm
import CollieCanvas
import CollieClient
import CollieCore
@testable import CollieApp

@MainActor private final class Sink: TerminalViewDelegate {
    var sent: [UInt8] = []
    var size: (Int, Int)?
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { size = (newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftTerm's `font` setter soft-resets the program (DECSTR); the font change must not.
@MainActor @Test func fontChangeKeepsTerminalModes() {
    let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
    let t = TerminalView(frame: frame, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    let sink = Sink(); t.terminalDelegate = sink
    t.feed(text: "\u{1b}[?1h")   // application cursor keys, as vim/less set them
    let cols = t.terminalDimensions.cols
    t.setFontKeepingModes(.monospacedSystemFont(ofSize: 16, weight: .regular))
    #expect(t.terminalDimensions.cols < cols)   // it reflowed
    #expect(sink.size?.0 == t.terminalDimensions.cols)   // and told the PTY
    #expect(t.frame == frame)
    t.doCommand(by: #selector(NSResponder.moveUp(_:)))
    #expect(sink.sent == EscapeSequences.moveUpApp)
}

/// Zoom scales the node (its bounds stay the canvas size): cols/rows and the PTY keep their size. A node resize changes them.
@MainActor @Test func zoomKeepsTerminalSize() throws {
    let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-zoom-\(UUID())")))
    let canvas = CanvasState(), id = UUID()
    let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
    defer { v.unmount() }
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
    let size = CGSize(width: 600, height: 400)
    v.place(CGRect(origin: .zero, size: size), canvasSize: size)
    v.setInteractive(true)
    v.layoutSubtreeIfNeeded()
    let t = try #require(v.term)
    let sink = Sink(); t.terminalDelegate = sink
    let cols = t.terminalDimensions.cols, rows = t.terminalDimensions.rows
    // no window: backing 2; integer multiples only (SwiftTerm snaps cells to 1/backing)
    for (z, scale) in [(2.0, 4.0), (0.5, 2.0), (1.37, 4.0)] {
        canvas.zoom = z
        v.place(CGRect(x: 40, y: 30, width: size.width * z, height: size.height * z), canvasSize: size)
        v.layoutSubtreeIfNeeded()
        #expect(near(v.bounds.width, size.width) && near(v.bounds.height, size.height))
        #expect(t.frame.size == CGSize(width: 600, height: 400 - TerminalNodeView.titleHeight))
        #expect(t.terminalDimensions.cols == cols && t.terminalDimensions.rows == rows)
        #expect(t.layer.map { near($0.contentsScale, scale) } == true)
        if z == 2 {
            // a window point maps back to the canvas point under it: SwiftTerm's mouse path is convert(_:from: nil)
            let p = CGPoint(x: 100, y: 132)
            #expect(near(t.convert(v.convert(p, to: nil), from: nil), t.convert(p, from: v)))
            #expect(near(v.convert(CGPoint(x: 100, y: 0), to: nil).x - v.convert(CGPoint.zero, to: nil).x, 200))
        }
    }
    #expect(sink.size == nil)
    v.place(CGRect(x: 40, y: 30, width: 800 * 1.37, height: 500 * 1.37), canvasSize: CGSize(width: 800, height: 500))
    v.layoutSubtreeIfNeeded()
    #expect(t.terminalDimensions.cols > cols && t.terminalDimensions.rows > rows)
    #expect(sink.size?.0 == t.terminalDimensions.cols && sink.size?.1 == t.terminalDimensions.rows)
}

/// Option types macOS characters (⌥C = ç on the US and Brazilian Pro layouts), as in Terminal: not Meta (ESC c).
@MainActor @Test func optionTypesCharactersNotMeta() throws {
    let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-opt-\(UUID())")))
    let canvas = CanvasState(), id = UUID()
    let v = TerminalNodeView(id: id, client: client, canvas: canvas, node: NodeController(id: id, client: client))
    defer { v.unmount() }
    let size = CGSize(width: 600, height: 400)
    v.place(CGRect(origin: .zero, size: size), canvasSize: size)
    v.setInteractive(true)
    let t = try #require(v.term)
    #expect(t.optionAsMetaKey == false)
}
