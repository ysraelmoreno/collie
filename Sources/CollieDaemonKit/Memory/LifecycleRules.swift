import Foundation
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

    static func eligible(_ r: MemoryRecord) -> Bool {
        r.scope == .project && r.status == .active && !r.pinned && !r.reviewed
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

    /// Never earned once contested: any wrong/outdated flag, a live contest, or a past one.
    private static func contested(_ e: LifecycleEntry) -> Bool {
        e.contestedNow || e.lastContestedAt != nil || e.flags.contains { $0.verdict != .useful }
    }

    private static func date(_ day: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        return f.date(from: day)
    }
}
