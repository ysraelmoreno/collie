import Foundation

/// claude.ai artifact links, as the daemon's `artifact import-claude` and the app's import sheet take them.
public enum ClaudeLinks {
    public static let maxPerImport = 50

    /// `https://claude.ai/artifact/<id>` or `https://claude.ai/code/artifact/<uuid>`, exactly (no query, port, user).
    public static func isLink(_ s: String) -> Bool {
        s.wholeMatch(of: /https:\/\/claude\.ai\/artifact\/[A-Za-z0-9_-]{1,128}/) != nil
            || s.wholeMatch(of: /https:\/\/claude\.ai\/code\/artifact\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) != nil
    }

    /// The words of `text` (split on spaces, lines and commas; a trailing `/` dropped): the links, each once, in order,
    /// and the words that are not one.
    public static func split(_ text: String) -> (links: [String], bad: [String]) {
        var links: [String] = [], bad: [String] = []
        for w in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let s = w.hasSuffix("/") ? String(w.dropLast()) : String(w)
            if !isLink(s) { bad.append(s) } else if !links.contains(s) { links.append(s) }
        }
        return (links, bad)
    }
}
