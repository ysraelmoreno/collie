import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// ma3: provisional → earned needs, besides 2 uses on 2 days by 2 sessions, at least one use with evidence (cite,
/// `memory get`, `flag --useful`); the lifecycle pass then writes `earnedBy: "evidence"`. Implicit uses alone stay
/// provisional; an entry already earned keeps its tier.
@Suite(.serialized) struct LifecycleEarnedEvidenceTests {
    private let prompt = "postgres pool sizing"
    private let d1 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC
    private var d2: Date { d1.addingTimeInterval(86_400) }
    private func key(_ d: Date, _ s: String) -> UseKey { UseKey(day: LifecycleRules.dayFormatter.string(from: d), session: s) }
    private func rec() -> MemoryRecord { MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres pool", body: prompt) }

    private func run(_ body: (Daemon, RepoMemory, URL) async throws -> Void) async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        fake.gated = true
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in
            try await body(d, await d.router.memory.repo(for: repo.path), repo)
            fake.open()
        }
    }

    /// Two sessions on two days, each injected by a user prompt that resolves without a correction (the implicit use);
    /// the first one also gives `evidence` ("cite", "get", "useful"; nil: none). Then one lifecycle pass.
    private func twoSessions(_ evidence: String?) async throws -> LifecycleEntry {
        var out: LifecycleEntry?
        try await run { d, store, repo in
            let r = rec(), mem = d.router.memory
            _ = try await store.run { try $0.store.save(r) }
            for (i, day) in [d1, d2].enumerated() {
                let term = UUID()
                await mem.noteSession(term, transcript: "/x/s\(i).jsonl")
                _ = await mem.relevant(for: term, cwd: repo.path, prompt: prompt)
                if i == 0, evidence == "cite" { await mem.noteTurnCitations(term, message: "Usei a [\(String(r.id.uuidString.lowercased().prefix(8)))].") }
                if i == 0, evidence == "get" { await mem.noteGet(term, record: r) }
                await mem.resolvePending(for: term, correction: false, user: true, now: day)
                if i == 0, evidence == "useful" {
                    _ = try await mem.applyFlag(session: "s0", id: r.id, record: r, verdict: .useful, reason: "", terminal: term, now: day)
                }
            }
            await d.router.lifecyclePass(store, now: d2)
            out = await mem.lifecycle.entry(r.id)
        }
        return try #require(out)
    }

    @Test func implicitUsesAloneStayProvisional() async throws {
        let e = try await twoSessions(nil)
        #expect(e.usefulUses == [key(d1, "s0"), key(d2, "s1")] && e.evidencedUses == nil)
        #expect(e.tier == .provisional && e.earnedBy == nil)
        #expect(!LifecycleRules.promotionCandidate(e, now: d2))
    }

    @Test func citeEarnsByEvidence() async throws {
        let e = try await twoSessions("cite")
        #expect(e.evidencedUses == [key(d1, "s0")])
        #expect(e.tier == .earned && e.earnedBy == "evidence")
    }

    @Test func getEarnsByEvidence() async throws {
        let e = try await twoSessions("get")
        #expect(e.tier == .earned && e.earnedBy == "evidence")
    }

    @Test func usefulFlagEarnsByEvidence() async throws {
        let e = try await twoSessions("useful")
        #expect(e.tier == .earned && e.earnedBy == "evidence")
    }

    /// The rule itself: evidence must sit on a held use; an open contest or a wrong/outdated flag still blocks.
    @Test func contestOrWrongFlagStillBlocks() {
        var e = LifecycleEntry(usefulUses: [key(d1, "a"), key(d2, "b")], tierSince: d1, evidencedUses: [key(d1, "a")])
        #expect(LifecycleRules.tier(for: e, now: d2) == .earned)
        e.contestedNow = true
        #expect(LifecycleRules.tier(for: e, now: d2) == .provisional)
        e.contestedNow = false
        for v in [FlagVerdict.wrong, .outdated] {
            e.flags = [LifecycleFlag(verdict: v, session: "c", day: "2027-01-10", reason: "x")]
            #expect(LifecycleRules.tier(for: e, now: d2) == .provisional)
        }
        e.flags = []; e.evidencedUses = [key(d1, "z")]   // not a held use: no evidence
        #expect(LifecycleRules.tier(for: e, now: d2) == .provisional)
    }

    /// No mass demotion: an entry earned before ma3 (implicit uses only, `earnedBy` nil) stays earned through the pass.
    @Test func existingEarnedIsNotDemoted() async throws {
        try await run { d, store, _ in
            let r = rec(), lc = d.router.memory.lifecycle
            _ = try await store.run { try $0.store.save(r) }
            await lc.update(r.id, now: d1) { $0.tier = .earned; $0.usefulUses = [self.key(self.d1, "a"), self.key(self.d2, "b")] }
            #expect(LifecycleRules.tier(for: try #require(await lc.entry(r.id)), now: d2) == .earned)
            await d.router.lifecyclePass(store, now: d2)
            let e = try #require(await lc.entry(r.id))
            #expect(e.tier == .earned && e.earnedBy == nil && e.tierSince == d1)
        }
    }
}
