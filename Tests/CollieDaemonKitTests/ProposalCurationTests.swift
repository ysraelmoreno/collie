import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
@discardableResult
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func rec(_ title: String, subject: String? = nil, status: MemoryStatus = .active, pinned: Bool = false, reviewed: Bool = false,
                 body: String = "", age: TimeInterval = 0) -> MemoryRecord {
    MemoryRecord(kind: .decision, subject: subject ?? title, title: title, body: body, status: status, reviewed: reviewed, pinned: pinned,
                 createdAt: Date().addingTimeInterval(-age))
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func cand(_ r: MemoryRecord) -> CorrectionPayload.Candidate { .init(id: r.id, kind: r.kind, title: r.title, body: r.body) }
/// A proposals job over `proposals` with `candidates`, in `store`.
private func job(_ store: RepoMemory, _ proposals: [MemoryRecord], _ candidates: [MemoryRecord] = []) throws -> CuratorJob {
    let p = ProposalsPayload(family: store.key, lot: nil, lotName: nil, root: store.root?.path,
                             proposals: proposals.map(cand), candidates: candidates.map(cand))
    return CuratorJob(id: UUID(), kind: .proposals, store: store.key, payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)),
                      dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
}
/// A daemon, a repo store holding `recs`, and the router to apply ops with.
private func withStore(_ recs: [MemoryRecord], _ body: (Daemon, RepoMemory) async throws -> Void) async throws {
    let repo = try await makeRepo()
    try await withDaemon { d, _ in
        let store = await d.router.memory.repo(for: repo.path)
        try await store.run { m in for r in recs { try m.store.write(r) } }
        try await body(d, store)
    }
}

@Suite(.serialized) struct ProposalCurationTests {
    @Test func proposalActivated() async throws {
        let a = rec("Use Postgres", subject: "db"), pr = rec("Use SQLite", subject: "db", status: .proposed)
        try await withStore([a, pr]) { d, store in
            let e = try await d.router.applyOps([.activate(id: pr.id, reason: "boa")], job: job(store, [pr], [a]))
            #expect(e.map(\.action) == ["ativado"])
            let recs = try await all(store)
            #expect(recs.first { $0.id == pr.id }?.status == .active)
            #expect(recs.first { $0.id == a.id }.map { ($0.status, $0.supersededBy) } ?? (.active, nil) == (.superseded, pr.id))
        }
    }

    @Test func proposalMerged() async throws {
        let m = rec("Cache no Redis", body: "ttl 60"), pr = rec("Cache Redis ttl", status: .proposed)
        try await withStore([m, pr]) { d, store in
            let e = try await d.router.applyOps([.merge(ids: [pr.id], into: m.id, title: nil, body: "ttl 60; chave por usuário", reason: "mesma coisa")],
                                                job: job(store, [pr], [m]))
            #expect(e.map(\.action) == ["mesclado"])
            let recs = try await all(store)
            #expect(recs.first { $0.id == m.id }?.body == "ttl 60; chave por usuário")
            let p = try #require(recs.first { $0.id == pr.id })
            #expect(p.status == .superseded && p.supersededBy == m.id)
        }
    }

    @Test func proposalDropped() async throws {
        let pr = rec("Trivial", status: .proposed)
        try await withStore([pr]) { d, store in
            let e = try await d.router.applyOps([.drop(id: pr.id, reason: "óbvio")], job: job(store, [pr]))
            #expect(e.map(\.action) == ["descartado"])
            #expect(try await all(store).first?.status == .discarded)
            #expect(try await store.run { try MemoryCleanup.restore(pr.id, store: $0.store) }.status == .active)
        }
    }

    /// Outside a correction, a pinned or user-reviewed record is never changed: the op becomes an ask.
    @Test func pinnedOrUserEditedBecomesAsk() async throws {
        let pin = rec("Fixada", pinned: true), edited = rec("Editada", subject: "x", reviewed: true)
        let pr = rec("Proposta", subject: "x", status: .proposed), pr2 = rec("Outra", status: .proposed)
        try await withStore([pin, edited, pr, pr2]) { d, store in
            let before = try await all(store)
            let e = try await d.router.applyOps([
                .retire(id: pin.id, reason: "fria"),
                .supersede(id: edited.id, by: pr2.id, reason: "nova"),
                .merge(ids: [pr2.id], into: edited.id, title: nil, body: "outro corpo", reason: "igual"),
                .activate(id: pr.id, reason: "substitui a editada"),   // would supersede the reviewed one of its key
            ], job: job(store, [pr, pr2], [pin, edited]))
            #expect(e.map(\.action) == ["ask", "ask", "ask", "ask"], "\(e)")
            #expect(try await all(store).sorted { $0.id.uuidString < $1.id.uuidString } == before.sorted { $0.id.uuidString < $1.id.uuidString })
        }
    }

    /// R20: an ask never supersedes: both stay as they are until the user resolves it.
    @Test func askKeepsNewerActive() async throws {
        let old = rec("Tabs", subject: "indent", age: 100), new = rec("Espaços", subject: "indentação", age: 10)
        try await withStore([old, new]) { d, store in
            let e = try await d.router.applyOps([.ask(ids: [old.id, new.id], question: "Tabs ou espaços?")], job: job(store, [], [old, new]))
            try await d.router.digest.append(e)
            let recs = try await all(store)
            #expect(recs.first { $0.id == new.id }?.status == .active && recs.first { $0.id == old.id }?.status == .active)
            let pending = await d.router.digest.since(.distantPast).filter { $0.action == "ask" && !$0.resolved }
            #expect(pending.count == 1 && pending.first?.title == "Tabs ou espaços?" && pending.first?.before.map(\.id) == [old.id, new.id])
        }
    }

    /// R19: a feedback (the user's rule, active or proposed) is never a proposals job's candidate, target or migration item.
    @Test func proposalsNeverTouchFeedback() async throws {
        let rule = MemoryRecord(kind: .feedback, subject: "pnpm", title: "Sempre use pnpm", body: "pnpm install sempre")
        let waiting = MemoryRecord(kind: .feedback, subject: "c", title: "Correção: nunca npm", status: .proposed)
        let pr = rec("Use npm install", status: .proposed, body: "pnpm install npm")
        try await withStore([rule, waiting, pr]) { d, store in
            await d.router.enqueueProposals([pr.id, waiting.id], store: store)
            let j = try #require(await d.router.curator.queued(kind: .proposals).first)
            let p = try CommandRouter.proposalsPayload(j)
            #expect(p.proposals.map(\.id) == [pr.id] && !p.candidates.contains { $0.id == rule.id }, "\(p)")
            // even if one slipped in: no op on a feedback outside a user's correction
            let e = try await d.router.applyOps([.retire(id: rule.id, reason: "x"), .merge(ids: [pr.id], into: rule.id, title: nil, body: "npm", reason: "x"),
                                                 .activate(id: waiting.id, reason: "x")], job: job(store, [pr, waiting], [rule]))
            #expect(e.isEmpty, "\(e)")
            #expect(try await all(store).first { $0.id == rule.id } == rule)
            #expect(try await all(store).first { $0.id == waiting.id }?.status == .proposed)
        }
    }

    /// R22: the ask entry is filed under the store its records live in.
    @Test func askFiledUnderRecordStore() async throws {
        let g = MemoryRecord(kind: .decision, scope: .global, subject: "g", title: "Global A"), h = MemoryRecord(kind: .decision, scope: .global, subject: "h", title: "Global B")
        try await withStore([]) { d, store in
            try await d.router.memory.global.run { m in try m.store.write(g); try m.store.write(h) }
            let e = try await d.router.applyOps([.ask(ids: [g.id, h.id], question: "Qual?")], job: job(store, [], [g, h]))
            #expect(e.first?.store == "global")
        }
    }

    @Test func expiryOnlyForPending() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(dir: dir)
        let queued = rec("Na fila", status: .proposed, age: 15 * 86400), left = rec("Pergunta esquecida", status: .proposed, age: 15 * 86400)
        let young = rec("Nova", status: .proposed, age: 86400), waiting = rec("Sem pergunta", status: .proposed, age: 15 * 86400)
        for r in [queued, left, young, waiting] { try store.write(r) }
        // R18: only "Precisa de você" items expire; one queued again is kept, one in no ask waits
        let gone = try MemoryCleanup.expireProposals(store: store, keep: [queued.id], asked: [queued.id, left.id, young.id], now: Date())
        #expect(gone.map(\.id) == [left.id])
        #expect(Set(store.all().records.filter { $0.status == .proposed }.map(\.id)) == [queued.id, young.id, waiting.id])
    }

    @Test func migrationOnce() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let marker = p.root.appendingPathComponent("curator/migrated")
            #expect(FileManager.default.fileExists(atPath: marker.path))   // first start ran it (nothing to queue)
            try FileManager.default.removeItem(at: marker)
            _ = try await term(d, p, "A", cwd: repo)
            let store = await d.router.memory.repo(for: repo.path)
            try await store.run { m in for i in 0..<5 { try m.store.write(rec("Proposta \(i)", status: .proposed)) } }
            await d.router.migrateProposals()
            let jobs = await d.router.curator.queued(kind: .proposals)
            #expect(jobs.count == 1 && jobs.first?.store == store.key)
            #expect(try jobs.first.map { try CommandRouter.proposalsPayload($0).proposals.count } == 5)
            await d.router.migrateProposals()   // marker written: never again
            #expect(await d.router.curator.queued(kind: .proposals).count == 1)
            // R22: a refused enqueue leaves no marker (the migration runs again next start); proposed feedback is skipped
            try FileManager.default.removeItem(at: marker)
            try await store.run { m in try m.store.write(MemoryRecord(kind: .feedback, subject: "f", title: "Correção", status: .proposed)) }
            await d.router.migrateProposals()   // the same 5 are queued already: refused
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(await d.router.curator.queued(kind: .proposals).count == 1)
        }
    }

    @Test func captureEnqueuesProposals() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await call(p, t, "work.task.add", ["title": "OAuth"])
            try await call(p, t, "work.task.defer", ["task": "OAuth", "reason": "falta a chave do Google"])
            try await call(p, t, "work.done", ["reason": "sessões no Redis"])
            #expect(await waitFor(10) { await d.router.curator.queued(kind: .proposals).count == 1 })
            let job = try #require(await d.router.curator.queued(kind: .proposals).first)
            let store = await d.router.memory.repo(for: repo.path)
            let ids = Set(try await all(store).filter { $0.status == .proposed }.map(\.id))
            #expect(Set(try CommandRouter.proposalsPayload(job).proposals.map(\.id)) == ids && ids.count == 2)
        }
    }

    @Test func agentSavesUnchanged() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let r = try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use SQLite"])
            #expect(r.ok)
            #expect(try await all(d.router.memory.repo(for: repo.path)).map(\.status) == [.active])
            try await Task.sleep(for: .milliseconds(200))
            #expect(await d.router.curator.queued(kind: .proposals).isEmpty)
            #expect(await d.router.curator.queued(kind: .correction).isEmpty)
        }
    }
}
