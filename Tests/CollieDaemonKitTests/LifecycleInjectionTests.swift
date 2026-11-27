import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

private func id8(_ r: MemoryRecord) -> String { String(r.id.uuidString.lowercased().prefix(8)) }

@Suite(.serialized, .memoryPT) struct LifecycleInjectionTests {
    private let t = UUID(), prompt = "postgres pool sizing"

    /// A service over a fresh repo holding `recs`, with `t`'s session "s1" (unless `session` is false).
    private func setup(_ recs: [MemoryRecord], session: Bool = true) async throws -> (MemoryService, URL) {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        for r in recs { _ = try await store.run { try $0.store.save(r) } }
        if session { await mem.noteSession(t, transcript: "/x/s1.jsonl") }
        return (mem, repo)
    }
    private func x(reviewed: Bool = false, pinned: Bool = false) -> MemoryRecord {
        MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres pool", body: "postgres pool sizing", reviewed: reviewed, pinned: pinned)
    }
    private static func day(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.string(from: d)
    }

    @Test func promptLineHasShortIdAndProvisionalTag() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        #expect(out.contains("\n- [decisão \(id8(r))] Use Postgres pool: postgres pool sizing (provisória)"), "\(out)")
        #expect(!out.contains("não revisada"))
        #expect(await mem.lifecycle.injected(session: "s1") == [r.id])
    }

    @Test func earnedLineHasNoTag() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        await mem.lifecycle.update(r.id, now: Date()) {
            $0.usefulUses = [UseKey(day: "2026-11-01", session: "a"), UseKey(day: "2026-11-02", session: "b")]
            $0.evidencedUses = [UseKey(day: "2026-11-01", session: "a")]   // ma3: earning needs evidence
        }
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        #expect(out.hasSuffix("] Use Postgres pool: postgres pool sizing"), "\(out)")
    }

    @Test func contestedLineTagged() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        await mem.lifecycle.update(r.id, now: Date()) { $0.contestedNow = true }
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).hasSuffix(" (provisória, contestada)"))
        await mem.lifecycle.update(r.id, now: Date()) { $0.tier = .earned }
        await mem.endSession(t); await mem.noteSession(t, transcript: "/x/s2.jsonl")
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).hasSuffix("sizing (contestada)"))
    }

    @Test func indexLinesHaveNoId() {
        let d = x(pinned: true), u = MemoryRecord(kind: .decision, subject: "u", title: "Unpinned one", body: "b")
        let (text, ids) = MemoryService.renderContext([d], index: [u], limit: 4096)
        #expect(text.contains("\n- [\(id8(d))] Use Postgres pool: postgres pool sizing\n"), "\(text)")
        #expect(text.hasSuffix("\n- Unpinned one") && ids == [d.id], "\(text)")
    }

    @Test func headerExplainsFlagCommand() async throws {
        let line = "memória errada ou velha: `collie memory flag <id> --wrong|--outdated`"
        #expect(MemoryService.header.contains(line))
        let (mem, repo) = try await setup([x()])
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).hasPrefix(MemoryService.relevantHeader) && MemoryService.relevantHeader.hasSuffix(line))
    }

    @Test func nextPromptWithoutCorrectionCountsOneUsePerDaySession() async throws {
        let r = x(), now = Date()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: false, user: true, now: now)
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])   // injected again the same day
        await mem.resolvePending(for: t, correction: false, user: true, now: now)
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses == [UseKey(day: Self.day(now), session: "s1")])
        await mem.resolvePending(for: t, correction: false, user: true, now: now)   // nothing pending: no change
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
        // a wrong flag from this session: not counted
        await mem.lifecycle.update(r.id, now: now) { $0.flags = [LifecycleFlag(verdict: .wrong, session: "s1", day: Self.day(now), reason: "")] }
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: false, user: true, now: now.addingTimeInterval(86_400))
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
    }

    @Test func nextPromptWithCorrectionDropsUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: true, user: true, now: Date())
        #expect(await mem.lifecycle.entry(r.id) == nil)
        #expect(await mem.lifecycle.takePending(session: "s1").isEmpty)
    }

    @Test func noNextPromptDropsUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.endSession(t)
        #expect(await mem.lifecycle.takePending(session: "s1").isEmpty)
        #expect(await mem.lifecycle.entry(r.id) == nil)
    }

    /// Leva 1 precision: the prompt injection logs how many ids can earn a use; each resolution logs a `used`.
    @Test func resolutionLogsUsedEvents() async throws {
        let r = x(), rv = MemoryRecord(kind: .decision, subject: "q", title: "Pool size twenty", body: "postgres pool sizing twenty", reviewed: true)
        let (mem, repo) = try await setup([r, rv])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: true, user: true, now: Date())
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())   // nothing pending: no event
        _ = try await mem.applyFlag(session: "s1", id: r.id, record: r, verdict: .useful, reason: "", terminal: t)
        mem.events.flush()
        let es = mem.events.read(since: Date().addingTimeInterval(-60))
        let inj = es.filter { $0.type == .injected && $0.where == "prompt" }
        #expect(inj.count == 1 && inj[0].ids?.count == 2 && inj[0].eligible == 1, "\(inj)")
        let used = es.filter { $0.type == .used && $0.where == nil }
        #expect(used.count == 2, "\(used)")
        let flag = es.filter { $0.type == .used && $0.where == "flag" }   // item 2: `--useful` is a use with evidence
        #expect(flag.count == 1 && flag[0].ids == [r.id] && flag[0].evidenced == [r.id] && flag[0].evidence == ["flag"], "\(flag)")
        #expect(await mem.lifecycle.entry(r.id)?.evidencedUses?.count == 1)
        #expect(used.first?.ids == [r.id] && used.first?.hits == 1 && used.first?.reason == nil && used.first?.terminal == t && used.first?.session == "s1")
        #expect(used.last?.ids == [] && used.last?.hits == 1 && used.last?.reason == "correction")
        #expect(es.first { $0.type == .flagged }?.terminal == t)   // the log can stamp the flagging agent
    }

    /// Item 2 phase 1: the turn names a pending memory; the next prompt (no correction) counts the use and its evidence.
    @Test func citedInTurnCountsEvidenceBesideTheUse() async throws {
        let r = x(), now = Date(), key = UseKey(day: Self.day(now), session: "s1")
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.noteTurnCitations(t, message: "Usei a [\(id8(r))] e deu certo.")
        await mem.resolvePending(for: t, correction: false, user: true, now: now)
        let e = try #require(await mem.lifecycle.entry(r.id))
        #expect(e.usefulUses == [key] && e.evidencedUses == [key])
        mem.events.flush()
        let used = mem.events.read(since: now.addingTimeInterval(-60)).filter { $0.type == .used }
        #expect(used.count == 1 && used[0].ids == [r.id] && used[0].evidenced == [r.id] && used[0].evidence == ["cite"], "\(used)")
    }

    @Test func citationWithCorrectionOrWithoutCitationRecordsNoEvidence() async throws {
        let r = x(), now = Date()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.noteTurnCitations(t, message: "Use Postgres pool, como a memória diz")   // the title (3 words)
        await mem.resolvePending(for: t, correction: true, user: true, now: now)
        #expect(await mem.lifecycle.entry(r.id) == nil)
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: false, user: true, now: now)   // the citation went with the corrected prompt
        let e = try #require(await mem.lifecycle.entry(r.id))
        #expect(e.usefulUses.count == 1 && e.evidencedUses == nil)
        mem.events.flush()
        #expect(mem.events.read(since: now.addingTimeInterval(-60)).filter { $0.type == .used }.allSatisfy { $0.evidenced == nil })
    }

    @Test func citationOfNothingPendingOrBeforeSessionEndIsDropped() async throws {
        let r = x(), other = MemoryRecord(kind: .decision, subject: "o", title: "Other one here", body: "zzz")
        let (mem, repo) = try await setup([r, other])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.noteTurnCitations(t, message: "Other one here [\(id8(other))]")   // not pending in this session
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        let ev = await mem.lifecycle.entry(r.id)?.evidencedUses, o = await mem.lifecycle.entry(other.id)
        #expect(ev == nil && o == nil)
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: "postgres pool sizing again")
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.noteTurnCitations(t, message: "[\(id8(r))]")
        await mem.endSession(t); await mem.noteSession(t, transcript: "/x/s1.jsonl")
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.evidencedUses == nil)   // endSession forgot the citation
    }

    /// Item 2 phase 1: `memory.get` of a memory injected in the caller's session changes nothing now (no use: no rule
    /// input moves); the next prompt without a correction counts the implicit use as before plus evidence `get`, in its
    /// own `used`. A correction drops it; a memory not injected here is never marked.
    @Test func getOfInjectedIsEvidenceAtTheNextPromptOnly() async throws {
        let r = x(), other = MemoryRecord(kind: .decision, subject: "o", title: "Other", body: "zzz"), now = Date()
        let key = UseKey(day: Self.day(now), session: "s1")
        let (mem, repo) = try await setup([r, other])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        let before = await mem.lifecycle.all()
        await mem.noteGet(t, record: r); await mem.noteGet(t, record: other)
        let after = await mem.lifecycle.all()
        #expect(after == before && after[r.id] == nil)   // (a) no use, no entry: tier, promotion and unused plan can't move
        await mem.resolvePending(for: t, correction: false, user: true, now: now)
        let e = try #require(await mem.lifecycle.entry(r.id))
        #expect(e.usefulUses == [key] && e.evidencedUses == [key])   // (b) the implicit use as today, plus evidence
        #expect(await mem.lifecycle.entry(other.id) == nil)          // (d) never injected: nothing
        mem.events.flush()
        let used = mem.events.read(since: now.addingTimeInterval(-60)).filter { $0.type == .used }
        #expect(used.count == 1 && used[0].where == nil && used[0].ids == [r.id] && used[0].evidenced == [r.id] && used[0].evidence == ["get"], "\(used)")
        #expect(MemoryObservability.precision(used).used == 1)   // the v1 count, as without the get
        // (c) a correction: nothing, the get went with it
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.noteGet(t, record: r)
        await mem.resolvePending(for: t, correction: true, user: true, now: now.addingTimeInterval(86_400))
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: false, user: true, now: now.addingTimeInterval(86_400))
        let k2 = UseKey(day: Self.day(now.addingTimeInterval(86_400)), session: "s1")
        let e2 = try #require(await mem.lifecycle.entry(r.id))
        #expect(e2.usefulUses == [key, k2] && e2.evidencedUses == [key])
    }

    @Test func citedAndGotBothKindsOneId() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.noteGet(t, record: r)
        await mem.noteTurnCitations(t, message: "[\(id8(r))]")
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        mem.events.flush()
        let u = mem.events.read(since: Date().addingTimeInterval(-60)).filter { $0.type == .used }
        #expect(u.count == 1 && u[0].evidenced == [r.id, r.id] && u[0].evidence == ["cite", "get"], "\(u)")
        #expect(MemoryObservability.evidence(u).evidenced == 1 && MemoryObservability.evidence(u).byKind == ["cite": 1, "get": 1])
    }

    @Test func reviewedAndPinnedHaveNoTagsAndNoEntries() async throws {
        let r = x(reviewed: true), p = MemoryRecord(kind: .decision, subject: "q", title: "Pool size twenty", body: "postgres pool sizing twenty",
                                                  pinned: true)
        let (mem, repo) = try await setup([r, p])
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        #expect(out.contains("[decisão \(id8(r))] Use Postgres pool: postgres pool sizing\n") || out.hasSuffix("[decisão \(id8(r))] Use Postgres pool: postgres pool sizing"), "\(out)")
        #expect(out.contains("[decisão \(id8(p))]") && !out.contains("(provisória"), "\(out)")
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        #expect(await mem.lifecycle.all().isEmpty)
    }

    @Test func noSessionNoBookkeeping() async throws {
        let r = x()
        let (mem, repo) = try await setup([r], session: false)
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).contains("(provisória)"))
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        #expect(await mem.lifecycle.all().isEmpty)
    }

    private func longTerm(_ mem: MemoryService, _ r: MemoryRecord, store: String?) async {
        await mem.lifecycle.update(r.id, now: Date()) { $0.tier = .longTerm; $0.store = store; $0.textHash = LifecycleRules.textHash(r) }
    }

    @Test func editedLongTermIsProvisionalAgain() async throws {
        var r = x()
        let (mem, repo) = try await setup([r])
        let key = await mem.repo(for: repo.path).key
        await longTerm(mem, r, store: key)
        #expect((await mem.contextText(cwd: repo.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
        r.body = "postgres pool sizing, editado"
        let edited = r
        _ = try await mem.repo(for: repo.path).run { try $0.store.write(edited) }
        #expect(!(await mem.contextText(cwd: repo.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).hasSuffix(" (provisória)"))
    }

    /// The same record in two stores (pasture and a paddock worktree): one entry, its tier holds in both; a copy whose
    /// text differs is provisional there.
    @Test func sameIdInTwoStoresKeepsTierOnlyForSameText() async throws {
        var r = x()
        let (mem, repo) = try await setup([r])
        let other = try await makeRepo(), b = await mem.repo(for: other.path)
        let same = r
        _ = try await b.run { try $0.store.write(same) }
        await longTerm(mem, r, store: await mem.repo(for: repo.path).key)
        #expect((await mem.contextText(cwd: repo.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
        #expect((await mem.contextText(cwd: other.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
        r.body = "outro texto no outro repo"
        let edited = r
        _ = try await b.run { try $0.store.write(edited) }
        #expect(!(await mem.contextText(cwd: other.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
        #expect((await mem.contextText(cwd: repo.path, paddock: nil)).text.contains(MemoryService.longTermTitle))
    }

    @Test func lotMemberGetsLongTermBlock() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        await longTerm(mem, r, store: await mem.repo(for: repo.path).key)
        let c = await mem.contextText(cwd: repo.path, paddock: nil, lot: UUID())
        #expect(c.text.contains(MemoryService.longTermTitle) && c.ids.contains(r.id), "\(c.text)")
    }

    @Test func usersKindHasNoProvisionalTag() async throws {
        let f = MemoryRecord(kind: .feedback, subject: "db", title: "Use Postgres pool", body: "postgres pool sizing")
        let (mem, repo) = try await setup([f])
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        #expect(out.contains("[regra \(id8(f))]") && !out.contains("provisória"), "\(out)")
    }
}
