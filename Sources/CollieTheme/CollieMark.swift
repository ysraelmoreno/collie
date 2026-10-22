import SwiftUI

/// The "Herd" mark: a C-shaped arc (the collie's run) gathering three dots (terminals), one accent dot at the arc's start.
/// Geometry lives in a 200×200 viewBox and scales with `size`; Resources/AppIcon.svg draws the same shapes.
public struct CollieMark: View {
    public let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(size: CGFloat) { self.size = size }

    /// −45° to +45° through the left, radius 64 around the centre of `rect`.
    public static func arcPath(in rect: CGRect) -> Path {
        let k = rect.width / 200
        var p = Path()
        p.addArc(center: CGPoint(x: rect.minX + 100 * k, y: rect.minY + 100 * k), radius: 64 * k,
                 startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: true)
        return p
    }

    // ponytail: brief's brand ink/accent, not Palette tokens (those are the app chrome's, not the logo's)
    private var accent: Color { scheme == .dark ? Color(red: 0x6E / 255, green: 0x9B / 255, blue: 1) : Color(red: 0x2F / 255, green: 0x6B / 255, blue: 1) }

    public var body: some View {
        let k = size / 200
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ZStack(alignment: .topLeading) {
            Self.arcPath(in: rect).stroke(Color.collieText, style: StrokeStyle(lineWidth: 18 * k, lineCap: .round))
            ForEach([(92.0, 82.0), (120, 100), (92, 118)], id: \.1) { x, y in
                Circle().fill(Color.collieText).frame(width: 22 * k, height: 22 * k).offset(x: (x - 11) * k, y: (y - 11) * k)
            }
            Circle().fill(accent).frame(width: 32 * k, height: 32 * k).offset(x: (145.3 - 16) * k, y: (54.7 - 16) * k)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
