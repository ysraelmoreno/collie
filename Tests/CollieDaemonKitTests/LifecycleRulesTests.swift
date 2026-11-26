import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct LifecycleRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC
    func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }
    func day(_ d: Int) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        return f.string(from: ago(Double(d)))
    }
    func uses(_ pairs: [(Int, String)]) -> Set<UseKey> { Set(pairs.map { UseKey(day: day($0.0), session: $0.1) }) }
    /// ma3: one use carries evidence (earning needs it); `LifecycleEarnedEvidenceTests` covers the implicit-only case.
    func entry(_ u: Set<UseKey>, since: Double = 30) -> LifecycleEntry {
        LifecycleEntry(usefulUses: u, tierSince: ago(since), evidencedUses: u.min { $0.day < $1.day }.map { [$0] })
    }
    func tmpDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("collie-lc-\(UUID().uuidString)") }

    @Test func earnedNeedsTwoDaysAndTwoSessions() {
        #expect(LifecycleRules.tier(for: entry(uses([(1, "a"), (1, "b")])), now: now) == .provisional)
        #expect(LifecycleRules.tier(for: entry(uses([(1, "a"), (2, "a")])), now: now) == .provisional)
        #expect(LifecycleRules.tier(for: entry(uses([(1, "a"), (2, "b")])), now: now) == .earned)
    }

    @Test func contestedNeverEarns() {
        let u = uses([(1, "a"), (2, "b")])
        var e = entry(u); e.contestedNow = true
        #expect(LifecycleRules.tier(for: e, now: now) == .provisional)
        e = entry(u); e.flags = [LifecycleFlag(verdict: .wrong, session: "a", day: day(3), reason: "x")]
        #expect(LifecycleRules.tier(for: e, now: now) == .provisional)
    }

    @Test func pastContestDoesNotBlockEarning() {
        var e = entry(uses([(1, "a"), (2, "b")])); e.lastContestedAt = ago(40)
        #expect(LifecycleRules.tier(for: e, now: now) == .earned)
    }

    @Test func longTermStaysUnlessContested() {
        var e = entry(uses([(1, "a")])); e.tier = .longTerm
        #expect(LifecycleRules.tier(for: e, now: now) == .longTerm)
        e.contestedNow = true
        #expect(LifecycleRules.tier(for: e, now: now) == .earned)
    }

    @Test func promotionNeedsEightUsesFourDaysFourteenDaySpan() {
        let ok = uses([(20, "a"), (15, "b"), (10, "c"), (5, "d"), (5, "e"), (5, "f"), (5, "g"), (5, "h")])
        #expect(LifecycleRules.promotionCandidate(entry(ok), now: now))
        #expect(!LifecycleRules.promotionCandidate(entry(uses([(20, "a"), (15, "b"), (10, "c"), (5, "d"), (5, "e"), (5, "f"), (5, "g")])), now: now))   // 7 uses
        #expect(!LifecycleRules.promotionCandidate(entry(uses([(20, "a"), (15, "b"), (5, "c"), (5, "d"), (5, "e"), (5, "f"), (5, "g"), (5, "h")])), now: now))   // 3 days
        #expect(!LifecycleRules.promotionCandidate(entry(uses([(12, "a"), (10, "b"), (8, "c"), (6, "d"), (6, "e"), (6, "f"), (6, "g"), (6, "h")])), now: now))   // span 6
        var l = entry(ok); l.tier = .longTerm
        #expect(!LifecycleRules.promotionCandidate(l, now: now))
    }

    @Test func contestedInLast30DaysBlocksPromotion() {
        let ok = uses([(20, "a"), (15, "b"), (10, "c"), (5, "d"), (5, "e"), (5, "f"), (5, "g"), (5, "h")])
        var e = entry(ok); e.tier = .earned; e.lastContestedAt = ago(10)
        #expect(!LifecycleRules.promotionCandidate(e, now: now))
        e.lastContestedAt = ago(40)
        #expect(LifecycleRules.promotionCandidate(e, now: now))
        e.contestedNow = true
        #expect(!LifecycleRules.promotionCandidate(e, now: now))
    }

    @Test func ttlCountsFromLastUsefulUseNotCreation() {
        let r = MemoryRecord(kind: .decision, subject: "a", title: "t", createdAt: ago(100))
        func plan(_ e: LifecycleEntry) -> [CleanupItem] { LifecycleRules.unusedPlan(records: [r], entries: [r.id: e], now: now) }
        #expect(plan(entry([], since: 20)).isEmpty)
        let p = plan(entry([], since: 22))
        #expect(p.count == 1 && p[0].action == .archiveUnused && p[0].reason == "provisória sem uso há 22 dias (prazo de decisão: 21)")
        #expect(plan(entry([], since: 21)).count == 1)                     // exactly 21 days
        var earned = entry([], since: 90); earned.tier = .earned
        #expect(plan(earned).isEmpty)
        #expect(plan(entry(uses([(5, "a")]), since: 60)).isEmpty)          // used 5 days ago
        #expect(plan(entry(uses([(25, "a")]), since: 60)).count == 1)
        #expect(LifecycleRules.unusedPlan(records: [r], entries: [:], now: now).isEmpty)   // no entry: not planned
    }

    /// B3.5: enforced by a check, a provisional memory past its TTL is not archived (never injected: it cannot earn a use).
    @Test func enforcedSkipsTheUnusedTTL() {
        for kind in [MemoryKind.decision, .pitfall] {
            var r = MemoryRecord(kind: kind, subject: "a", title: "t", createdAt: ago(400))
            let es = [r.id: entry([], since: 365)]
            #expect(LifecycleRules.unusedPlan(records: [r], entries: es, now: now).count == 1)
            r.enforcedBy = "scripts/ci/lint.sh"
            #expect(LifecycleRules.unusedPlan(records: [r], entries: es, now: now).isEmpty, "\(kind)")
        }
    }

    @Test func ttlPerKind() {
        #expect(LifecycleRules.ttl(.decision) == 21 * 86_400 && LifecycleRules.ttl(.map) == 21 * 86_400)
        #expect(LifecycleRules.ttl(.pitfall) == 60 * 86_400 && LifecycleRules.ttl(.procedure) == 60 * 86_400)
        #expect(LifecycleRules.ttl(.feedback) == nil)
        for (kind, days, label) in [(MemoryKind.decision, 21.0, "decisão"), (.map, 21, "mapa"), (.pitfall, 60, "armadilha"), (.procedure, 60, "procedimento")] {
            let r = MemoryRecord(kind: kind, subject: "a", title: "t", createdAt: ago(200))
            func plan(_ since: Double) -> [CleanupItem] { LifecycleRules.unusedPlan(records: [r], entries: [r.id: entry([], since: since)], now: now) }
            #expect(plan(days - 1).isEmpty, "\(kind) N-1")
            #expect(plan(days).map(\.reason) == ["provisória sem uso há \(Int(days)) dias (prazo de \(label): \(Int(days)))"], "\(kind) N")
            #expect(LifecycleRules.unusedPlan(records: [r], entries: [r.id: entry(uses([(Int(days) - 1, "a")]), since: 300)], now: now).isEmpty,
                    "\(kind) used recently")
        }
        let fb = MemoryRecord(kind: .feedback, subject: "a", title: "t", createdAt: ago(400))
        #expect(LifecycleRules.unusedPlan(records: [fb], entries: [fb.id: entry([], since: 365)], now: now).isEmpty)
    }

    @Test func pitfallArchiveGoesThroughUndo() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let r = MemoryRecord(kind: .pitfall, subject: "a", title: "t", createdAt: ago(90))
        try s.write(r)
        #expect(LifecycleRules.unusedPlan(records: s.all().records, entries: [r.id: entry([], since: 30)], now: now).isEmpty)
        let plan = LifecycleRules.unusedPlan(records: s.all().records, entries: [r.id: entry([], since: 61)], now: now)
        #expect(plan.count == 1)
        _ = try MemoryCleanup.apply(plan, store: s)
        #expect(s.all().records.first { $0.id == r.id }?.status == .archived)
        #expect(try MemoryCleanup.restore(r.id, store: s).status == .active)
    }

    @Test func ineligibleRecordsNeverInPlan() {
        let rs = [MemoryRecord(kind: .decision, subject: "p", title: "t", pinned: true),
                  MemoryRecord(kind: .decision, subject: "r", title: "t", reviewed: true),
                  MemoryRecord(kind: .decision, scope: .lot, lotId: UUID(), subject: "l", title: "t"),
                  MemoryRecord(kind: .decision, scope: .global, subject: "g", title: "t"),
                  MemoryRecord(kind: .decision, scope: .paddock, paddock: "x", subject: "d", title: "t")]
        let es = Dictionary(uniqueKeysWithValues: rs.map { ($0.id, entry([], since: 90)) })
        #expect(LifecycleRules.unusedPlan(records: rs, entries: es, now: now).isEmpty)
    }

    @Test func plannedItemApplyArchivesAndStaysReversible() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let r = MemoryRecord(kind: .decision, subject: "a", title: "t", createdAt: ago(50))
        try s.write(r)
        let plan = LifecycleRules.unusedPlan(records: s.all().records, entries: [r.id: entry([], since: 30)], now: now)
        #expect(plan.count == 1)
        _ = try MemoryCleanup.apply(plan, store: s)
        #expect(s.all().records.first { $0.id == r.id }?.status == .archived)
        #expect(try MemoryCleanup.restore(r.id, store: s).status == .active)
    }

    /// ma3 ended the shadow: the same uses earn only with evidence beside them (stored through `LifecycleStore`, the way
    /// the daemon writes them); implicit uses alone never earn nor become a promotion candidate.
    @Test func evidenceIsWhatEarns() async {
        let recs = (0..<6).map { MemoryRecord(kind: $0 % 2 == 0 ? .pitfall : .decision, subject: "s\($0)", title: "t\($0)", body: "b") }
        let plain = LifecycleStore(file: tmpDir().appendingPathComponent("a.json")), shadow = LifecycleStore(file: tmpDir().appendingPathComponent("b.json"))
        // record i is used on days 60, 60-4, 60-8 … by sessions alternating, i*2 uses in all (0: none at all)
        for (i, r) in recs.enumerated() {
            for st in [plain, shadow] { await st.update(r.id, now: ago(70)) { _ in } }
            for n in 0..<(i * 2) {
                let key = UseKey(day: day(60 - n * 4), session: n % 2 == 0 ? "a" : "b")
                await plain.addUse([r.id], key: key, now: ago(Double(60 - n * 4)))
                let taken = await shadow.addUse([r.id], key: key, now: ago(Double(60 - n * 4)))
                await shadow.addEvidence(taken, key: key, now: ago(Double(60 - n * 4)))
            }
        }
        // and a `get` of each, through the service: it marks, writes nothing (no next prompt here)
        let mem = MemoryService(globalDir: tmpDir().appendingPathComponent("memory")), term = UUID()
        await mem.noteSession(term, transcript: "/x/g.jsonl")
        await mem.lifecycle.noteInjected(session: "g", ids: recs.map(\.id), now: ago(1))
        for r in recs { await mem.lifecycle.update(r.id, now: ago(70)) { _ in } }
        let beforeGet = await mem.lifecycle.all()
        for r in recs { await mem.noteGet(term, record: r) }
        #expect(await mem.lifecycle.all() == beforeGet)
        let a = await plain.all(), b = await shadow.all()
        #expect(b.values.contains { ($0.evidencedUses?.count ?? 0) > 0 } && b.values.allSatisfy { ($0.evidencedUses ?? []).isSubset(of: $0.usefulUses) })
        for at in [ago(30), ago(0), now.addingTimeInterval(90 * 86_400)] {
            for r in recs {
                #expect(LifecycleRules.tier(for: a[r.id]!, now: at) == .provisional)
                #expect(!LifecycleRules.promotionCandidate(a[r.id]!, now: at))
            }
        }
        #expect(Set(recs.map { LifecycleRules.tier(for: b[$0.id]!, now: now) }).count > 1)   // with evidence the sequence does move tiers
        #expect(!LifecycleRules.unusedPlan(records: recs, entries: a, now: now.addingTimeInterval(90 * 86_400)).isEmpty)
    }

    /// An edited text starts over without its uses: its evidence goes with them (`evidencedUses ⊆ usefulUses`).
    @Test func editedTextDropsEvidenceWithTheUses() {
        let r = MemoryRecord(kind: .decision, subject: "s", title: "t", body: "b")
        var e = entry(uses([(1, "a"), (2, "b")])); e.tier = .earned; e.textHash = "other"; e.evidencedUses = uses([(1, "a")])
        let x = LifecycleRules.effective(e, r)
        #expect(x.usefulUses.isEmpty && x.evidencedUses == nil)
    }
}
