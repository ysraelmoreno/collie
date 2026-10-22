import Foundation
import Testing
@testable import OrqCanvas

@MainActor
@Suite struct CanvasStateTests {
    let vp = CGSize(width: 1000, height: 800)

    @Test func zoomKeepsCursorPointFixed() {
        let s = CanvasState()
        s.offset = CGPoint(x: 120, y: -40)
        let p = CGPoint(x: 333, y: 222)
        let before = s.toCanvas(p)
        s.zoom(by: 1.5, around: p)
        let after = s.toCanvas(p)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        #expect(s.zoom == 1.5)
    }

    @Test func zoomIsClamped() {
        let s = CanvasState()
        s.zoom(by: 10, around: .zero)
        #expect(s.zoom == 2.0)
        s.zoom(by: 0.01, around: .zero)
        #expect(s.zoom == 0.25)
    }

    @Test func panMovesContentWithDrag() {
        let s = CanvasState()
        s.zoom(by: 2, around: .zero)
        s.pan(by: CGSize(width: 100, height: 0))
        #expect(s.offset.x == -50)
        #expect(s.toScreen(.zero).x == 100)
    }

    @Test func visibleNodesCullsOffscreen() {
        let s = CanvasState()
        let far = UUID(), near = UUID(), inside = UUID()
        s.frames[far] = CGRect(x: 6000, y: 0, width: 100, height: 100)
        s.frames[near] = CGRect(x: 1150, y: 0, width: 100, height: 100)
        s.frames[inside] = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(s.visibleNodes(viewport: vp) == [near, inside])
    }

    @Test func placeNewAvoidsOverlap() {
        let s = CanvasState()
        var rects: [CGRect] = []
        for _ in 0..<3 {
            let r = s.placeNew(viewport: vp)
            rects.append(r)
            s.frames[UUID()] = r
        }
        for i in 0..<3 { for j in (i + 1)..<3 where j < 3 { #expect(!rects[i].intersects(rects[j])) } }
    }

    @Test func placeNewUsesDefaultTerminalSize() {
        #expect(CanvasState().placeNew(viewport: vp).size == CanvasState.defaultTerminalSize)
        #expect(CanvasState.defaultTerminalSize == CGSize(width: 640, height: 400))
    }

    @Test func pendingFrameIsUsedOnFirstPlacementOnly() {
        let s = CanvasState(), id = UUID(), r = CGRect(x: 900, y: 700, width: 640, height: 400)
        s.setFrame(r, for: id)               // reply before the event: not placed yet
        #expect(s.frames[id] == nil)
        s.place(id, viewport: vp)
        #expect(s.frames[id] == r && s.pendingFrames[id] == nil)
        let r2 = CGRect(x: 5, y: 5, width: 640, height: 400)
        s.setFrame(r2, for: id)              // already placed: overwritten directly
        #expect(s.frames[id] == r2)
    }

    @Test func placeNewNeverStacksManyNodes() {
        let s = CanvasState()
        var rects: [CGRect] = []
        for _ in 0..<21 {
            let r = s.placeNew(viewport: vp)
            rects.append(r)
            s.frames[UUID()] = r
        }
        for i in rects.indices { for j in rects.indices where j > i { #expect(!rects[i].intersects(rects[j]), "\(i) \(j)") } }
    }

    @Test func fitAllFitsAndResets() {
        let s = CanvasState()
        s.fitAll(viewport: vp)
        #expect(s.zoom == 1 && s.offset == .zero)
        s.frames[UUID()] = CGRect(x: 0, y: 0, width: 4000, height: 400)
        s.fitAll(viewport: vp)
        #expect(s.zoom == 0.25)
        let tl = s.toScreen(.zero), br = s.toScreen(CGPoint(x: 4000, y: 400))
        #expect(tl.x >= 0 && br.x <= vp.width && br.y <= vp.height)
    }

    @Test func layoutRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("a/b/layout.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let f = LayoutFile(offset: CGPoint(x: 1, y: 2), zoom: 1.25, frames: [id: CGRect(x: 3, y: 4, width: 5, height: 6)])
        try LayoutStore.save(f, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(id.uuidString))
        let g = try #require(LayoutStore.load(url))
        #expect(g.frames == f.frames && g.zoom == 1.25 && g.offset == f.offset && g.schemaVersion == 1)
    }

    @Test func loadMissingOrCorruptIsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(LayoutStore.load(url) == nil)
        try Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LayoutStore.load(url) == nil)
    }

    @Test func zoomAroundCursorWhenClamped() {
        let s = CanvasState()
        s.zoom(by: 2, around: .zero)
        let p = CGPoint(x: 400, y: 300)
        let before = s.toCanvas(p)
        s.zoom(by: 1.5, around: p)
        let after = s.toCanvas(p)
        #expect(s.zoom == 2.0)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func visibleNodesMarginScalesWithZoom() {
        let s = CanvasState()
        s.zoom(by: 0.5, around: .zero)
        // visible canvas width 2000, margin 200/0.5 = 400 canvas units -> edge at x = 2400
        let inside = UUID(), outside = UUID()
        s.frames[inside] = CGRect(x: 2399, y: 0, width: 10, height: 10)
        s.frames[outside] = CGRect(x: 2401, y: 0, width: 10, height: 10)
        #expect(s.visibleNodes(viewport: vp) == [inside])
    }

    @Test func fitAllTinyFrameCentres() {
        let s = CanvasState()
        s.frames[UUID()] = CGRect(x: 500, y: 700, width: 10, height: 10)
        s.fitAll(viewport: vp)
        #expect(s.zoom == 2.0)
        let c = s.toScreen(CGPoint(x: 505, y: 705))
        #expect(abs(c.x - 500) < 1e-6 && abs(c.y - 400) < 1e-6)
    }

    @Test func loadToleratesDuplicateUUIDKeys() throws {
        let id = UUID().uuidString
        let json = #"{"schemaVersion":1,"offset":[0,0],"zoom":1,"frames":{"\#(id.lowercased())":[[1,2],[3,4]],"\#(id.uppercased())":[[1,2],[3,4]]}}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LayoutStore.load(url)?.frames.count == 1)
    }

    @Test func loadRejectsBadZoom() throws {
        for z in ["0", "-1", "1e999"] {
            let json = #"{"schemaVersion":1,"offset":[0,0],"zoom":\#(z),"frames":{}}"#
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(json.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(LayoutStore.load(url) == nil)
        }
    }
}
