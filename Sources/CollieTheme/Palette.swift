import AppKit
import SwiftUI

/// sRGB color from a 0xRRGGBB literal.
public struct RGB: Sendable, Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// WCAG 2.x contrast ratio between two sRGB colors.
public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    func luminance(_ c: RGB) -> Double {
        func lin(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Theme tokens. Hex values come from the plan 3R token table.
public struct Palette: Sendable, Equatable {
    public let background: RGB
    public let surface: RGB
    public let sidebar: RGB
    public let sunken: RGB
    public let raised: RGB
    public let border: RGB
    public let borderSoft: RGB
    public let grid: RGB
    public let scrim: RGB
    public let text: RGB
    public let textSecondary: RGB
    public let muted: RGB
    public let accent: RGB
    public let onAccent: RGB
    public let attention: RGB
    public let attentionTint: RGB
    public let secondary: RGB
    public let danger: RGB

    public static let dark = Palette(
        background: RGB(hex: 0x0E1326),
        surface: RGB(hex: 0x161C36),
        sidebar: RGB(hex: 0x121831),
        sunken: RGB(hex: 0x0B1020),
        raised: RGB(hex: 0x1B2340),
        border: RGB(hex: 0x262E52),
        borderSoft: RGB(hex: 0x1E2647),
        grid: RGB(hex: 0x151B33),
        scrim: RGB(hex: 0x070A16),
        text: RGB(hex: 0xE8ECF8),
        textSecondary: RGB(hex: 0xB6BEDB),
        muted: RGB(hex: 0x8C95B8),
        accent: RGB(hex: 0x6EE7B7),
        onAccent: RGB(hex: 0x0E1326),
        attention: RGB(hex: 0xFFB86B),
        attentionTint: RGB(hex: 0x2A2418),
        secondary: RGB(hex: 0x93A4FF),
        danger: RGB(hex: 0xFF8A8A),
    )

    public static let light = Palette(
        background: RGB(hex: 0xF3F4F1),
        surface: RGB(hex: 0xFFFFFF),
        sidebar: RGB(hex: 0xECEDE9),
        sunken: RGB(hex: 0xF7F7F5),
        raised: RGB(hex: 0xE3E7F7),
        border: RGB(hex: 0xD9DBD5),
        borderSoft: RGB(hex: 0xE4E5E0),
        grid: RGB(hex: 0xE4E5E0),
        scrim: RGB(hex: 0xC9CBC5),
        text: RGB(hex: 0x15171C),
        textSecondary: RGB(hex: 0x2E323B),
        muted: RGB(hex: 0x5C6270),
        accent: RGB(hex: 0x2448C9),
        onAccent: RGB(hex: 0xFFFFFF),
        attention: RGB(hex: 0xA14A06),
        attentionTint: RGB(hex: 0xFDF6EE),
        secondary: RGB(hex: 0x6B3FC4),
        danger: RGB(hex: 0xB42318),
    )
}

/// Dynamic NSColors that pick the dark or light palette from the appearance.
public enum CollieColor {
    public static let background: NSColor = dynamic("background", \.background)
    public static let surface: NSColor = dynamic("surface", \.surface)
    public static let sidebar: NSColor = dynamic("sidebar", \.sidebar)
    public static let sunken: NSColor = dynamic("sunken", \.sunken)
    public static let raised: NSColor = dynamic("raised", \.raised)
    public static let border: NSColor = dynamic("border", \.border)
    public static let borderSoft: NSColor = dynamic("borderSoft", \.borderSoft)
    public static let grid: NSColor = dynamic("grid", \.grid)
    public static let scrim: NSColor = dynamic("scrim", \.scrim)
    public static let text: NSColor = dynamic("text", \.text)
    public static let textSecondary: NSColor = dynamic("textSecondary", \.textSecondary)
    public static let muted: NSColor = dynamic("muted", \.muted)
    public static let accent: NSColor = dynamic("accent", \.accent)
    public static let onAccent: NSColor = dynamic("onAccent", \.onAccent)
    public static let attention: NSColor = dynamic("attention", \.attention)
    public static let attentionTint: NSColor = dynamic("attentionTint", \.attentionTint)
    public static let secondary: NSColor = dynamic("secondary", \.secondary)
    public static let danger: NSColor = dynamic("danger", \.danger)

    private static func dynamic(_ token: String, _ key: KeyPath<Palette, RGB>) -> NSColor {
        NSColor(name: "collie.\(token)") { appearance in
            let palette = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Palette.dark : Palette.light
            return palette[keyPath: key].nsColor
        }
    }
}

public extension ShapeStyle where Self == Color {
    static var collieBackground: Color { Color(nsColor: CollieColor.background) }
    static var collieSurface: Color { Color(nsColor: CollieColor.surface) }
    static var collieSidebar: Color { Color(nsColor: CollieColor.sidebar) }
    static var collieSunken: Color { Color(nsColor: CollieColor.sunken) }
    static var collieRaised: Color { Color(nsColor: CollieColor.raised) }
    static var collieBorder: Color { Color(nsColor: CollieColor.border) }
    static var collieBorderSoft: Color { Color(nsColor: CollieColor.borderSoft) }
    static var collieGrid: Color { Color(nsColor: CollieColor.grid) }
    static var collieScrim: Color { Color(nsColor: CollieColor.scrim) }
    static var collieText: Color { Color(nsColor: CollieColor.text) }
    static var collieTextSecondary: Color { Color(nsColor: CollieColor.textSecondary) }
    static var collieMuted: Color { Color(nsColor: CollieColor.muted) }
    static var collieAccent: Color { Color(nsColor: CollieColor.accent) }
    static var collieOnAccent: Color { Color(nsColor: CollieColor.onAccent) }
    static var collieAttention: Color { Color(nsColor: CollieColor.attention) }
    static var collieAttentionTint: Color { Color(nsColor: CollieColor.attentionTint) }
    static var collieSecondary: Color { Color(nsColor: CollieColor.secondary) }
    static var collieDanger: Color { Color(nsColor: CollieColor.danger) }
}
