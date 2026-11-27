import Foundation
import CryptoKit
import CollieCore

/// Pure tier and lifetime rules; state lives in `LifecycleStore`.
enum LifecycleRules {
    /// How long a provisional memory lives with no useful use, by kind. Pitfalls and procedures are rarely used and
    /// costly to lose, so they get longer. The user's feedback has none (out of the cycle).
    static func ttl(_ k: MemoryKind) -> TimeInterval? {
        switch k {
        case .decision, .map: 21 * 86_400
        case .pitfall, .procedure: 60 * 86_400
        case .feedback: nil
        }
    }
    private static func kindLabel(_ k: MemoryKind) -> String {
        switch k {
        case .decision: tr("decisão", "decision")
        case .map: tr("mapa", "map")
        case .pitfall: tr("armadilha", "pitfall")
        case .procedure: tr("procedimento", "procedure")
        case .feedback: "feedback"
        }
    }
    static let earnedUses = 2, earnedDays = 2, earnedSessions = 2
    static let longTermUses = 8, longTermDays = 4
    static let longTermSpan: TimeInterval = 14 * 86_400, contestedWindow: TimeInterval = 30 * 86_400
    static let maxLongTermPerProject = 12, maxLongTermInjected = 3, maxLongTermInjectedBytes = 600
    static let flagPenalty = -0.3, maxFlagsPerSession = 20
    static let verifyCooldown: TimeInterval = 14 * 86_400, maxGatesPerDay = 3
    /// Contested this long with no verdict: "Precisa de você".
    static let contestedAskAfter: TimeInterval = 14 * 86_400
    static let maxClaimContestsPerPass = 10

    static func eligible(_ r: MemoryRecord) -> Bool {
        r.scope == .project && r.status == .active && !r.pinned && !r.reviewed
    }

    /// SHA-256 hex of the record's title and body: the text a tier was given for.
    static func textHash(_ r: MemoryRecord) -> String {
        SHA256.hash(data: Data((r.title + "\n" + r.body).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `e` as it holds for `r`: an earned/longTerm tier counts only for the text it was given for (`textHash`); another
    /// text (edited, or a copied id) starts over (provisional, no uses). Never by store: the same record lives in the
    /// pasture and every paddock worktree. Feed the result to `tier(for:)`; the lifecycle pass stores it.
    static func effective(_ e: LifecycleEntry, _ r: MemoryRecord) -> LifecycleEntry {
        guard e.tier != .provisional, let h = e.textHash, h != textHash(r) else { return e }
        var x = e
        x.tier = .provisional; x.usefulUses = []; x.evidencedUses = nil; x.textHash = nil; x.earnedBy = nil
        return x
    }

    /// provisional → earned (ma3): 2 uses on 2 days by 2 sessions, at least one of them with evidence (cite, `memory get`,
    /// `flag --useful`), and no open contest nor wrong/outdated flag. Implicit uses alone stay provisional. An entry
    /// already stored earned keeps it (no mass demotion: the rule is for new promotions); the pass writes `earnedBy`.
    static func tier(for e: LifecycleEntry, now: Date) -> LifecycleTier {
        if e.tier == .longTerm { return e.contestedNow ? .earned : .longTerm }
        guard e.tier == .provisional, !contested(e) else { return e.tier }
        let u = e.usefulUses
        return u.count >= earnedUses && Set(u.map(\.day)).count >= earnedDays && Set(u.map(\.session)).count >= earnedSessions
            && !(e.evidencedUses ?? []).intersection(u).isEmpty
            ? .earned : .provisional
    }

    /// Needs a tier that is not provisional, so the mass promotion by "vacuous use" (implicit uses only) is barred by `tier`.
    static func promotionCandidate(_ e: LifecycleEntry, now: Date) -> Bool {
        guard e.tier != .longTerm, !e.contestedNow, e.usefulUses.count >= longTermUses else { return false }
        if let c = e.lastContestedAt, now.timeIntervalSince(c) < contestedWindow { return false }
        let days = Set(e.usefulUses.map(\.day)).compactMap(date).sorted()
        guard days.count >= longTermDays, let f = days.first, let l = days.last else { return false }
        return l.timeIntervalSince(f) >= longTermSpan && tier(for: e, now: now) != .provisional
    }

    static func unusedPlan(records: [MemoryRecord], entries: [UUID: LifecycleEntry], now: Date) -> [CleanupItem] {
        records.compactMap { r in
            // B3.5: enforced is never injected, so it can never earn a use: no TTL while a check speaks for it
            guard r.enforcedBy == nil, eligible(r), let ttl = ttl(r.kind), let e = entries[r.id], tier(for: e, now: now) == .provisional else { return nil }
            let last = max(e.tierSince, e.usefulUses.compactMap { date($0.day) }.max() ?? .distantPast)
            let age = now.timeIntervalSince(last)
            guard age >= ttl else { return nil }
            return CleanupItem(action: .archiveUnused, id: r.id, into: nil,
                               reason: tr("provisória sem uso há \(Int((age / 86_400).rounded(.down))) dias (prazo de \(kindLabel(r.kind)): \(Int(ttl / 86_400)))",
                                          "provisional and unused for \(Int((age / 86_400).rounded(.down))) days (\(kindLabel(r.kind)) limit: \(Int(ttl / 86_400)))"))
        }
    }

    /// Blocks earning: a live contest or an open wrong/outdated flag. A past contest (`lastContestedAt`) only gates promotion.
    private static func contested(_ e: LifecycleEntry) -> Bool {
        e.contestedNow || e.flags.contains { $0.verdict != .useful }
    }

    private static func date(_ day: String) -> Date? {
        dayFormatter.date(from: day)
    }
    /// The one `yyyy-MM-dd` formatter of the Memory module (lifecycle days, use keys).
    nonisolated(unsafe) static let dayFormatter: ISO8601DateFormatter = {   // UTC; read-only after init
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f
    }()
}
