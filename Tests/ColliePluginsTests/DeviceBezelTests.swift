import CoreGraphics
import Testing
import CollieDevice
@testable import ColliePlugins

@Suite struct DeviceBezelTests {
    let area = CGRect(x: 0, y: 0, width: 600, height: 900)
    let portrait = CGSize(width: 1080, height: 2400)
    let landscape = CGSize(width: 2400, height: 1080)

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.01 && inner.minY >= outer.minY - 0.01 && inner.maxX <= outer.maxX + 0.01 && inner.maxY <= outer.maxY + 0.01
    }

    @Test(arguments: DeviceFrame.Kind.allCases) func screenKeepsVideoAspect(kind: DeviceFrame.Kind) {
        for video in [portrait, landscape, CGSize(width: 1768, height: 2208)] {
            let (bezel, screen) = DeviceBezel.layout(kind: kind, area: area, video: video)
            #expect(screen.width > 0)
            #expect(abs(screen.height - screen.width * video.height / video.width) <= 0.5, "\(kind) \(video) \(screen)")
            #expect(contains(bezel, screen), "\(kind) \(bezel) \(screen)")
            #expect(contains(area.insetBy(dx: DeviceBezel.margin, dy: DeviceBezel.margin), bezel), "\(kind) \(bezel)")
            #expect(abs(bezel.midX - area.midX) < 0.01 && abs(bezel.midY - area.midY) < 0.01)
        }
    }

    @Test func framedKindsHaveBorders() {
        let g = DeviceBezel.resolve(kind: .phone, area: area, video: portrait)
        #expect(g.kind == .phone && g.edgeX == 6 && g.edgeY == 6 && g.radius == 32 && g.screenRadius == 26)
        let bare = DeviceBezel.layout(kind: .bare, area: area, video: portrait)
        #expect(bare.bezel == bare.screen)
    }

    @Test func classicBordersTurnInLandscape() {
        let p = DeviceBezel.resolve(kind: .classic, area: area, video: portrait)
        #expect(p.edgeY > p.edgeX * 2, "forehead and chin on top and bottom: \(p)")
        let l = DeviceBezel.resolve(kind: .classic, area: CGRect(x: 0, y: 0, width: 900, height: 600), video: landscape)
        #expect(l.landscape && l.edgeX > l.edgeY * 2, "forehead and chin at the sides: \(l)")
        #expect(abs(l.edgeX / l.screen.height - p.edgeY / p.screen.width) < 0.001)
        #expect(p.screenRadius == 2)
        let home = DeviceBezel.homeButton(l)
        #expect(home.map { $0.midX > l.screen.maxX && contains(l.bezel, $0) } == true)
    }

    @Test(arguments: DeviceFrame.Kind.allCases) func smallAreaIsBare(kind: DeviceFrame.Kind) {
        let small = CGRect(x: 0, y: 0, width: 220, height: 500)   // screen under 200 pt wide with any border
        let g = DeviceBezel.resolve(kind: kind, area: small, video: portrait)
        #expect(g.kind == .bare)
        let (bezel, screen) = DeviceBezel.layout(kind: kind, area: small, video: portrait)
        #expect(bezel == screen)
        let wide = DeviceBezel.resolve(kind: kind, area: CGRect(x: 0, y: 0, width: 900, height: 230), video: landscape)
        #expect(wide.kind == .bare, "landscape: the screen's height counts")
    }

    @Test func devicePointMapsTheFrameScreen() throws {
        let (bezel, screen) = DeviceBezel.layout(kind: .island, area: area, video: portrait)
        let c = try #require(devicePoint(CGPoint(x: screen.midX, y: screen.midY), screen: screen, video: portrait))
        #expect(abs(Int(c.x) - 540) <= 1 && abs(Int(c.y) - 1200) <= 1, "\(c)")
        #expect(devicePoint(CGPoint(x: bezel.minX + 3, y: screen.midY), screen: screen, video: portrait) == nil)   // on the border
        #expect(devicePoint(CGPoint(x: 2, y: 2), screen: screen, video: portrait) == nil)                           // on the stage
        let tl = try #require(devicePoint(CGPoint(x: screen.minX, y: screen.minY), screen: screen, video: portrait))
        #expect(tl.x == 0 && tl.y == 0)
        let br = try #require(devicePoint(CGPoint(x: screen.maxX - 0.01, y: screen.maxY - 0.01), screen: screen, video: portrait))
        #expect(br.x == 1079 && br.y == 2399, "\(br)")
    }
}
