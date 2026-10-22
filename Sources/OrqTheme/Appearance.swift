import AppKit

public enum ThemeChoice: String, CaseIterable, Sendable {
    case dark, light, system
    /// `nil` follows the system.
    public var appearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

public enum WindowStructure: String, CaseIterable, Sendable { case compact, full }

public struct TerminalFontChoice: Sendable, Equatable {
    public var family: String
    public var size: CGFloat
    public init(family: String, size: CGFloat) { self.family = family; self.size = size }
    public static let `default` = TerminalFontChoice(family: "DM Mono", size: 13)
    public static let families = ["DM Mono", "SF Mono", "Menlo"]
    public static let sizes: ClosedRange<CGFloat> = 11...16
    public var font: NSFont {
        family == "SF Mono" ? .monospacedSystemFont(ofSize: size, weight: .regular) : OrqFont.mono(size, family: family)
    }
}

public enum AppearanceKeys {
    public static let theme = "appearance.theme", structure = "appearance.structure",
                      terminalFamily = "appearance.terminalFamily", terminalSize = "appearance.terminalSize"
}

public struct AppearanceSettings: Equatable {
    public var theme: ThemeChoice
    public var structure: WindowStructure
    public var terminalFont: TerminalFontChoice

    public init(theme: ThemeChoice, structure: WindowStructure, terminalFont: TerminalFontChoice) {
        self.theme = theme; self.structure = structure; self.terminalFont = terminalFont
    }

    /// Tolerant read: unknown values fall back to Escuro, Compacta, DM Mono 13.
    public init(defaults: UserDefaults) {
        theme = defaults.string(forKey: AppearanceKeys.theme).flatMap(ThemeChoice.init) ?? .dark
        structure = defaults.string(forKey: AppearanceKeys.structure).flatMap(WindowStructure.init) ?? .compact
        let family = defaults.string(forKey: AppearanceKeys.terminalFamily).flatMap { TerminalFontChoice.families.contains($0) ? $0 : nil } ?? "DM Mono"
        let raw = defaults.double(forKey: AppearanceKeys.terminalSize)
        let size = raw == 0 ? TerminalFontChoice.default.size : min(max(CGFloat(raw).rounded(), TerminalFontChoice.sizes.lowerBound), TerminalFontChoice.sizes.upperBound)
        terminalFont = TerminalFontChoice(family: family, size: size)
    }

    /// Writes the tolerant read back, so the Preferences pickers always find their stored value.
    public static func normalize(_ defaults: UserDefaults) {
        let s = AppearanceSettings(defaults: defaults)
        // only changed keys: an unchanged write still notifies the observers
        for (k, v) in [(AppearanceKeys.theme, s.theme.rawValue), (AppearanceKeys.structure, s.structure.rawValue),
                       (AppearanceKeys.terminalFamily, s.terminalFont.family)] where defaults.string(forKey: k) != v {
            defaults.set(v, forKey: k)
        }
        let size = Double(s.terminalFont.size)
        if defaults.double(forKey: AppearanceKeys.terminalSize) != size { defaults.set(size, forKey: AppearanceKeys.terminalSize) }
    }
}

/// Splits chips into the shown ones (order kept, `current` always among them) and the overflow menu.
public func chipSplit<T: Equatable>(_ items: [T], current: T?, max: Int) -> (shown: [T], overflow: [T]) {
    var room = max - (current.map(items.contains) == true ? 1 : 0)
    var shown: [T] = [], overflow: [T] = []
    for i in items {
        if i == current { shown.append(i) } else if room > 0 { shown.append(i); room -= 1 } else { overflow.append(i) }
    }
    return (shown, overflow)
}
