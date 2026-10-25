import Foundation

/// A paddock name the daemon accepts (`^[a-z0-9][a-z0-9-]{0,39}$`), from whatever the user typed.
public enum PaddockName {
    /// "ShowOn" → "showon", "Meu Cercado_2" → "meu-cercado-2", "  ação!! " → "acao"; nil when nothing usable is left.
    public static func slug(_ typed: String) -> String? {
        let folded = typed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = "", dash = false
        for u in folded.unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) { out.unicodeScalars.append(u); dash = false }
            else if !out.isEmpty, !dash { out.append("-"); dash = true }
        }
        let s = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? nil : s
    }
}
