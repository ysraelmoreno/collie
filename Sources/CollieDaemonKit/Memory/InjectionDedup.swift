import Foundation
import CollieCore

/// M10.4: near-duplicate memories never enter one injection block together (checklist, relevant, focus). Before the
/// byte budget cuts, candidates are grouped and only the best of each group is injected; the others count as seen in the
/// session (they don't come back) and as `collapsed` in `memory stats`. Selection only: nothing in the store changes
/// (the consolidation is what really merges).
enum InjectionDedup {
    /// Two memories of the same kind and scope are near when they have the same normalized `subject`, or their title terms
    /// (`MemoryService.significantTerms`, lowercased) have a Jaccard ≥ `titleMin` (the consolidation's `clusterMin`), or —
    /// both with a stored vector of the same language and size — a cosine ≥ `vectorMin`. No vector: subject and title only.
    static let titleMin = 0.5, vectorMin = 0.92

    typealias Vectors = [UUID: (lang: String, vector: [Float])]

    static func titleTerms(_ r: MemoryRecord) -> Set<String> { Set(MemoryService.significantTerms(r.title).map { $0.lowercased() }) }

    static func near(_ a: MemoryRecord, _ b: MemoryRecord, vectors: Vectors = [:]) -> Bool {
        guard a.kind == b.kind, a.scope == b.scope else { return false }   // a decision and a pitfall on one subject are not copies
        if a.subject == b.subject { return true }
        let ta = titleTerms(a), tb = titleTerms(b), u = ta.union(tb).count
        if u > 0, ta.intersection(tb).count >= 3, Double(ta.intersection(tb).count) / Double(u) >= titleMin { return true }   // short titles share 2 terms by chance
        guard let x = vectors[a.id], let y = vectors[b.id], x.lang == y.lang, x.vector.count == y.vector.count else { return false }
        var dot = 0.0, nx = 0.0, ny = 0.0
        for i in x.vector.indices {
            let p = Double(x.vector[i]), q = Double(y.vector[i])
            dot += p * q; nx += p * p; ny += q * q
        }
        return nx > 0 && ny > 0 && dot / (nx * ny).squareRoot() >= vectorMin
    }

    /// `recs` ordered best first: highest `score`, then the newest, then the most confirmations (`hits`). Each one near a
    /// kept memory (or one of `against`, already in another section of the block) is collapsed `by` it; the rest are kept
    /// in that order. ponytail: greedy against kept ones only (A~B, B~C, A≁C keeps A and C); O(n²) over ≤ 50 candidates.
    static func collapse(_ recs: [MemoryRecord], score: (MemoryRecord) -> Double, vectors: Vectors = [:],
                         against: [MemoryRecord] = []) -> (kept: [MemoryRecord], collapsed: [(record: MemoryRecord, by: UUID)]) {
        let ordered = recs.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            let (sx, sy) = (score(x), score(y))
            if sx != sy { return sx > sy }
            if x.updatedAt != y.updatedAt { return x.updatedAt > y.updatedAt }
            if (x.hits ?? 0) != (y.hits ?? 0) { return (x.hits ?? 0) > (y.hits ?? 0) }
            return a.offset < b.offset
        }.map(\.element)
        var kept: [MemoryRecord] = [], collapsed: [(record: MemoryRecord, by: UUID)] = []
        for r in ordered {
            if let rep = (against + kept).first(where: { near(r, $0, vectors: vectors) }) { collapsed.append((r, rep.id)) } else { kept.append(r) }
        }
        return (kept, collapsed)
    }
}
