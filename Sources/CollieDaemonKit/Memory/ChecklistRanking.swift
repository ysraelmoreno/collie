import Foundation
import CollieCore

/// What the session at hand is about, as one short text: the query that ranks the start-of-session pitfall checklist.
enum ChecklistFocus {
    static let maxChars = 600
    /// Branch prefixes and trunk names say nothing about the work.
    private static let genericBranchWords: Set<String> = ["feat", "fix", "spike", "docs", "chore", "collie", "main", "master", "wip"]

    static func build(branch: String?, workTitle: String?, openTasks: [String] = [], commitSubjects: [String] = [], paths: [String] = [],
                      paddock: String? = nil, lotGoal: String? = nil) -> String {
        var parts: [String] = []
        if let branch {
            parts.append(words(branch, [ "/", "-", "_", "." ]).filter { !genericBranchWords.contains($0.lowercased()) }.joined(separator: " "))
        }
        if let workTitle { parts.append(workTitle) }
        parts += openTasks.prefix(5)
        parts += commitSubjects.prefix(5)
        var seen = Set<String>()
        for p in paths.prefix(15) {
            let tail = p.split(separator: "/").suffix(2).map(String.init).joined(separator: " ")
            let w = words(tail, ["/", "-", "_", "."]).joined(separator: " ")
            if !w.isEmpty, seen.insert(w).inserted { parts.append(w) }
        }
        if let paddock { parts.append(paddock) }
        if let lotGoal { parts.append(lotGoal) }
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(text.prefix(maxChars))
    }

    private static func words(_ s: String, _ separators: [Character]) -> [String] {
        s.split { separators.contains($0) || $0.isWhitespace }.map(String.init)
    }
}

/// The start-of-session checklist: the pitfalls most relevant to the focus first, the old hit rank for the rest.
enum ChecklistRanking {
    /// Relevance slots and the share of the best score a pitfall needs to take one.
    static let relevantSlots = 4, minRelative = 0.4

    /// `recs`: the candidate pitfalls. `relevance`: score per id from the focus search (empty: no focus, no signal).
    /// `hitRank`: the old `hits × recency × score`. Pitfalls about another platform than the focus names are dropped from
    /// both parts (none named: any platform may fill). At most `max`, no repeats.
    static func pick(_ recs: [MemoryRecord], relevance: [UUID: Double], focus: String, max: Int, hitRank: (MemoryRecord) -> Double) -> [MemoryRecord] {
        let asked = MemoryService.platforms(focus)
        func otherPlatform(_ r: MemoryRecord) -> Bool {
            guard !asked.isEmpty else { return false }
            let p = MemoryService.platforms(r.title + " " + r.subject + " " + r.body)
            return !p.isEmpty && p.isDisjoint(with: asked)
        }
        var out: [MemoryRecord] = []
        if let top = relevance.values.max(), top > 0 {
            let near = recs.filter { (relevance[$0.id] ?? 0) >= top * minRelative && !otherPlatform($0) }
                .sorted { (relevance[$0.id] ?? 0, $0.updatedAt) > (relevance[$1.id] ?? 0, $1.updatedAt) }
            out = Array(near.prefix(Swift.min(relevantSlots, max)))
        }
        for r in recs.sorted(by: { (hitRank($0), $0.updatedAt) > (hitRank($1), $1.updatedAt) }) where out.count < max {
            if !out.contains(where: { $0.id == r.id }) && !otherPlatform(r) { out.append(r) }
        }
        return out
    }
}
