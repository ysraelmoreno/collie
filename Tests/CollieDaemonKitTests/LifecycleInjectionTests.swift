import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

private func id8(_ r: MemoryRecord) -> String { String(r.id.uuidString.lowercased().prefix(8)) }

@Suite(.serialized) struct LifecycleInjectionTests {
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
        await mem.lifecycle.update(r.id, now: Date()) { $0.usefulUses = [UseKey(day: "2026-11-01", session: "a"), UseKey(day: "2026-11-02", session: "b")] }
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
        await mem.resolvePending(for: t, correction: false, now: now)
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])   // injected again the same day
        await mem.resolvePending(for: t, correction: false, now: now)
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses == [UseKey(day: Self.day(now), session: "s1")])
        await mem.resolvePending(for: t, correction: false, now: now)   // nothing pending: no change
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
        // a wrong flag from this session: not counted
        await mem.lifecycle.update(r.id, now: now) { $0.flags = [LifecycleFlag(verdict: .wrong, session: "s1", day: Self.day(now), reason: "")] }
        await mem.lifecycle.setPending(session: "s1", ids: [r.id])
        await mem.resolvePending(for: t, correction: false, now: now.addingTimeInterval(86_400))
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
    }

    @Test func nextPromptWithCorrectionDropsUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: true, now: Date())
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

    @Test func reviewedAndPinnedHaveNoTagsAndNoEntries() async throws {
        let r = x(reviewed: true), p = MemoryRecord(kind: .decision, subject: "q", title: "Pool size twenty", body: "postgres pool sizing twenty",
                                                  pinned: true)
        let (mem, repo) = try await setup([r, p])
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        #expect(out.contains("[decisão \(id8(r))] Use Postgres pool: postgres pool sizing\n") || out.hasSuffix("[decisão \(id8(r))] Use Postgres pool: postgres pool sizing"), "\(out)")
        #expect(out.contains("[decisão \(id8(p))]") && !out.contains("(provisória"), "\(out)")
        await mem.resolvePending(for: t, correction: false, now: Date())
        #expect(await mem.lifecycle.all().isEmpty)
    }

    @Test func noSessionNoBookkeeping() async throws {
        let r = x()
        let (mem, repo) = try await setup([r], session: false)
        #expect((await mem.relevant(for: t, cwd: repo.path, prompt: prompt)).contains("(provisória)"))
        await mem.resolvePending(for: t, correction: false, now: Date())
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
