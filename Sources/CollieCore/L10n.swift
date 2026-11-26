import Foundation
import Synchronization

/// The language Collie speaks (spec 2026-11-26 idiomas). Both texts sit side by side at the call site: `tr("pt", "en")`.
public enum Lang: String, Sendable, CaseIterable { case pt, en }

/// `CollieSettings.language` / Preferences › Interface › "Idioma". Nil or unknown is `.system`.
public enum LanguageSetting: String, Sendable, CaseIterable {
    case system, pt, en
    public static func parse(_ s: String?) -> LanguageSetting { s.flatMap(LanguageSetting.init(rawValue:)) ?? .system }
}

public extension Lang {
    /// `.system`: a Mac in any Portuguese is pt, anything else en.
    static func resolve(_ s: LanguageSetting, preferred: [String] = Locale.preferredLanguages) -> Lang {
        switch s {
        case .pt: .pt
        case .en: .en
        case .system: preferred.first?.lowercased().hasPrefix("pt") == true ? .pt : .en
        }
    }
    /// The CLI: `COLLIE_LANG` (set by the daemon in every terminal; the sandbox hides preferences.json) wins, then the file.
    static func forCLI(env: [String: String], setting: String?, preferred: [String]) -> Lang {
        env["COLLIE_LANG"].flatMap(Lang.init(rawValue:)) ?? resolve(.parse(setting), preferred: preferred)
    }
}

public enum L10n {
    private static let state = Mutex<Lang>(.pt)
    /// Per task (tests): wins over the process language.
    @TaskLocal public static var override: Lang?
    public static var current: Lang { override ?? state.withLock { $0 } }
    public static func set(_ l: Lang) { state.withLock { $0 = l } }
}

/// The text in the active language. Interpolate whole sentences in each language; never glue translated pieces.
public func tr(_ pt: String, _ en: String) -> String { L10n.current == .en ? en : pt }
