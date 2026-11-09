import Foundation

/// A numbered option of a Claude dialog (permission or AskUserQuestion), read from the screen the approval captured.
public struct ApprovalOption: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var label: String
    public var id: Int { number }
    public init(number: Int, label: String) { self.number = number; self.label = label }
    /// "Yes, and don't ask again…" / "…during this session": the chat's "nesta sessão".
    public var isSession: Bool {
        let l = label.lowercased()
        return l.hasPrefix("yes") && (l.contains("don't ask again") || l.contains("do not ask again") || l.contains("this session") || l.contains("allow all"))
    }
    public var isNo: Bool { label.lowercased().hasPrefix("no") }
}

extension Approval {
    /// `AttentionDetector.claudeQuestion`: the reason of an AskUserQuestion dialog.
    public static let questionReason = "chat about this"

    public var isQuestion: Bool { reason == Self.questionReason }

    /// The options the chat may click: a permission menu's, or a single-choice question's. Empty: answer in the terminal
    /// (trust folder, other kinds, a multi-select question, or a screen whose options cannot be read).
    public var options: [ApprovalOption] {
        guard kind == .menu || (kind == .unknown && isQuestion) else { return [] }
        let all = Self.parseOptions(prompt)
        guard isQuestion else { return all }
        let low = prompt.lowercased()
        if low.contains("space to select") || low.contains("☐") || low.contains("[ ]") { return [] }   // multi-select: toggles, not picks
        // "Type something" / "Chat about this" open a text input: the next keys would be typed, never sent from the chat
        return all.filter { o in let l = o.label.lowercased(); return !l.hasPrefix("type something") && !l.hasPrefix("chat about this") }
    }

    /// The question (or the command asked about): the screen above the first option, last 6 non-empty lines.
    public var question: String {
        var head: [String] = []
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            if Self.optionLine(String(line)) != nil { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { head.append(t) }
        }
        return head.suffix(6).joined(separator: "\n")
    }

    static func optionLine(_ line: String) -> ApprovalOption? {
        guard let m = line.firstMatch(of: /^[\s│|]*(?:❯|>)?\s*(\d{1,2})\.\s+(\S.*?)\s*$/), let n = Int(m.1) else { return nil }
        return ApprovalOption(number: n, label: String(m.2))
    }

    /// The last run of consecutive options 1, 2, 3… on the screen (an older dialog's above it does not count).
    static func parseOptions(_ prompt: String) -> [ApprovalOption] {
        var run: [ApprovalOption] = []
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let o = optionLine(String(line)) else { continue }
            if o.number == 1 { run = [o] } else if o.number == run.count + 1 { run.append(o) }
        }
        return run.filter { $0.number <= 9 }   // one key each
    }
}
