import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Every path and branch fine; the SHAs in `missing` absent.
private struct PassFacts: GitFacts {
    var missing: Set<String> = []
    var merged: Set<String> = []
    func branch(_ name: String) async -> BranchState { merged.contains(name) ? .merged : .open }
    func commitExists(_ sha: String) async -> Bool { !missing.contains(sha) }
    func pathExists(_ rel: String) -> Bool { true }
}

private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { try m.store.write(r) } } }
private func status(_ s: RepoMemory, _ id: UUID) async throws -> MemoryStatus? {
    try await s.run { $0.store.all().records.first { $0.id == id }?.status }
}
private func dec(_ title: String, body: String = "corpo", age: Double = 0, status: MemoryStatus = .active, pinned: Bool = false,
                 reviewed: Bool = false) -> MemoryRecord {
    MemoryRecord(kind: .decision, subject: title, title: title, body: body, status: status, reviewed: reviewed, pinned: pinned,
                 createdAt: Date().addingTimeInterval(-age * 86_400))
}
private func id8(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
private func dayString(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.string(from: d) }
private let bad = "deadbee1"

@Suite(.serialized) struct LifecyclePassTests {
    private func run(available: Bool = true, _ body: (Daemon, RepoMemory) async throws -> Void) async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        fake.gated = true
        if !available { fake.avail = .unavailable("sem claude") }
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in PassFacts(missing: [bad], merged: ["feat/velha"]) } }) { d, _ in
            try await body(d, await d.router.memory.repo(for: repo.path))
            fake.open()
        }
    }
    private func claimContested(_ d: Daemon) async -> Int {
        await d.router.memory.lifecycle.all().values.filter { $0.flags.contains { $0.session == "claim-check" } }.count
    }

    /// No curator, bodies naming a merged branch and a missing SHA: the first run archives, flags and queues nothing.
    @Test func firstRunMigratesAllAsProvisionalAndArchivesNothing() async throws {
        try await run(available: false) { d, store in
            let bodies = ["corrigido em \(bad)", "ainda não mergeado: feat/velha", "corpo"]
            let recs: [MemoryRecord] = (0..<188).map { (i: Int) -> MemoryRecord in dec("Decisão \(i)", body: bodies[i % 3], age: 100 + Double(i)) }
            try await put(store, recs)
            let now = Date()
            await d.router.lifecyclePass(store, now: now)
            let entries = await d.router.memory.lifecycle.all()
            #expect(recs.allSatisfy { entries[$0.id]?.tier == .provisional && entries[$0.id]?.tierSince == now && entries[$0.id]?.contestedNow == false })
            let active = try await store.run { $0.store.all().records.filter { $0.status == .active }.count }
            #expect(active == 188)
            #expect(await d.router.digest.since(.distantPast).isEmpty)
            #expect(await claimContested(d) == 0)
            #expect(await d.router.curator.queued(kind: .verifyContested).isEmpty)
        }
    }

    @Test func claimContestsCappedAtTenPerPass() async throws {
        try await run { d, store in
            try await put(store, (0..<15).map { dec("Sumida \($0)", body: "corrigido em \(bad)") })
            let now = Date()
            await d.router.lifecyclePass(store, now: now)
            #expect(await claimContested(d) == 0)   // born this pass
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(86_400))
            #expect(await claimContested(d) == 10)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(2 * 86_400))
            #expect(await claimContested(d) == 15)
        }
    }

    /// The re-check judged this text: a failing claim check never contests it again.
    @Test func recheckedTextNotContestedAgain() async throws {
        try await run { d, store in
            let r = dec("Julgada", body: "corrigido em \(bad)")
            try await put(store, [r])
            let now = Date(), lc = d.router.memory.lifecycle
            await d.router.lifecyclePass(store, now: now)
            await lc.update(r.id, now: now) { $0.recheckedAt = now }
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(20 * 86_400))
            #expect(await claimContested(d) == 0)
        }
    }

    @Test func contestedLongTermIsEarnedUntilValidRecheck() async throws {
        try await run { d, store in
            let r = dec("Longa contestada", body: "corpo longo")
            try await put(store, [r])
            let now = Date(), lc = d.router.memory.lifecycle
            await lc.update(r.id, now: now) { $0.tier = .longTerm; $0.contestedNow = true; $0.lastContestedAt = now }
            await d.router.lifecyclePass(store, now: now)
            #expect(await lc.entry(r.id)?.tier == .longTerm)   // never demoted on disk
            #expect(MemoryService.renderLongTerm([r], entries: await lc.all(), limit: 4096).ids.isEmpty)
            await d.router.memory.applyVerdict(r.id, kind: .verifyContested, ops: [], now: now)
            #expect(MemoryService.renderLongTerm([r], entries: await lc.all(), limit: 4096).ids == [r.id])
        }
    }

    /// The 12-per-project cap counts stored longTerm: a contested one keeps its slot.
    @Test func contestedLongTermKeepsItsSlotInTheCap() async throws {
        try await run { d, store in
            let lts = (0..<12).map { dec("Longa \($0)") }, next = dec("Candidata")
            try await put(store, lts + [next])
            let now = Date(), lc = d.router.memory.lifecycle
            for r in lts { await lc.update(r.id, now: now) { $0.tier = .longTerm } }
            await lc.update(lts[0].id, now: now) { $0.contestedNow = true; $0.lastContestedAt = now }
            let ago: [Double] = [20, 14, 7, 1]
            await lc.update(next.id, now: now) { e in
                e.usefulUses = Set((0..<8).map { UseKey(day: dayString(now.addingTimeInterval(-ago[$0 % 4] * 86_400)), session: "u\($0)") })
            }
            #expect(LifecycleRules.promotionCandidate(try #require(await lc.entry(next.id)), now: now))
            await d.router.memory.applyVerdict(next.id, kind: .verifyPromotion, ops: [], now: now)
            let e = await lc.entry(next.id)
            #expect(e?.tier != .longTerm && e?.recheckedAt == now)
        }
    }

    /// Prune judges only the consolidated store's own entries.
    @Test func pruneOnlyTouchesThisStoresEntries() async throws {
        try await run { d, a in
            let b = await d.router.memory.repo(for: try await makeRepo().path)
            let ra = dec("Em A"), gone = dec("Sai de A"), rb = dec("Em B")
            try await put(a, [ra, gone]); try await put(b, [rb])
            let now = Date(), lc = d.router.memory.lifecycle
            await d.router.lifecyclePass(a, now: now); await d.router.lifecyclePass(b, now: now)
            let (sb, sa) = (await lc.entry(rb.id)?.store, await lc.entry(ra.id)?.store)
            #expect(sb == b.key && sa == a.key)
            try await a.run { try $0.store.delete(gone.id) }
            await d.router.lifecyclePass(a, now: now.addingTimeInterval(86_400))
            await d.router.lifecyclePass(a, now: now.addingTimeInterval(32 * 86_400))
            #expect(await lc.entry(gone.id) == nil)
            let (eb, ea) = (await lc.entry(rb.id), await lc.entry(ra.id))
            #expect(eb != nil && ea != nil)
        }
    }

    @Test func unusedProvisionalArchivedAfterTtl() async throws {
        try await run { d, store in
            let r = dec("Sem uso")
            try await put(store, [r])
            let now = Date()
            await d.router.lifecyclePass(store, now: now)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(20 * 86_400))
            #expect(try await status(store, r.id) == .active)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(22 * 86_400))
            #expect(try await status(store, r.id) == .archived)
            let row = await d.router.digest.since(.distantPast).first { $0.before.first?.id == r.id }
            #expect(row?.action == "aposentado" && row?.reason.hasPrefix("provisória sem uso") == true, "\(String(describing: row))")
        }
    }

    @Test func usefulUseExtendsLife() async throws {
        try await run { d, store in
            let r = dec("Usada")
            try await put(store, [r])
            let now = Date(), lc = d.router.memory.lifecycle
            await d.router.lifecyclePass(store, now: now)
            await lc.addUse([r.id], key: UseKey(day: dayString(now.addingTimeInterval(15 * 86_400)), session: "s1"), now: now)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(30 * 86_400))
            #expect(try await status(store, r.id) == .active)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(38 * 86_400))
            #expect(try await status(store, r.id) == .archived)
        }
    }

    @Test func proposalWithPassingChecksBecomesProvisionalActive() async throws {
        try await run { d, store in
            let old = dec("Proposta velha", age: 15, status: .proposed), young = dec("Proposta nova", age: 10, status: .proposed)
            try await put(store, [old, young])
            let now = Date()
            await d.router.lifecyclePass(store, now: now)
            #expect(try await status(store, old.id) == .active)
            #expect(try await status(store, young.id) == .proposed)
            let e = await d.router.memory.lifecycle.entry(old.id)
            #expect(e?.tier == .provisional && e?.tierSince == now)
            #expect(await d.router.digest.since(.distantPast).contains { $0.action == "ativado" && $0.before.first?.id == old.id })
        }
    }

    @Test func proposalWithFailingClaimStaysProposed() async throws {
        try await run { d, store in
            let p = dec("Commit sumido", body: "corrigido em \(bad)", age: 15, status: .proposed)
            try await put(store, [p])
            await d.router.lifecyclePass(store, now: Date())
            #expect(try await status(store, p.id) == .proposed)
            #expect(await d.router.memory.lifecycle.entry(p.id) == nil)
        }
    }

    @Test func pinnedAndReviewedNeverArchivedByFlagsOrChecks() async throws {
        try await run { d, store in
            let pin = dec("Fixada", body: "veio de \(bad)", age: 90, pinned: true), rev = dec("Revisada", body: "veio de \(bad)", age: 90, reviewed: true)
            try await put(store, [pin, rev])
            let now = Date(), lc = d.router.memory.lifecycle
            for r in [pin, rev] {
                await lc.update(r.id, now: now) { e in
                    e.flags = [LifecycleFlag(verdict: .wrong, session: "a", day: dayString(now), reason: "x")]; e.contestedNow = true; e.lastContestedAt = now
                }
            }
            await d.router.lifecyclePass(store, now: now)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(40 * 86_400))
            for r in [pin, rev] {
                #expect(try await status(store, r.id) == .active)
                #expect(await lc.entry(r.id)?.flags.contains { $0.session == "claim-check" } == false)
            }
            // the user's contested memories go to "Precisa de você", once each
            let asks = await d.router.digest.since(.distantPast).filter { $0.action == "ask" }
            #expect(asks.count == 2 && Set(asks.compactMap { $0.before.first?.id }) == [pin.id, rev.id], "\(asks.map(\.title))")
        }
    }

    @Test func longTermSkipsColdArchive() async throws {
        let now = Date(), cold = dec("Antiga", age: 70), lt = dec("Longo prazo", age: 70)
        let items = MemoryCleanup.plan(records: [cold, lt], stats: [:], scores: [lt.id: 0.1], exempt: [lt.id], now: now)
        #expect(items.map(\.id) == [cold.id])
        try await run { d, store in
            try await put(store, [cold, lt])
            await d.router.memory.lifecycle.update(lt.id, now: now) { $0.tier = .longTerm }
            await d.router.consolidate(store, now: now)
            #expect(try await status(store, cold.id) == .archived)
            #expect(try await status(store, lt.id) == .active)
        }
    }

    @Test func longTermInjectedInFullAtStartMaxThreeAnd600Bytes() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory")), t = UUID()
        let store = await mem.repo(for: repo.path)
        let lts = (0..<5).map { i in dec("Longa \(i)", body: "linha um \(i)\nlinha dois " + String(repeating: "x", count: 100)) }
        let plain = dec("Comum"), pit = MemoryRecord(kind: .pitfall, subject: "armadilha", title: "Armadilha recorrente", body: "b", hits: 3)
        try await put(store, lts + [plain, pit])
        for (i, r) in lts.enumerated() {
            await mem.lifecycle.update(r.id, now: Date()) { e in
                e.tier = .longTerm
                e.usefulUses = Set((0...i).map { UseKey(day: "2026-11-0\($0 + 1)", session: "s\($0)") })   // the most used first
            }
        }
        await mem.noteSession(t, transcript: "/x/s1.jsonl")
        let out = await mem.context(for: t, cwd: repo.path)
        let start = try #require(out.range(of: "\n\n" + MemoryService.longTermTitle))
        let ltText = String(out[start.lowerBound...]).components(separatedBy: "\n\n" + MemoryService.checklistHeader).first ?? ""
        #expect(ltText.utf8.count <= 600, "\(ltText.utf8.count)")
        let shown = lts.filter { out.contains("- [\(id8($0.id))] \($0.title): linha um") }
        #expect(Set(shown.map(\.id)) == [lts[4].id, lts[3].id, lts[2].id], "\(out)")
        let at = { (r: MemoryRecord) in out.range(of: "[\(id8(r.id))]")?.lowerBound ?? out.endIndex }
        #expect(at(lts[4]) < at(lts[3]) && at(lts[3]) < at(lts[2]))   // the most used first
        #expect(shown.allSatisfy { out.contains("- [\(id8($0.id))] \($0.title): linha um \($0.title.suffix(1)) linha dois \(String(repeating: "x", count: 100))\n") })
        #expect(!ltText.contains("provisória"))
        // before the checklist; the rest stay in the index (titles)
        let cl = try #require(out.range(of: MemoryService.checklistHeader))
        #expect(start.lowerBound < cl.lowerBound)
        let index = try #require(out.components(separatedBy: MemoryService.indexTitle).last)
        #expect(index.contains("\n- Longa 1") && index.contains("\n- Longa 0") && !index.contains("Longa 4"), "\(out)")
        #expect(await mem.lifecycle.injected(session: "s1").isSuperset(of: shown.map(\.id)))
        // 600 B: whole lines only, however few that leaves
        let big = (0..<3).map { dec("Grande \($0)", body: String(repeating: "y", count: 250)) }
        let entries = Dictionary(uniqueKeysWithValues: big.map { ($0.id, LifecycleEntry(tier: .longTerm, tierSince: Date())) })
        let (t2, ids2) = MemoryService.renderLongTerm(big, entries: entries, limit: 4096)
        #expect(ids2.count == 2 && t2.utf8.count <= 600, "\(t2.utf8.count)")
    }

    @Test func forgedFrontmatterTierIgnored() async throws {
        try await run { d, store in
            let r = dec("Forjada", body: "corpo forjado")
            let text = MemoryFile.render(r).replacingOccurrences(of: "\nstatus: active", with: "\ntier: longTerm\nlifecycle: longTerm\nstatus: active")
            let file = try await store.run { $0.store.dir }.appendingPathComponent(MemoryFile.fileName(r))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            #expect(try await store.run { $0.store.all().records.first?.id } == r.id)
            await d.router.lifecyclePass(store, now: Date())
            #expect(await d.router.memory.lifecycle.entry(r.id)?.tier == .provisional)
            let recs = try await store.run { $0.store.all().records }
            let (text2, ids) = MemoryService.renderLongTerm(recs, entries: await d.router.memory.lifecycle.all(), limit: 4096)
            #expect(text2.isEmpty && ids.isEmpty)
        }
    }

    @Test func contestedFourteenDaysGoesToDigest() async throws {
        try await run { d, store in
            let old = dec("Contestada antiga"), recent = dec("Contestada recente")
            try await put(store, [old, recent])
            let now = Date(), lc = d.router.memory.lifecycle
            await lc.update(old.id, now: now) { $0.contestedNow = true; $0.lastContestedAt = now.addingTimeInterval(-15 * 86_400) }
            await lc.update(recent.id, now: now) { $0.contestedNow = true; $0.lastContestedAt = now.addingTimeInterval(-5 * 86_400) }
            await d.router.lifecyclePass(store, now: now)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(60))
            let asks = await d.router.digest.since(.distantPast).filter { $0.action == "ask" }
            #expect(asks.map { $0.before.map(\.id) } == [[old.id]], "\(asks.map(\.title))")
            #expect(try await status(store, old.id) == .active)
        }
    }
}
