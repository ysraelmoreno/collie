import Foundation
import CollieCore

/// Item 2 phase 1: which of `records` (a turn's pending memories, ≤ 5) the agent's last message names — its short id (8
/// hex, not part of a longer hex run) or its title (normalized, ≥ 3 words, whole words). Pure; only the first `maxBytes`
/// of the message are read and none of it is kept.
enum UseEvidence {
    static let maxBytes = 64 * 1024, minTitleWords = 3

    static func cited(message: String, records: [MemoryRecord]) -> Set<UUID> {
        let text = String(decoding: message.utf8.prefix(maxBytes), as: UTF8.self)
        let lower = text.lowercased(), words = " " + normalized(text) + " "
        var out: Set<UUID> = []
        for r in records {
            if hasId(String(r.id.uuidString.lowercased().prefix(8)), in: lower) { out.insert(r.id); continue }
            let t = normalized(r.title)
            if t.split(separator: " ").count >= minTitleWords, words.contains(" " + t + " ") { out.insert(r.id) }
        }
        return out
    }

    /// Lowercased, without diacritics, every run of non-alphanumerics one space.
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static func hasId(_ id: String, in s: String) -> Bool {
        var from = s.startIndex
        while let r = s.range(of: id, range: from..<s.endIndex) {
            let before = r.lowerBound == s.startIndex ? nil : s[s.index(before: r.lowerBound)]
            let after = r.upperBound == s.endIndex ? nil : s[r.upperBound]
            if before?.isHexDigit != true, after?.isHexDigit != true { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }
}
