import Foundation

/// A4: the answer of a Cursor turn out of its rendered screen (`ScreenRenderer`), without Ink's fixed frame.
/// Cursor draws the prompt it was sent as a block padded with spaces, then the answer, then the input bar
/// (`→ Add a follow-up`, between two padded lines) and a footer (model, mode, path).
enum CursorScreen {
    private struct Parts { var answer: [String]; var echoSeen: Bool }

    private static func isPad(_ l: String) -> Bool { !l.isEmpty && l.allSatisfy { $0 == " " } }

    private static func parts(_ screen: String) -> Parts {
        var lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // the frame: from the bar down (the bar is the last line that starts with the arrow)
        if let bar = lines.lastIndex(where: { $0.drop(while: { $0 == " " }).hasPrefix("→ ") }) { lines.removeSubrange(bar...) }
        while let l = lines.last, l.allSatisfy({ $0 == " " }) { lines.removeLast() }
        // the echo of the sent prompt: the answer starts after its closing padded line
        let echo = lines.lastIndex(where: isPad)
        if let echo { lines.removeSubrange(...echo) }
        return Parts(answer: lines, echoSeen: echo != nil)
    }

    /// Only the answer: no echo of the prompt, input bar or footer; trailing blanks and the 2-column margin gone.
    static func answer(_ screen: String) -> String {
        var l = parts(screen).answer.map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }
        let margin = l.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("  ") }
        if margin { l = l.map { String($0.dropFirst(min(2, $0.prefix(while: { $0 == " " }).count))) } }
        while l.first?.isEmpty == true { l.removeFirst() }
        while l.last?.isEmpty == true { l.removeLast() }
        return l.joined(separator: "\n")
    }

    /// The screen shows only the end of the answer: the echo of the prompt scrolled off.
    static func isCut(_ screen: String) -> Bool {
        let p = parts(screen)
        return !p.echoSeen && !p.answer.isEmpty
    }
}
