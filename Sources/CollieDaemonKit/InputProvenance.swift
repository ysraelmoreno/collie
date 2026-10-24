import Foundation

/// R12: who wrote a terminal's prompt. The app's keyboard (StreamHub) appends what it types/pastes; every write
/// Collie makes for an agent or a workflow (ask, inject: summon, herd roles, rerail, chat delivery) taints the terminal.
/// A prompt is the user's own only when nothing tainted it since the last submit and the app typed exactly it.
final class InputProvenance: @unchecked Sendable {   // state under `lock`
    static let cap = 16 * 1024
    private let lock = NSLock()
    private var typed: [UUID: Data] = [:]
    private var tainted: Set<UUID> = []

    func typed(_ terminal: UUID, _ d: Data) {
        lock.withLock {
            var b = typed[terminal] ?? Data()
            b.append(d)
            typed[terminal] = b.count > Self.cap ? b.suffix(Self.cap) : b
        }
    }

    func taint(_ terminal: UUID) { _ = lock.withLock { tainted.insert(terminal) } }
    func isTainted(_ terminal: UUID) -> Bool { lock.withLock { tainted.contains(terminal) } }

    /// At a submit: whether `prompt` is what the app typed (and nothing else wrote) since the last one; starts over.
    func take(_ terminal: UUID, prompt: String) -> Bool {
        let (d, t) = lock.withLock { (typed.removeValue(forKey: terminal) ?? Data(), tainted.remove(terminal) != nil) }
        let p = Self.collapse(prompt)
        return !t && !p.isEmpty && Self.collapse(Self.text(d)).contains(p)
    }

    /// Keyboard bytes as the line editor would see them: escape sequences (arrows, bracketed-paste marks) dropped,
    /// backspace/DEL erase, other controls dropped, Enter is a line break. ponytail: a prompt edited with the cursor
    /// keys doesn't match — it is then only a proposal (the safe side).
    static func text(_ d: Data) -> String {
        var out = String.UnicodeScalarView()
        let s = Array(String(decoding: d, as: UTF8.self).unicodeScalars)
        var i = 0
        while i < s.count {
            let u = s[i]
            if u == "\u{1B}" {
                i += 1
                if i < s.count, s[i] == "[" {   // CSI: parameters, then a final byte @…~
                    i += 1
                    while i < s.count, !(0x40...0x7E).contains(s[i].value) { i += 1 }
                } else if i < s.count, s[i] == "O" { i += 1 }   // SS3: one more byte
                i += 1
                continue
            }
            if u == "\u{7F}" || u == "\u{08}" { if !out.isEmpty { out.removeLast() } }
            else if u == "\r" || u == "\n" { out.append("\n") }
            else if u == "\t" || u.properties.generalCategory != .control { out.append(u) }
            i += 1
        }
        return String(out)
    }

    static func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
