import AppKit
import Testing
@testable import OrqApp

/// Zoom gestures over a panel's content belong to the panel (FigCraft zooms itself); elsewhere they zoom the canvas.
@MainActor @Suite struct PanelZoomRoutingTests {
    @Test func pinchOverPanelContentLeavesTheCanvas() {
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let body = PanelBody(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let web = NSView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))   // e.g. the web view inside the card
        body.addSubview(web); canvas.addSubview(body)
        #expect(!CanvasViewport.zoomsCanvas(hit: web))
        #expect(!CanvasViewport.zoomsCanvas(hit: body))
        #expect(CanvasViewport.zoomsCanvas(hit: canvas))
        #expect(CanvasViewport.zoomsCanvas(hit: nil))
    }

    @Test func focusInsidePanelKeepsKeyZoomForThePanel() {
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let body = PanelBody(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let field = NSView(frame: body.bounds)
        body.addSubview(field); canvas.addSubview(body)
        #expect(CanvasViewport.focusIsInPanel(field))
        #expect(!CanvasViewport.focusIsInPanel(canvas))
        #expect(!CanvasViewport.focusIsInPanel(nil))
    }
}
