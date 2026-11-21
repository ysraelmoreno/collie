import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// M10.4: near-duplicate memories (same subject, close title terms or close vectors) never enter one injection block
/// together: the best of each group goes in, the others count as seen and as `collapsed`; the store is never touched.
@Suite(.serialized) struct InjectionDedupTests {
    private static let subject = "escrita na worktree derruba a tentativa"
    /// Five pitfalls about the same thing (different ids and texts, one subject) and two about other things.
    private func fixture(age: (Int) -> TimeInterval = { Double($0) * 60 }) -> (group: [MemoryRecord], other: [MemoryRecord]) {
        // one subject each (the store itself resolves two actives of one subject): the titles make them near
        let titles = ["Escrita na worktree derruba a tentativa do laço", "Escrita na worktree derruba a tentativa do laço em curso",
                      "Escrita na worktree derruba de novo a tentativa do laço", "Escrita na worktree derruba a tentativa do laço agora",
                      "Escrita na worktree compartilhada derruba a tentativa do laço"]
        let group = titles.enumerated().map { i, t in
            MemoryRecord(kind: .pitfall, subject: Self.subject + " \(i)", title: t, body: "worktree tentativa laço", hits: 1,
                         updatedAt: Date().addingTimeInterval(-age(i)))
        }
        let other = [MemoryRecord(kind: .pitfall, subject: "commit antes do check", title: "Laço sem commit perde a tentativa",
                                  body: "worktree tentativa laço commit", hits: 1),
                     MemoryRecord(kind: .decision, subject: "build frio", title: "Compilação fria em worktree nova é lenta",
                                  body: "worktree tentativa laço compilação", hits: 1)]
        return (group, other)
    }
    private func service(_ recs: [MemoryRecord], embedder: (any MemoryEmbedder)? = nil) async throws -> (MemoryService, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-dedup-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mem = MemoryService(globalDir: dir, embedder: embedder)
        try await mem.global.run { m in for r in recs { try m.store.write(r) } }
        if embedder != nil { await mem.global.fillVectors() }
        return (mem, root, dir.path)
    }
    private func count(_ text: String, _ recs: [MemoryRecord]) -> Int { recs.filter { text.contains($0.title) }.count }
    private func snapshot(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let urls = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for u in urls where u.pathExtension == "md" { out[u.lastPathComponent] = try Data(contentsOf: u) }
        return out
    }
    private let prompt = "escrita worktree derruba tentativa laço commit compilação"

    @Test func fiveOfOneSubjectAndTwoOthersInjectOnePlusTwo() async throws {
        let f = fixture()
        let (mem, root, dir) = try await service(f.group + f.other)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = await mem.relevant(for: UUID(), cwd: dir, prompt: prompt, limit: 4096, max: 5)
        #expect(count(text, f.group) == 1 && count(text, f.other) == 2, "\(text)")
    }

    @Test func bestOfGroupWinsByScoreThenRecency() {
        let f = fixture()
        let g = f.group
        // score first: the oldest wins when its score is the highest
        let byScore = InjectionDedup.collapse(g + f.other, score: { $0.id == g[4].id ? 2 : 1 })
        #expect(Set(byScore.kept.map(\.id)) == Set([g[4].id] + f.other.map(\.id)))
        #expect(byScore.kept.first?.id == g[4].id && byScore.collapsed.count == 4 && byScore.collapsed.allSatisfy { $0.by == g[4].id })
        // a tie: the newest (g[0]); same date: the most confirmations
        let tie = InjectionDedup.collapse(g.reversed(), score: { _ in 1 })
        #expect(tie.kept.map(\.id) == [g[0].id])
        var a = g[1], b = g[2]
        a.updatedAt = g[0].updatedAt; b.updatedAt = g[0].updatedAt; b.hits = 9
        #expect(InjectionDedup.collapse([a, b], score: { _ in 1 }).kept.map(\.id) == [b.id])
    }

    @Test func collapsedDoNotComeBackNextPrompt() async throws {
        let f = fixture()
        let (mem, root, dir) = try await service(f.group + f.other)
        defer { try? FileManager.default.removeItem(at: root) }
        let t = UUID()
        let first = await mem.relevant(for: t, cwd: dir, prompt: prompt, limit: 4096, max: 5)
        #expect(count(first, f.group) == 1, "\(first)")
        let second = await mem.relevant(for: t, cwd: dir, prompt: prompt, limit: 4096, max: 5)
        #expect(count(second, f.group) == 0, "\(second)")
    }

    @Test func withoutEmbedderTitleTermsGroupDifferentSubjects() async throws {
        let a = MemoryRecord(kind: .pitfall, subject: "um", title: "Escrita na worktree derruba a tentativa", body: "x")
        let b = MemoryRecord(kind: .pitfall, subject: "dois", title: "Escrita worktree derruba tentativa laço", body: "y")
        let c = MemoryRecord(kind: .pitfall, subject: "três", title: "Laço sem commit perde a tentativa", body: "z")
        #expect(InjectionDedup.near(a, b) && !InjectionDedup.near(a, c))
        let (mem, root, dir) = try await service([a, b, c])
        defer { try? FileManager.default.removeItem(at: root) }
        let text = await mem.relevant(for: UUID(), cwd: dir, prompt: "escrita worktree derruba tentativa laço commit", limit: 4096, max: 5)
        #expect(count(text, [a, b]) == 1 && text.contains(c.title), "\(text)")
    }

    /// With vectors: two titles with no term in common but the same meaning (the fake embedder's concept axis) group.
    @Test func vectorsGroupSameMeaning() async throws {
        let a = MemoryRecord(kind: .decision, subject: "a", title: "Rodar testes com filter", body: "teste")
        let b = MemoryRecord(kind: .decision, subject: "b", title: "Suíte inteira nunca", body: "teste")
        let (mem, root, dir) = try await service([a, b], embedder: ConceptEmbedder())
        defer { try? FileManager.default.removeItem(at: root) }
        let vecs = try await mem.global.run { m in m.index()?.vectors([a.id, b.id]) ?? [:] }
        #expect(!InjectionDedup.near(a, b) && InjectionDedup.near(a, b, vectors: vecs))
        let text = await mem.relevant(for: UUID(), cwd: dir, prompt: "como rodo os testes da suíte com filter?", limit: 4096, max: 5)
        #expect(count(text, [a, b]) == 1, "\(text)")
    }

    /// The byte budget holds, and what the collapsed would have taken goes to distinct candidates.
    @Test func budgetHoldsAndGoesToDistinct() async throws {
        let f = fixture()
        let (mem, root, dir) = try await service(f.group + f.other)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = 140, limit = MemoryService.relevantHeader.utf8.count + 3 * line   // room for about three lines
        let text = await mem.relevant(for: UUID(), cwd: dir, prompt: prompt, limit: limit, max: 3)
        #expect(text.utf8.count <= limit, "\(text.utf8.count)")
        #expect(count(text, f.group) == 1 && count(text, f.other) == 2, "\(text)")
    }

    @Test func storeIsIdenticalBeforeAndAfter() async throws {
        let f = fixture()
        let (mem, root, dir) = try await service(f.group + f.other)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(dir)
        let t = UUID()
        _ = await mem.relevant(for: t, cwd: dir, prompt: prompt)
        _ = await mem.relevant(for: t, cwd: dir, prompt: prompt)
        #expect(try snapshot(dir) == before && before.count == 7)
        let all = try await mem.global.run { m in m.store.all().records }
        #expect(all.filter { $0.status == .active }.count == 7)
    }

    @Test func checklistCollapsesAndStatsCountIt() async throws {
        let repo = try await makeRepo()
        let f = fixture()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            try await store.run { m in for r in f.group + [f.other[0]] { try m.store.write(r) } }
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(count(c.text, f.group) == 1 && c.text.contains(f.other[0].title) && c.ids.count == 2, "\(c.text)")
        }
        var e = MemoryEvent(type: .injected); e.at = Date(); e.ids = [f.group[0].id]; e.collapsed = f.group.dropFirst().map(\.id); e.where = "prompt"
        let r = MemoryObservability.compute(events: [e], since: Date().addingTimeInterval(-3600), now: Date().addingTimeInterval(60), records: [],
                                            verified: { _ in true }, scores: [:], openDigest: [], curator: nil)
        #expect(r.usage.collapsed == 4)
    }
}
