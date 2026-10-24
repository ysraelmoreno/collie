import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func ops(_ list: [[String: JSONValue]]) -> CuratorOutput {
    CuratorOutput(json: .object(["ops": .array(list.map { .object($0) })]), inputTokens: 10, outputTokens: 5, costUSD: 0.0001)
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { try m.store.write(r) } } }
private func rec(_ title: String, _ body: String, kind: MemoryKind = .decision, subject: String? = nil, age: TimeInterval = 0,
                 path: String? = nil) -> MemoryRecord {
    MemoryRecord(kind: kind, subject: subject ?? title, title: title, body: body, path: path, createdAt: Date().addingTimeInterval(-age * 86400))
}
/// Three decisions about the same thing, in different words (newest first: c, b, a).
private func tailwind() -> [MemoryRecord] {
    [rec("Use Tailwind", "O estilo do app usa Tailwind v4 com classes utilitárias.", age: 3),
     rec("Tailwind v4", "O estilo do app usa Tailwind v4 e classes utilitárias.", age: 2),
     rec("Estilo com Tailwind", "Estilo do app: Tailwind v4 com classes utilitárias.", age: 1)]
}
private func status(_ s: RepoMemory, _ id: UUID) async throws -> MemoryStatus? { try await all(s).first { $0.id == id }?.status }

@Suite(.serialized) struct ConsolidationTests {
    @Test func clustersFound() {
        let t = tailwind()
        let map = rec("Mapa do estilo", "O estilo do app usa Tailwind v4 com classes utilitárias.", kind: .map, path: "Sources/Style.swift")
        let other = rec("Banco SQLite", "O índice usa SQLite com FTS5.")
        let rule = MemoryRecord(kind: .feedback, subject: "Use Tailwind", title: "Use Tailwind", body: t[0].body)
        let cs = Consolidation.clusters(t + [map, other, rule], max: 6)
        #expect(cs.map { $0.map(\.id) } == [[t[2].id, t[1].id, t[0].id]], "\(cs.map { $0.map(\.title) })")
        // same subject alone is enough
        let s1 = rec("A", "um", subject: "deploy"), s2 = rec("B", "dois", subject: "Deploy", age: 1)
        #expect(Consolidation.clusters([s1, s2], max: 6).map { Set($0.map(\.id)) } == [[s1.id, s2.id]])
        // 2–8 a cluster
        let many = (0..<12).map { rec("Tailwind \($0)", "O estilo do app usa Tailwind v4 com classes utilitárias.", age: Double($0)) }
        #expect(Consolidation.clusters(many, max: 6).first?.count == 8)
    }

    /// Cold, missing-path and duplicate items are applied and in the digest before any curator job; feedback untouched (R19).
    @Test func deterministicFirst() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        fake.gated = true
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let cold = rec("Velha", "nunca lida", age: 70), gone = rec("Arquivo sumido", "mapa", kind: .map, path: "gone.swift")
            let dupA = rec("Porta 8080", "o servidor ouve na porta 8080", age: 2), dupB = rec("Servidor 8080", "o servidor ouve na porta 8080", age: 1)
            let rule = MemoryRecord(kind: .feedback, subject: "r", title: "Regra antiga", createdAt: Date().addingTimeInterval(-90 * 86400))
            try await put(store, [cold, gone, dupA, dupB, rule] + tailwind())
            _ = try await store.run { $0.index() != nil }   // the map's path is seen missing now
            await d.router.consolidate(store, now: Date().addingTimeInterval(8 * 86400))
            let digest = await d.router.digest.since(.distantPast)
            #expect(Set(digest.map(\.title)) == ["Velha", "Arquivo sumido", "Porta 8080"], "\(digest.map(\.title))")
            #expect(digest.filter { $0.title == "Porta 8080" }.map(\.action) == ["mesclado"])
            let (c, g, u) = (try await status(store, cold.id), try await status(store, gone.id), try await status(store, dupA.id))
            #expect(c == .archived && g == .archived && u == .superseded)
            #expect(try await status(store, rule.id) == .active)
            #expect(await d.router.curator.queued(kind: .consolidate).count == 1)
            let input = fake.inputs.first ?? ""
            #expect(!input.contains("Regra antiga") && !input.contains("Velha"))
            fake.open()
        }
    }

    @Test func newestWinsSupersede() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        let t = tailwind()
        fake.output = ops([["op": .string("supersede"), "id": .string(t[0].id.uuidString), "by": .string(t[2].id.uuidString),
                            "reason": .string("a nova substitui a antiga")],
                           // never the older over the newer: that one waits for the user
                           ["op": .string("supersede"), "id": .string(t[1].id.uuidString), "by": .string(t[0].id.uuidString), "reason": .string("x")]])
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, t)
            await d.router.consolidate(store)
            #expect(await waitFor(10) { (try? await status(store, t[0].id)) == .superseded })
            let recs = try await all(store)
            #expect(recs.first { $0.id == t[0].id }?.supersededBy == t[2].id)
            #expect(recs.first { $0.id == t[1].id }?.status == .active)
            #expect(await waitFor(10) { await d.router.curator.queued(kind: .consolidate).isEmpty })
            let digest = await d.router.digest.since(.distantPast)
            #expect(digest.contains { $0.action == "aposentado" && $0.reason == "a nova substitui a antiga" }, "\(digest)")
            #expect(digest.contains { $0.action == "ask" })
        }
    }

    /// An unresolved contradiction is one "Precisa de você"; it never supersedes (R20: both stay, the newer among them).
    @Test func contradictionBecomesAsk() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        let old = rec("Tabs", "indente o código com tabs", age: 9), new = rec("Espaços", "indente o código com 4 espaços", age: 1)
        fake.output = ops([["op": .string("ask"), "ids": .array([.string(old.id.uuidString), .string(new.id.uuidString)]),
                            "question": .string("Tabs ou espaços?")]])
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [old, new])
            await d.router.consolidate(store)
            #expect(await waitFor(10) { await d.router.digest.since(.distantPast).contains { $0.action == "ask" } })
            let asks = await d.router.digest.since(.distantPast).filter { $0.action == "ask" && !$0.resolved }
            #expect(asks.count == 1 && asks[0].title == "Tabs ou espaços?")
            let (n, o) = (try await status(store, new.id), try await status(store, old.id))
            #expect(n == .active && o == .active)
        }
    }

    /// Review Focus 5: no curator → the deterministic cleanup still runs and is in the digest; the cluster job waits.
    @Test func consolidationWithoutCurator() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let cold = rec("Velha", "nunca lida", age: 70)
            try await put(store, [cold] + tailwind())
            await d.router.consolidate(store)
            #expect(try await status(store, cold.id) == .archived)
            #expect(await d.router.digest.since(.distantPast).map(\.title) == ["Velha"])
            #expect(await d.router.curator.queued(kind: .consolidate).count == 1)
            #expect(!(await d.router.curator.status()).available)
        }
    }

    @Test func trigger20() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            #expect(await d.router.consolidationDue(store))   // never run
            await d.router.consolidate(store)
            #expect(!(await d.router.consolidationDue(store)))
            try await put(store, (0..<19).map { rec("Nova \($0)", "corpo \($0)") })
            #expect(!(await d.router.consolidationDue(store)))
            try await put(store, [rec("Vigésima", "corpo")])
            #expect(await d.router.consolidationDue(store))
            await d.router.consolidate(store)
            #expect(!(await d.router.consolidationDue(store)))
            #expect(await d.router.consolidationDue(store, now: Date().addingTimeInterval(Consolidation.every + 1)))
        }
    }

    @Test func capRespected() async throws {
        let a = try await makeRepo(), b = try await makeRepo(), fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in
            await d.router.curator.setCap(1)
            let sa = await d.router.memory.repo(for: a.path), sb = await d.router.memory.repo(for: b.path)
            try await put(sa, tailwind()); try await put(sb, tailwind())
            await d.router.consolidate(sa); await d.router.consolidate(sb)
            #expect(await waitFor(10) { fake.calls == 1 })
            try await Task.sleep(for: .milliseconds(300))
            let left = await d.router.curator.queued(kind: .consolidate)
            #expect(fake.calls == 1 && left.count == 1)
        }
    }
}
