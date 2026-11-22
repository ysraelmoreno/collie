import AppKit
import QuartzCore
import CollieDevice

/// The frame drawn around a Device panel's screen (PRD D1, design `docs/pages/painel-device-molduras/index.html`):
/// pure geometry (`layout`) plus the layers that draw it. The screen has exactly the video's aspect, so no letterbox.
enum DeviceBezel {
    /// Room left around the frame inside the stage (the prototype's `.stage { padding: 14px }`).
    static let margin: CGFloat = 14
    /// Under this screen width (height, in landscape) the frame goes away: `bare`.
    static let minScreen: CGFloat = 200

    struct Geometry: Equatable {
        let kind: DeviceFrame.Kind      // after the small-area fallback
        let landscape: Bool
        let bezel: CGRect
        let screen: CGRect
        let radius: CGFloat             // the frame's corners
        let screenRadius: CGFloat
        let edgeX: CGFloat              // border on the left and on the right
        let edgeY: CGFloat              // border on top and at the bottom
    }

    /// Portrait borders: `side` left/right, `end` top/bottom; points, or (`perShort`) fractions of the screen's short side.
    private static func metrics(_ k: DeviceFrame.Kind) -> (side: CGFloat, end: CGFloat, perShort: Bool, radius: CGFloat, screenRadius: CGFloat?) {
        switch k {
        case .phone: (6, 6, false, 32, nil)
        case .fold: (7, 7, false, 24, nil)
        case .tablet: (12, 12, false, 22, nil)
        case .island: (7, 7, false, 40, nil)
        // 6% of the frame's width at the sides, 15% forehead and chin: the screen is 88% of the frame's short side
        case .classic: (0.06 / 0.88, 0.15 / 0.88, true, 34, 2)
        case .ipad: (14, 14, false, 26, nil)
        case .bare: (0, 0, false, 10, 10)
        }
    }

    static func layout(kind: DeviceFrame.Kind, area: CGRect, video: CGSize) -> (bezel: CGRect, screen: CGRect) {
        let g = resolve(kind: kind, area: area, video: video)
        return (g.bezel, g.screen)
    }

    static func resolve(kind: DeviceFrame.Kind, area: CGRect, video: CGSize) -> Geometry {
        let inner = area.insetBy(dx: margin, dy: margin)
        guard video.width > 0, video.height > 0, inner.width > 0, inner.height > 0 else {
            let r = CGRect(x: area.midX, y: area.midY, width: 0, height: 0)
            return Geometry(kind: .bare, landscape: false, bezel: r, screen: r, radius: 10, screenRadius: 10, edgeX: 0, edgeY: 0)
        }
        let m = metrics(kind), landscape = video.width > video.height
        let short = min(video.width, video.height)
        let bx = landscape ? m.end : m.side, by = landscape ? m.side : m.end   // the borders turn with the video
        // screen = t × video; constant borders take from the room, proportional ones scale with t
        let tx = m.perShort ? inner.width / (video.width + 2 * bx * short) : (inner.width - 2 * bx) / video.width
        let ty = m.perShort ? inner.height / (video.height + 2 * by * short) : (inner.height - 2 * by) / video.height
        let t = max(0, min(tx, ty))
        if kind != .bare, t * short < minScreen { return resolve(kind: .bare, area: area, video: video) }
        let ex = m.perShort ? bx * t * short : bx, ey = m.perShort ? by * t * short : by
        let sw = t * video.width, sh = t * video.height
        let bezel = CGRect(x: inner.midX - sw / 2 - ex, y: inner.midY - sh / 2 - ey, width: sw + 2 * ex, height: sh + 2 * ey)
        return Geometry(kind: kind, landscape: landscape, bezel: bezel, screen: bezel.insetBy(dx: ex, dy: ey),
                        radius: m.radius, screenRadius: m.screenRadius ?? max(0, m.radius - m.side), edgeX: ex, edgeY: ey)
    }

    /// Side buttons in portrait: (on the right?, start, length) in % of the frame's height (prototype `side`).
    static func sideButtons(_ k: DeviceFrame.Kind) -> [(right: Bool, at: CGFloat, length: CGFloat)] {
        switch k {
        case .phone: [(true, 18, 9), (true, 31, 15)]
        case .fold: [(true, 14, 12)]
        case .island: [(false, 16, 5), (false, 24, 9), (false, 35, 9), (true, 26, 13)]
        case .classic: [(false, 18, 6), (false, 27, 9), (true, 22, 9)]
        case .tablet, .ipad, .bare: []
        }
    }

    /// Where the `classic` home button sits (on the chin; at the right in landscape).
    static func homeButton(_ g: Geometry) -> CGRect? {
        guard g.kind == .classic else { return nil }
        let d = (g.landscape ? g.edgeX : g.edgeY) * 0.7
        let c = g.landscape ? CGPoint(x: g.bezel.maxX - g.edgeX / 2, y: g.bezel.midY) : CGPoint(x: g.bezel.midX, y: g.bezel.maxY - g.edgeY / 2)
        return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }
}

/// The frame's layers, around the panel's video layer: `back` (body, side buttons, the parts on the border) goes
/// under it and `front` (hole, island, fold) over it. Fixed near-black on purpose: a device is dark in both themes.
@MainActor final class DeviceBezelLayers {
    let back = CALayer()
    let front = CALayer()
    private static let body = CGColor(srgbRed: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255, alpha: 1)
    private static let outline = CGColor(srgbRed: 0x2A / 255, green: 0x2D / 255, blue: 0x35 / 255, alpha: 1)
    private static let cutout = CGColor(srgbRed: 0x05 / 255, green: 0x05 / 255, blue: 0x06 / 255, alpha: 1)
    private static let cutoutRing = CGColor(srgbRed: 0x1A / 255, green: 0x1B / 255, blue: 0x20 / 255, alpha: 1)
    private static let lens = CGColor(srgbRed: 0x1C / 255, green: 0x1F / 255, blue: 0x27 / 255, alpha: 1)
    private static let lensRing = CGColor(srgbRed: 0x2C / 255, green: 0x30 / 255, blue: 0x40 / 255, alpha: 1)
    private static let speaker = CGColor(srgbRed: 0x23 / 255, green: 0x26 / 255, blue: 0x2E / 255, alpha: 1)

    /// `bareBorder`: the theme's border, the only themed color (the frameless outline).
    func apply(_ g: DeviceBezel.Geometry, video: CALayer, bareBorder: CGColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        back.frame = video.superlayer?.bounds ?? .zero; front.frame = back.frame
        back.sublayers = nil; front.sublayers = nil
        video.frame = g.screen; video.cornerRadius = g.screenRadius; video.masksToBounds = true
        guard g.screen.width > 0 else { return }

        let body = CALayer()
        body.frame = g.bezel; body.cornerRadius = g.radius
        body.shadowColor = .black; body.shadowOpacity = 0.45; body.shadowRadius = 15; body.shadowOffset = CGSize(width: 0, height: 12)
        body.shadowPath = CGPath(roundedRect: body.bounds, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil)
        if g.kind == .bare {
            body.borderColor = bareBorder; body.borderWidth = 1; body.shadowOpacity = 0.3; body.shadowRadius = 12
            back.addSublayer(body)
            return
        }
        body.backgroundColor = Self.body; body.borderColor = Self.outline; body.borderWidth = 1
        for s in DeviceBezel.sideButtons(g.kind) {   // portrait right → top, left → bottom (as the prototype turns)
            let b = CALayer()
            b.backgroundColor = Self.outline; b.cornerRadius = 1.5
            b.frame = g.landscape
                ? CGRect(x: g.bezel.minX + g.bezel.width * s.at / 100, y: s.right ? g.bezel.minY - 3 : g.bezel.maxY,
                         width: g.bezel.width * s.length / 100, height: 3)
                : CGRect(x: s.right ? g.bezel.maxX : g.bezel.minX - 3, y: g.bezel.minY + g.bezel.height * s.at / 100,
                         width: 3, height: g.bezel.height * s.length / 100)
            back.addSublayer(b)
        }
        back.addSublayer(body)

        switch g.kind {
        case .tablet, .ipad:   // camera centered on the top border
            back.addSublayer(Self.dot(CGPoint(x: g.bezel.midX, y: g.bezel.minY + g.edgeY / 2), 6, Self.lens, ring: Self.lensRing))
        case .classic:          // speaker and camera on the forehead (left in landscape); the home ring is a button
            let short = min(g.bezel.width, g.bezel.height), along = short * 0.22
            let spk = CALayer()
            spk.backgroundColor = Self.speaker; spk.cornerRadius = 2
            spk.frame = g.landscape
                ? CGRect(x: g.bezel.minX + g.edgeX / 2 - 2, y: g.bezel.midY - along / 2, width: 4, height: along)
                : CGRect(x: g.bezel.midX - along / 2, y: g.bezel.minY + g.edgeY / 2 - 2, width: along, height: 4)
            back.addSublayer(spk)
            let cam = g.landscape ? CGPoint(x: g.bezel.minX + g.edgeX / 2, y: g.bezel.minY + g.bezel.height * 0.29)
                                  : CGPoint(x: g.bezel.minX + g.bezel.width * 0.29 + 3, y: g.bezel.minY + g.edgeY / 2)
            back.addSublayer(Self.dot(cam, 6, Self.lens, ring: Self.lensRing))
        case .phone:            // punch hole over the picture
            let c = g.landscape ? CGPoint(x: g.screen.minX + 11.5, y: g.screen.midY) : CGPoint(x: g.screen.midX, y: g.screen.minY + 11.5)
            front.addSublayer(Self.dot(c, 9, Self.cutout, ring: Self.cutoutRing))
        case .island:
            let pill = CALayer()
            pill.backgroundColor = Self.cutout; pill.cornerRadius = 9.5
            pill.frame = g.landscape
                ? CGRect(x: g.screen.minX + 7, y: g.screen.midY - g.screen.height * 0.155, width: 19, height: g.screen.height * 0.31)
                : CGRect(x: g.screen.midX - g.screen.width * 0.155, y: g.screen.minY + 7, width: g.screen.width * 0.31, height: 19)
            front.addSublayer(pill)
        case .fold:             // translucent crease across the middle
            let h = CAGradientLayer()
            h.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.07), CGColor(gray: 1, alpha: 0.25), CGColor(gray: 1, alpha: 0)]
            h.locations = [0, 0.45, 0.55, 1]
            if g.landscape {
                h.startPoint = CGPoint(x: 0.5, y: 0); h.endPoint = CGPoint(x: 0.5, y: 1)
                h.frame = CGRect(x: g.screen.minX, y: g.screen.midY - 5, width: g.screen.width, height: 10)
            } else {
                h.startPoint = CGPoint(x: 0, y: 0.5); h.endPoint = CGPoint(x: 1, y: 0.5)
                h.frame = CGRect(x: g.screen.midX - 5, y: g.screen.minY, width: 10, height: g.screen.height)
            }
            front.addSublayer(h)
        case .bare: break
        }
    }

    private static func dot(_ c: CGPoint, _ d: CGFloat, _ fill: CGColor, ring: CGColor) -> CALayer {
        let l = CALayer()
        l.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        l.cornerRadius = d / 2; l.backgroundColor = fill; l.borderColor = ring; l.borderWidth = 1.5
        return l
    }
}
