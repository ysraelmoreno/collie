import AppKit
import SwiftUI

/// Bundled UI/mono fonts; a missing family falls back to the system fonts (no error).
public enum OrqFont {
    public static let uiFamily = "Space Grotesk", monoFamily = "DM Mono"

    public static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular, family: String = uiFamily) -> NSFont {
        named(family, size, weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular, family: String = monoFamily) -> NSFont {
        named(family, size, weight) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // ponytail: read once; ATS registers the bundled fonts (ATSApplicationFontsPath) before any lookup. Fonts installed
    // while the app runs are seen at the next launch.
    private static let families = Set(NSFontManager.shared.availableFontFamilies)

    /// Weight goes through the descriptor traits, which also drives the variable Space Grotesk.
    private static func named(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        guard families.contains(family) else { return nil }
        let d = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: d, size: size)
    }
}

extension Font {
    public static func orqUI(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { Font(OrqFont.ui(size, w.nsWeight)) }
    public static func orqMono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { Font(OrqFont.mono(size, w.nsWeight)) }
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
