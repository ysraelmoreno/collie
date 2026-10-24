import Foundation

/// A cheap, synchronous guess that a prompt corrects the agent (pt/en). Conservative: a missed correction costs less
/// than a false rule. A pattern counts in the first 60 characters, an explicit phrase anywhere; prompts over 2 000
/// characters (pasted logs) never count; a bare "não"/"no" counts when the agent's last turn asked something.
enum CorrectionDetector {
    static let maxPrompt = 2_000
    /// Word-bounded, case- and accent-insensitive (matched on the folded text). `remove`/`desfaz`/`undo` only with a
    /// pronoun object: "remove o arquivo" is an order, not a correction.
    private static let head = #"(^|[^\p{L}\p{N}])(nao[,.!]|no[,.!]|na verdade|pare de |para de |nunca |errado|de novo|ja falei|eu disse|nao era isso|(desfaz|desfaca|remove|tira) (isso|isto|aquilo)|stop |wrong|actually|undo (that|it|this)|i said|i told you|not that)"#
    private static let anywhere = #"(^|[^\p{L}\p{N}])(eu disse|ja falei|nao era isso|that'?s wrong|i told you)([^\p{L}\p{N}]|$)"#

    static func isCorrection(_ prompt: String, lastTurn: String?) -> Bool {
        guard prompt.count <= maxPrompt else { return false }
        let p = fold(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if ["nao", "no", "nope"].contains(p.trimmingCharacters(in: .punctuationCharacters)),
           lastTurn?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") == true { return true }
        return String(p.prefix(60)).range(of: head, options: .regularExpression) != nil
            || p.range(of: anywhere, options: .regularExpression) != nil
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
