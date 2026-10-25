import Foundation

/// R12: who wrote a terminal's prompt. The app's keyboard (StreamHub) appends what it types/pastes; every write
/// Collie makes for an agent or a workflow (ask, inject: summon, herd roles, rerail, chat delivery) taints the terminal.
/// A prompt is the user's own only when nothing tainted it since the last submit and the app typed exactly it.
final class InputProvenance: @unchecked Sendable {   // state under `lock`
    static let cap = 16 * 1024
    private let lock = NSLock()
    private var typed: [UUID: Data] = [:]
    private var tainted: Set<UUID> = []
    /// The app typed into it since the last submit (a mismatched submit keeps `typed`, not this).
    private var fresh: Set<UUID> = []

    func typed(_ terminal: UUID, _ d: Data) {
        lock.withLock {
            var b = typed[terminal] ?? Data()
            b.append(d)
            typed[terminal] = b.count > Self.cap ? b.suffix(Self.cap) : b
            fresh.insert(terminal)
        }
    }

    /// What the user typed before a Collie write can't be told apart from it: the buffer starts over too.
    func taint(_ terminal: UUID) { lock.withLock { _ = tainted.insert(terminal); typed[terminal] = nil; fresh.remove(terminal) } }
    func isTainted(_ terminal: UUID) -> Bool { lock.withLock { tainted.contains(terminal) } }
    func hasTyped(_ terminal: UUID) -> Bool { lock.withLock { !(typed[terminal]?.isEmpty ?? true) } }   // tests

    /// At a submit: whether `prompt` is what the app typed (and nothing else wrote) since the last one. R22: equal, after
    /// line editing, to the whole buffer or to its last lines (stale lines a mismatched submit left before them); a
    /// fragment of a line never counts. R21: only a match consumes the buffer — another caller's prompt (an agent calling
    /// the hook itself) leaves the user's keystrokes alone. Any submit clears the taint.
    func take(_ terminal: UUID, prompt: String) -> Bool { submit(terminal, prompt: prompt).user }

    /// `take`, plus `likely`: no match, but the app typed into the terminal since the last submit and nothing tainted it
    /// (a history recall, Tab/@ completion, cursor edits, an image paste): very probably the user's — asked, never assumed.
    func submit(_ terminal: UUID, prompt: String) -> (user: Bool, likely: Bool) {
        lock.withLock {
            let wasTainted = tainted.remove(terminal) != nil, wasTyped = fresh.remove(terminal) != nil
            let p = Self.collapse(prompt)
            guard !wasTainted, !p.isEmpty else { return (false, false) }
            let lines = typed[terminal].map { Self.text($0).split(separator: "\n").map { Self.collapse(String($0)) }.filter { !$0.isEmpty } } ?? []
            guard (1...max(1, lines.count)).contains(where: { k in lines.count >= k && lines.suffix(k).joined(separator: " ") == p }) else {
                return (false, wasTyped)
            }
            typed[terminal] = nil
            return (true, false)
        }
    }

    /// Keyboard bytes as the line editor would see them: escape sequences dropped (CSI/SS3; DCS, OSC, APC, PM and SOS
    /// with their payloads up to BEL or ST), backspace/DEL erase a character, Ctrl-W a word, Ctrl-U/Ctrl-C the line,
    /// other controls dropped, Enter is a line break. ponytail: a prompt edited with the cursor keys doesn't match — it
    /// is then only a proposal (the safe side).
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
                } else if i < s.count, "P]_^X".unicodeScalars.contains(s[i]) {   // a string: up to BEL or ESC \
                    i += 1
                    while i < s.count, s[i] != "\u{07}", !(s[i] == "\u{1B}" && i + 1 < s.count && s[i + 1] == "\\") { i += 1 }
                    if i < s.count, s[i] == "\u{1B}" { i += 1 }
                } else if i < s.count, s[i] == "O" { i += 1 }   // SS3: one more byte
                i += 1
                continue
            }
            func eraseLine() { while let c = out.last, c != "\n" { out.removeLast() } }
            if u == "\u{15}" || u == "\u{03}" { eraseLine() }
            else if u == "\u{17}" {
                while let c = out.last, c == " " || c == "\t" { out.removeLast() }
                while let c = out.last, c != " ", c != "\t", c != "\n" { out.removeLast() }
            }
            else if u == "\u{7F}" || u == "\u{08}" { if !out.isEmpty { out.removeLast() } }
            else if u == "\r" || u == "\n" { out.append("\n") }
            else if u == "\t" || u.properties.generalCategory != .control { out.append(u) }
            i += 1
        }
        return String(out)
    }

    static func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
