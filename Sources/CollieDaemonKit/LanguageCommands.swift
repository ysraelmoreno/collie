import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// `admin.language` (app only): nil reads; else `system|pt|en`, saved and live at once (terminals already open keep theirs).
    func setLanguage(_ v: String?) throws -> JSONValue {
        var s = CollieSettings.load(config.paths.root)
        if let v {
            guard let l = LanguageSetting(rawValue: v) else {
                throw ProtocolError(code: .invalidArgs, message: "language must be system, pt or en")
            }
            s.language = l.rawValue
            do { try s.save(config.paths.root) } catch { throw ProtocolError(code: .internal, message: "preferences.json: \(error)") }
            language = Lang.resolve(l)
            if config.setsProcessLanguage { L10n.set(language) }
        }
        return .object(["language": .string(LanguageSetting.parse(s.language).rawValue), "active": .string(language.rawValue)])
    }
}

/// For the CLI (a separate module): the saved `language` of `<root>/preferences.json`; nil when unset or unreadable.
public enum LanguagePreference {
    public static func saved(root: URL) -> String? { CollieSettings.load(root).language }
}
