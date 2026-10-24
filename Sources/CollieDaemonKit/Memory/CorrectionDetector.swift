import Foundation

/// A cheap, synchronous guess that a prompt corrects the agent (pt/en). Conservative: a missed correction costs less
/// than a false rule. R14: a pattern counts only in the first sentence (up to the first . ! ? or line break, 60
/// characters at most); prompts over 600 characters (pasted logs, long briefs) never count; a bare "não"/"no" counts when
/// the agent's last turn asked something.
enum CorrectionDetector {
    static let maxPrompt = 600
    /// Word-bounded, case- and accent-insensitive (matched on the folded text). `remove`/`desfaz`/`undo` only with a
    /// pronoun object: "remove o arquivo" is an order, not a correction.
    private static let head = #"(^|[^\p{L}\p{N}])(nao[,.!]|no[,.!]|na verdade|pare de |para de |nunca |errado|de novo|ja falei|eu disse|nao era isso|(desfaz|desfaca|remove|tira) (isso|isto|aquilo)|stop |wrong|actually|undo (that|it|this)|i said|i told you|not that)"#
    private static let anywhere = #"(^|[^\p{L}\p{N}])(eu disse|ja falei|nao era isso|that'?s wrong|i told you)([^\p{L}\p{N}]|$)"#

    static func isCorrection(_ prompt: String, lastTurn: String?) -> Bool {
        guard prompt.count <= maxPrompt else { return false }
        let p = fold(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if ["nao", "no", "nope"].contains(p.trimmingCharacters(in: .punctuationCharacters)),
           lastTurn?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") == true { return true }
        let head60 = p.prefix(60)
        let end = head60.firstIndex { ".!?\n".contains($0) }.map { head60.index(after: $0) } ?? head60.endIndex
        let first = String(head60[..<end])   // with its terminator: "não." still matches
        return first.range(of: head, options: .regularExpression) != nil || first.range(of: anywhere, options: .regularExpression) != nil
    }

    /// R24: the user's words carry a rule of their own (≥ 6 distinct meaningful words); else (a bare "não", "não, use X")
    /// the rule's substance would come from the agent's last turn, so the result may only be proposed.
    /// ponytail: a word count, not a semantic check; negation words count only once each, so "nope nope…" is one word.
    static let minOwnWords = 6
    static func hasOwnRule(_ prompt: String) -> Bool {
        Set(MemoryService.significantTerms(prompt).map { fold($0) }).count >= minOwnWords
    }

    /// The user states a how-to: "sempre que X, faça Y", "toda vez que X, …", "whenever X, …" — the trigger starts in the
    /// first 60 characters and a comma then a word follows it; "sempre que possível/puder/der" is not one. Same 600 cap.
    private static let procedure = #"(^|[^\p{L}\p{N}])(sempre que|toda vez que|todas as vezes que|cada vez que|whenever|every time)\s+(?!(possivel|puder|der|possible|you can)([^\p{L}\p{N}]|$))[^,.!?\n]{2,160},\s*[\p{L}\p{N}]"#
    static func isProcedure(_ prompt: String) -> Bool {
        guard prompt.count <= maxPrompt else { return false }
        let p = fold(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = p.range(of: procedure, options: .regularExpression) else { return false }
        return p.distance(from: p.startIndex, to: r.lowerBound) < 60
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
