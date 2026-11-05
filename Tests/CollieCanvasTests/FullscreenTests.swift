import CoreGraphics
import Foundation
import Testing
import CollieCanvas

/// Tela cheia: one node fills the canvas area; the canvas underneath keeps its zoom, position and frames.
@MainActor @Suite struct FullscreenTests {
    private func canvas() -> (CanvasState, UUID, UUID, UUID) {
        let c = CanvasState(), a = UUID(), b = UUID(), d = UUID()
        c.frames = [a: CGRect(x: 0, y: 0, width: 640, height: 400),      // top left
                    b: CGRect(x: 700, y: 0, width: 640, height: 400),    // top right
                    d: CGRect(x: 100, y: 500, width: 640, height: 400)]  // below
        c.shown = [a, b, d]
        c.zoom = 0.73; c.offset = CGPoint(x: -120, y: 48)
        return (c, a, b, d)
    }

    @Test func enterAndExitKeepZoomPositionAndFrames() {
        let (c, a, _, _) = canvas()
        let frames = c.frames
        c.toggleFullscreen(a)
        #expect(c.fullscreen == a)
        #expect(c.zoom == 0.73 && c.offset == CGPoint(x: -120, y: 48) && c.frames == frames)
        c.toggleFullscreen(a)
        #expect(c.fullscreen == nil)
        #expect(c.zoom == 0.73 && c.offset == CGPoint(x: -120, y: 48) && c.frames == frames)
    }

    @Test func stepFollowsCanvasOrderAndWraps() {
        let (c, a, b, d) = canvas()
        #expect(c.fullscreenOrder == [a, b, d])   // rows top to bottom, then left to right
        c.toggleFullscreen(a)
        c.stepFullscreen(1); #expect(c.fullscreen == b)
        c.stepFullscreen(1); #expect(c.fullscreen == d)
        c.stepFullscreen(1); #expect(c.fullscreen == a)
        c.stepFullscreen(-1); #expect(c.fullscreen == d)
    }

    @Test func stepDoesNothingOutsideFullscreen() {
        let (c, _, _, _) = canvas()
        c.stepFullscreen(1)
        #expect(c.fullscreen == nil)
    }

    @Test func hiddenNodesAreNotInTheOrder() {
        let (c, a, _, d) = canvas()
        c.shown = [a, d]   // b: another paddock or docked
        #expect(c.fullscreenOrder == [a, d])
    }
}
