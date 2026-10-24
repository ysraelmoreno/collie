import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private struct Term { var id: String; var token: String }
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": name, "preset": "shell", "cwd": cwd.path])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func savedId(_ r: Response) -> UUID? {
    if case .object(let o)? = r.result, case .string(let s)? = o["id"] { return UUID(uuidString: s) }
    return nil
}
private func ops(_ list: [[String: JSONValue]]) -> CuratorOutput {
    CuratorOutput(json: .object(["ops": .array(list.map { .object($0) })]), inputTokens: 10, outputTokens: 5, costUSD: 0.0001)
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func klass(_ title: String, subject: String, hits: Int, examples: [String] = [], scope: MemoryScope = .project, lot: UUID? = nil) -> MemoryRecord {
    MemoryRecord(kind: .pitfall, scope: scope, lotId: lot, subject: subject, title: title,
                 body: PitfallClasses.withExamples("Cheque o caminho real antes de usar.", examples), hits: hits)
}

@Suite(.serialized) struct PitfallClassTests {
    @Test func bumpKeepsThreeNewest() {
        var c = klass("Symlink seguido", subject: "symlink", hits: 3, examples: ["b", "c", "d"])
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        PitfallClasses.bump(&c, example: "a " + String(repeating: "x", count: 300), now: t)
        #expect(c.hits == 4 && c.updatedAt == t)
        let ex = PitfallClasses.examples(c.body)
        #expect(ex.count == 3 && ex[0].hasPrefix("a xx") && ex[0].unicodeScalars.count <= 200 && Array(ex[1...]) == ["b", "c"], "\(ex)")
        #expect(c.body.hasPrefix("Cheque o caminho real antes de usar.\n\nExemplos:\n- a"))
    }

    @Test func sameSubjectBumpsWithoutModel() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            let c = klass("Symlink seguido num caminho checado", subject: "symlink", hits: 2, examples: ["link em /tmp"])
            try await store.run { try $0.store.write(c) }
            let r = try await admin(d, p, "memory.save", ["kind": "pitfall", "subject": "Symlink", "title": "Segui um link em ~/.ssh", "repo": repo.path])
            let id = try #require(savedId(r), "\(r)")
            let recs = try await all(store)
            let k = try #require(recs.first { $0.id == c.id })
            #expect(k.status == .active && k.hits == 3 && PitfallClasses.examples(k.body).first == "Segui um link em ~/.ssh", "\(k)")
            let n = try #require(recs.first { $0.id == id })
            #expect(n.status == .superseded && n.supersededBy == c.id)
            let queued = await d.router.curator.queued(kind: .pitfall)
            #expect(fake.calls == 0 && queued.isEmpty)
            #expect(await d.router.digest.since(.distantPast).map(\.action) == ["mesclado"])
        }
    }

    @Test func curatorBumpsClass() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        let c = klass("Symlink seguido num caminho checado", subject: "symlink", hits: 3, examples: ["link em /tmp", "link no cache"])
        fake.output = ops([["op": .string("bump"), "id": .string(c.id.uuidString), "example": .string("symlink em ~/.ssh")]])
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await store.run { try $0.store.write(c) }
            let r = try await admin(d, p, "memory.save", ["kind": "pitfall", "subject": "ssh config", "title": "Abri ~/.ssh/config pelo link",
                                                          "repo": repo.path])
            let id = try #require(savedId(r), "\(r)")
            #expect(await waitFor(10) { (try? await all(store))?.first { $0.id == id }?.status == .superseded })
            let recs = try await all(store)
            let k = try #require(recs.first { $0.id == c.id })
            #expect(k.hits == 4 && PitfallClasses.examples(k.body) == ["symlink em ~/.ssh", "link em /tmp", "link no cache"], "\(k.body)")
            #expect(recs.first { $0.id == id }?.supersededBy == c.id)
            #expect(fake.calls == 1 && fake.inputs[0].contains(c.id.uuidString) && fake.inputs[0].contains("Abri ~/.ssh/config pelo link"))
            #expect(await d.router.digest.since(.distantPast).map(\.action) == ["mesclado"])
        }
    }

    @Test func curatorCreatesClass() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        fake.output = ops([["op": .string("create"), "kind": .string("pitfall"), "scope": .string("project"), "subject": .string("corrida check-then-use"),
                            "title": .string("Corrida entre checar e usar"), "body": .string("Abra com O_NOFOLLOW em vez de checar antes.")]])
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            let r = try await admin(d, p, "memory.save", ["kind": "pitfall", "subject": "stat antes do open", "title": "stat e depois open no mesmo caminho",
                                                          "repo": repo.path])
            let id = try #require(savedId(r), "\(r)")
            #expect(await waitFor(10) { (try? await all(store))?.first { $0.id == id }?.status == .superseded })
            let recs = try await all(store)
            let k = try #require(recs.first { $0.hits != nil })
            #expect(k.hits == 1 && k.status == .active && k.title == "Corrida entre checar e usar" && k.scope == .project)
            #expect(PitfallClasses.examples(k.body) == ["stat e depois open no mesmo caminho"], "\(k.body)")
            #expect(recs.first { $0.id == id }?.supersededBy == k.id)
            #expect(await d.router.digest.since(.distantPast).map(\.action) == ["aprendido"])
        }
    }

    /// Each source queues one pitfall job (the curator is unavailable: they wait).
    @Test func sourcesEnqueue() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            // an agent's save
            let t = try await term(d, p, "T", cwd: repo)
            #expect(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "a", "title": "Rodei a suíte inteira"]).ok)
            #expect(await d.router.curator.queued(kind: .pitfall).count == 1)
            // an abandoned task's captured pitfall
            #expect(try await call(p, t, "work.task.add", ["title": "OAuth"]).ok)
            #expect(try await call(p, t, "work.task.drop", ["task": "OAuth", "reason": "o provedor bloqueia números novos"]).ok)
            #expect(try await call(p, t, "work.done", ["reason": "fim"]).ok)
            #expect(await waitFor(10) { await d.router.curator.queued(kind: .pitfall).count == 2 })
            // a correction whose op created a pitfall (user provenance: active)
            let cp = CorrectionPayload(terminal: UUID(uuidString: t.id)!, name: "T", family: store.key, lot: nil, lotName: nil, root: repo.path,
                                       prompt: "não, nunca rode o claude real nos testes", lastTurn: nil, work: nil, candidates: [], proposal: nil, user: true)
            let job = CuratorJob(id: UUID(), kind: .correction, store: store.key, payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cp)),
                                 dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
            let out = ops([["op": .string("create"), "kind": .string("pitfall"), "scope": .string("project"), "subject": .string("claude real"),
                            "title": .string("Rodar o claude real nos testes")]])
            try await d.router.runLearningJob(job, call: { _ throws(ProtocolError) in out })
            #expect(try await all(store).first { $0.id == job.id }?.kind == .pitfall)
            #expect(await d.router.curator.queued(kind: .pitfall).count == 3)
        }
    }

    /// A lot member's pitfall job is scoped to the lot; its candidate classes come from the lot store only.
    @Test func lotPitfallStaysInLot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            let lid = try #require(await d.router.ws.lots.first { $0.name == "Login" }?.id)
            let project = await d.router.memory.repo(for: repo.path), lot = await d.router.memory.lotStore(lid)
            let pc = klass("Classe do projeto", subject: "p", hits: 5)
            try await project.run { try $0.store.write(pc) }
            let lc = klass("Classe do lote", subject: "l", hits: 2, scope: .lot, lot: lid)
            try await lot.run { try $0.store.write(lc) }
            #expect(try await call(p, a, "memory.save", ["kind": "pitfall", "subject": "x", "title": "Erro no lote"]).ok)
            let j = try #require(await d.router.curator.queued(kind: .pitfall).first)
            let pl = try CommandRouter.pitfallPayload(j)
            #expect(j.store == lot.key && pl.family == lot.key && pl.classes.map(\.id) == [lc.id], "\(pl)")
            #expect(CommandRouter.pitfallScope(pl).scopes == [.lot] && !CommandRouter.pitfallScope(pl).ids.contains(pc.id))
        }
    }

    /// R6: a correction without the user's provenance writes a proposed pitfall; nothing activates or absorbs it.
    @Test func proposedCorrectionPitfallStaysProposed() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let c = klass("Claude real nos testes", subject: "claude real", hits: 2)
            try await store.run { try $0.store.write(c) }
            let cp = CorrectionPayload(terminal: UUID(), name: "T", family: store.key, lot: nil, lotName: nil, root: repo.path,
                                       prompt: "não, nunca rode o claude real", lastTurn: nil, work: nil, candidates: [], proposal: nil, user: false)
            let job = CuratorJob(id: UUID(), kind: .correction, store: store.key, payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cp)),
                                 dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
            let out = ops([["op": .string("create"), "kind": .string("pitfall"), "scope": .string("project"), "subject": .string("claude real"),
                            "title": .string("Rodar o claude real")]])
            try await d.router.runLearningJob(job, call: { _ throws(ProtocolError) in out })
            await d.router.enqueuePitfall(job.id, store: store)
            let recs = try await all(store)
            #expect(recs.first { $0.id == job.id }?.status == .proposed)
            #expect(recs.first { $0.id == c.id }?.hits == 2)
            #expect(await d.router.curator.queued(kind: .pitfall).isEmpty)
        }
    }

    /// R7: a pinned or user-edited pitfall is never absorbed or replaced: an ask instead.
    @Test func usersPitfallNeverAbsorbed() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let c = klass("Symlink seguido", subject: "symlink", hits: 2)
            let mine = MemoryRecord(kind: .pitfall, subject: "symlink", title: "Minha nota fixada", pinned: true)
            let edited = MemoryRecord(kind: .pitfall, subject: "corrida", title: "Editada por mim", reviewed: true)
            try await store.run { try $0.store.write(c); try $0.store.write(mine); try $0.store.write(edited) }
            await d.router.enqueuePitfall(mine.id, store: store)
            // a curator create naming the edited one's subject
            let p = PitfallPayload(family: store.key, scope: .project, instance: nil, review: .init(file: "r.md", excerpt: "x"), classes: [])
            let j = CuratorJob(id: UUID(), kind: .pitfall, store: store.key, payload: .null, dedupe: "x", createdAt: Date(), attempts: 0)
            let e = try await d.router.applyPitfallOps([.create(CuratorNew(kind: .pitfall, scope: .project, subject: "corrida", title: "Corrida",
                                                                           body: "", why: "", howToApply: ""))], p, job: j, store: store)
            #expect(e.map(\.action) == ["ask"], "\(e)")
            let recs = try await all(store)
            #expect(recs.first { $0.id == mine.id }?.status == .active && recs.first { $0.id == edited.id }?.status == .active)
            #expect(recs.first { $0.id == c.id }?.hits == 2 && !recs.contains { $0.id == j.id })
            #expect(await d.router.digest.since(.distantPast).map(\.action) == ["ask"])
        }
    }

    /// R9: at most 10 bumps a job, one per class.
    @Test func bumpsCapped() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let cs = (0..<12).map { klass("Classe \($0)", subject: "c\($0)", hits: 1) }
            try await store.run { m in for c in cs { try m.store.write(c) } }
            let p = PitfallPayload(family: store.key, scope: .project, instance: nil, review: .init(file: "r.md", excerpt: "x"),
                                   classes: PitfallClasses.summaries(cs))
            let j = CuratorJob(id: UUID(), kind: .pitfall, store: store.key, payload: .null, dedupe: "x", createdAt: Date(), attempts: 0)
            let bumps = [CuratorOp.bump(id: cs[0].id, example: "a"), .bump(id: cs[0].id, example: "b")] + cs.map { .bump(id: $0.id, example: "e") }
            _ = try await d.router.applyPitfallOps(bumps, p, job: j, store: store)
            let hits = try await all(store).compactMap(\.hits)
            #expect(hits.reduce(0, +) - 12 == 10 && hits.max() == 2, "\(hits)")
            #expect(CommandRouter.pitfallScope(p).maxOps >= 10)
        }
    }
}
