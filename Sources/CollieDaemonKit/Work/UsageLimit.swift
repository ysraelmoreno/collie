import Foundation

/// M5.3: Claude Code's usage-limit dialog ("You've hit your … limit · resets …" and the menu "Stop and wait for limit
/// to reset") seen on the last non-empty lines of an agent's screen. Nothing is ever typed into it: the loop only reads.
enum UsageLimit {
    static let excerptMax = 80
    /// The menu's option is among the last `menuWithin` lines, the limit line among the `limitWithin` above it.
    static let menuWithin = 6, limitWithin = 8

    /// The dialog's limit line (`excerpt`), when `lines` end in the dialog and the agent printed nothing lately
    /// (`quiet`); nil otherwise. The agent writing about the limit is followed by its input box and footer, never only
    /// by the dialog's other options and hints.
    // ponytail: text heuristics on the screen's tail; a footer-less screen whose agent's last words are the menu would
    // match, but only after the turn hung quiet with no Stop hook
    static func detect(_ lines: [String], quiet: Bool) -> String? {
        guard quiet else { return nil }
        let tail = Array(lines.suffix(menuWithin))
        guard let m = tail.lastIndex(where: { trimmed($0).wholeMatch(of: menu) != nil }),
              tail[(m + 1)...].allSatisfy({ after($0) }) else { return nil }
        let at = lines.count - tail.count + m
        let above = lines[max(0, at - limitWithin)..<at]
        return above.last { $0.firstMatch(of: limit) != nil }.map { excerpt(trimmed($0)) }
    }

    /// Text read from a screen made data: no escape sequence nor control character, one line, at most `excerptMax`.
    static func excerpt(_ s: String) -> String {
        let plain = s.replacing(csi, with: "")
        let clean = String(String.UnicodeScalarView(plain.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let one = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count <= excerptMax ? one : String(one.prefix(excerptMax - 1)) + "…"
    }

    // computed: `Regex` is not Sendable
    private static var menu: Regex<(Substring, Substring?)> { /(?i)(\d+\.\s*)?stop and wait for limit to reset/ }
    private static var limit: Regex<Substring> { /(?i)hit your .*limit|usage limit|limit reached/ }
    private static var csi: Regex<Substring> { /\x{1B}\[[0-9;?]*[ -\/]*[@-~]/ }
    /// Box borders and the menu's cursor around a line.
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t│┃|❯›⎿")) }
    /// What may follow the menu's option in the dialog: other options, its hints, borders.
    private static func after(_ s: String) -> Bool {
        let t = trimmed(s)
        return t.allSatisfy { "─━╭╮╰╯".contains($0) } || t.firstMatch(of: /^\d+\.\s/) != nil || t.lowercased().contains("esc to") || t.lowercased().contains("enter to")
    }
}
