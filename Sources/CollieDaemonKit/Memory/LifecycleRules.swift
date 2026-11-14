import Foundation
import CryptoKit
import CollieCore

/// Pure tier and lifetime rules; state lives in `LifecycleStore`.
enum LifecycleRules {
    static let provisionalTTL: TimeInterval = 21 * 86_400
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

    /// `e` as it holds for `r` read from store `store` (nil: unknown): a tier counts only in the store that earned it and,
    /// earned/longTerm, for the text it was given for (`textHash`); otherwise the memory starts over (provisional, no uses).
    /// Feed the result to `tier(for:)`; the lifecycle pass stores it.
    static func effective(_ e: LifecycleEntry, _ r: MemoryRecord, store: String?) -> LifecycleEntry {
        let otherStore = store != nil && e.store != nil && e.store != store
        let otherText = e.tier != .provisional && e.textHash.map { $0 != textHash(r) } == true
        guard otherStore || otherText else { return e }
        var x = e
        x.tier = .provisional; x.usefulUses = []; x.textHash = nil
        return x
    }

    static func tier(for e: LifecycleEntry, now: Date) -> LifecycleTier {
        if e.tier == .longTerm { return e.contestedNow ? .earned : .longTerm }
        guard e.tier == .provisional, !contested(e) else { return e.tier }
        let u = e.usefulUses
        return u.count >= earnedUses && Set(u.map(\.day)).count >= earnedDays && Set(u.map(\.session)).count >= earnedSessions
            ? .earned : .provisional
    }

    static func promotionCandidate(_ e: LifecycleEntry, now: Date) -> Bool {
        guard e.tier != .longTerm, !e.contestedNow, e.usefulUses.count >= longTermUses else { return false }
        if let c = e.lastContestedAt, now.timeIntervalSince(c) < contestedWindow { return false }
        let days = Set(e.usefulUses.map(\.day)).compactMap(date).sorted()
        guard days.count >= longTermDays, let f = days.first, let l = days.last else { return false }
        return l.timeIntervalSince(f) >= longTermSpan && tier(for: e, now: now) != .provisional
    }

    static func unusedPlan(records: [MemoryRecord], entries: [UUID: LifecycleEntry], now: Date) -> [CleanupItem] {
        records.compactMap { r in
            guard eligible(r), let e = entries[r.id], tier(for: e, now: now) == .provisional else { return nil }
            let last = max(e.tierSince, e.usefulUses.compactMap { date($0.day) }.max() ?? .distantPast)
            let age = now.timeIntervalSince(last)
            guard age >= provisionalTTL else { return nil }
            return CleanupItem(action: .archiveUnused, id: r.id, into: nil, reason: "provisória sem uso há \(Int((age / 86_400).rounded(.down))) dias")
        }
    }

    /// Blocks earning: a live contest or an open wrong/outdated flag. A past contest (`lastContestedAt`) only gates promotion.
    private static func contested(_ e: LifecycleEntry) -> Bool {
        e.contestedNow || e.flags.contains { $0.verdict != .useful }
    }

    private static func date(_ day: String) -> Date? {
        dayFormatter.date(from: day)
    }
    nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f
    }()
}
