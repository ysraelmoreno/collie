import Foundation

/// A status question the registry answers for free. The panel buttons send exactly the first phrase of each.
public enum StatusQuestion: String, Codable, Sendable, Equatable {
    case whereAreWe, whatIsStuck, whatIsRunning, summary

    private static let phrases: [(StatusQuestion, [String])] = [
        (.whereAreWe, ["onde estamos", "status", "como esta", "como estamos"]),
        (.whatIsStuck, ["o que travou", "o que esta travado", "travou", "o que falta"]),
        (.whatIsRunning, ["o que esta rodando", "o que roda", "rodando"]),
        (.summary, ["resumo", "o que foi feito"]),
    ]

    private static let fillers = ["agora", "ai", "entao", "por favor", "pf", "me diz", "hoje"]

    /// Only a message that is exactly a known phrase (plus trailing filler words, ≤ 40 normalized characters) counts;
    /// anything else may be an instruction and goes to the agent untouched.
    public static func match(_ text: String) -> StatusQuestion? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var words = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
        guard words.count <= 40 else { return nil }
        while let f = fillers.first(where: { words.hasSuffix(" " + $0) }) { words.removeLast(f.count + 1) }
        return phrases.first { $0.1.contains(words) }?.0
    }
}

/// Who wrote a chat message: `orq` is the registry's status answers and notices (no tokens spent).
public enum ChatRole: String, Codable, Sendable, Equatable { case user, agent, orq }

/// One line of the work chat (`work.chat.*`).
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public static let maxText = 8_000
    public var id: UUID
    public var at: Date
    public var role: ChatRole
    public var workId: UUID?
    /// The agent's name, for user→agent and agent→user messages.
    public var terminal: String?
    /// At most `maxText` characters; a longer text is cut and `truncated` set.
    public var text: String
    public var truncated: Bool
    public var replyTo: UUID?
    public init(id: UUID = UUID(), at: Date = Date(), role: ChatRole, workId: UUID? = nil, terminal: String? = nil,
                text: String, replyTo: UUID? = nil) {
        self.id = id; self.at = at; self.role = role; self.workId = workId; self.terminal = terminal; self.replyTo = replyTo
        self.truncated = text.count > Self.maxText
        self.text = truncated ? String(text.prefix(Self.maxText)) : text
    }
}

/// How an approval prompt is answered: `yesNo` "(y/n)"/"[y/n]", `menu` Claude Code's numbered dialogs ("1" = "Yes";
/// Esc = "No"), `enter` "press enter". `unknown`: too much output to check, nothing is ever typed — the user looks at the
/// terminal (only their own keys clear it).
public enum ApprovalKind: String, Codable, Sendable, Equatable { case yesNo, menu, enter, unknown }

/// An agent's prompt waiting for the user (`work.approvals`). `prompt` is the screen captured when it appeared: an approval
/// is written only while that text is still the terminal's pending prompt.
public struct Approval: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var terminalId: UUID
    public var terminal: String
    public var kind: ApprovalKind
    /// What was matched: the pattern, Claude's question, or the hook's message.
    public var reason: String
    /// The last 15 non-empty lines of the screen (ANSI stripped).
    public var prompt: String
    public var at: Date
    public init(id: UUID = UUID(), terminalId: UUID, terminal: String, kind: ApprovalKind, reason: String, prompt: String, at: Date = Date()) {
        self.id = id; self.terminalId = terminalId; self.terminal = terminal; self.kind = kind; self.reason = reason
        self.prompt = prompt; self.at = at
    }
}
