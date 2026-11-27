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

/// What `appearance.theme` holds: a built-in choice or `custom:<id>` (a valid id, see `ThemeFile.validId`).
public enum ThemeSelection: Equatable, Sendable {
    case dark, light, system, custom(String)

    /// `nil` for anything else, including `custom:` with an empty or invalid id.
    public init?(rawValue: String) {
        switch rawValue {
        case "dark": self = .dark
        case "light": self = .light
        case "system": self = .system
        default:
            let prefix = "custom:"
            guard rawValue.hasPrefix(prefix) else { return nil }
            let id = String(rawValue.dropFirst(prefix.count))
            guard ThemeFile.validId(id) else { return nil }
            self = .custom(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .dark: "dark"
        case .light: "light"
        case .system: "system"
        case .custom(let id): "custom:\(id)"
        }
    }

    /// Of the built-in choices; `nil` follows the system. A custom theme's appearance is its `extends` side (the app decides).
    public var appearance: NSAppearance? {
        switch self {
        case .dark, .custom: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

public struct TerminalFontChoice: Sendable, Equatable {
    public var family: String
    public var size: CGFloat
    public init(family: String, size: CGFloat) { self.family = family; self.size = size }
    public static let `default` = TerminalFontChoice(family: "DM Mono", size: 13)
    public static let families = ["DM Mono", "SF Mono", "Menlo"]
    public static let sizes: ClosedRange<CGFloat> = 11...16
    public var font: NSFont {
        family == "SF Mono" ? .monospacedSystemFont(ofSize: size, weight: .regular) : CollieFont.mono(size, family: family)
    }
}

public enum AppearanceKeys {
    public static let theme = "appearance.theme",
                      terminalFamily = "appearance.terminalFamily", terminalSize = "appearance.terminalSize"
    /// `system|pt|en`: the app's own copy of Preferences › Interface › "Idioma", read in `CollieApp.init` before any view.
    public static let language = "collie.language"
}

public struct AppearanceSettings: Equatable {
    public var theme: ThemeSelection
    public var terminalFont: TerminalFontChoice

    public init(theme: ThemeSelection, terminalFont: TerminalFontChoice) {
        self.theme = theme; self.terminalFont = terminalFont
    }

    /// Tolerant read: unknown values fall back to Escuro, DM Mono 13.
    public init(defaults: UserDefaults) {
        theme = defaults.string(forKey: AppearanceKeys.theme).flatMap(ThemeSelection.init(rawValue:)) ?? .dark
        let family = defaults.string(forKey: AppearanceKeys.terminalFamily).flatMap { TerminalFontChoice.families.contains($0) ? $0 : nil } ?? "DM Mono"
        let raw = defaults.double(forKey: AppearanceKeys.terminalSize)
        let size = raw == 0 ? TerminalFontChoice.default.size : min(max(CGFloat(raw).rounded(), TerminalFontChoice.sizes.lowerBound), TerminalFontChoice.sizes.upperBound)
        terminalFont = TerminalFontChoice(family: family, size: size)
    }

    /// Writes the tolerant read back, so the Preferences pickers always find their stored value.
    public static func normalize(_ defaults: UserDefaults) {
        let s = AppearanceSettings(defaults: defaults)
        // only changed keys: an unchanged write still notifies the observers
        for (k, v) in [(AppearanceKeys.theme, s.theme.rawValue),
                       (AppearanceKeys.terminalFamily, s.terminalFont.family)] where defaults.string(forKey: k) != v {
            defaults.set(v, forKey: k)
        }
        let size = Double(s.terminalFont.size)
        if defaults.double(forKey: AppearanceKeys.terminalSize) != size { defaults.set(size, forKey: AppearanceKeys.terminalSize) }
    }
}
