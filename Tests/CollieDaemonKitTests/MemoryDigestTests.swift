import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func asJob(_ kind: CuratorJobKind, _ v: some Encodable) throws -> CuratorJob {
    CuratorJob(id: UUID(), kind: kind, store: "", payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v)),
               dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
}
private let rule = CuratorNew(kind: .feedback, scope: .project, subject: "banco", title: "Use SQLite", body: "", why: "", howToApply: "")

/// A daemon, a repo store holding `recs`; the correction job a user typed in that repo.
private func withRepo(_ recs: [MemoryRecord], _ body: (Daemon, Paths, RepoMemory, CuratorJob) async throws -> Void) async throws {
    let repo = try await makeRepo()
    try await withDaemon { d, p in
        let store = await d.router.memory.repo(for: repo.path)
        try await store.run { m in for r in recs { try m.store.write(r) } }
        let job = try asJob(.correction, CorrectionPayload(terminal: UUID(), name: "A", family: store.key, lot: nil, lotName: nil,
                                                           root: store.root?.path, prompt: "não, use SQLite", lastTurn: nil, work: nil,
                                                           candidates: [], proposal: nil, user: true))
        try await body(d, p, store, job)
    }
}

@Suite(.serialized) struct MemoryDigestTests {
    @Test func undoRestoresBefore() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres", pinned: true)
        try await withRepo([x]) { d, p, store, job in
            let entries = try await d.router.applyOps([.create(rule), .supersede(id: x.id, by: nil, reason: "corrigido")], job: job)
            try await d.router.digest.append(entries)
            let retired = try #require(entries.first { $0.action == "aposentado" })
            let r = try await admin(d, p, "memory.undo", ["entry": retired.id.uuidString])
            #expect(r.ok, "\(r)")
            let recs = try await all(store)
            #expect(recs.first { $0.id == x.id } == x)   // active and pinned again, as it was
            #expect(recs.first { $0.kind == .feedback }?.status == .discarded)
            #expect(await d.router.digest.since(.distantPast).first { $0.id == retired.id }?.undone == true)
            #expect(try await admin(d, p, "memory.undo", ["entry": retired.id.uuidString]).ok)   // a no-op
            #expect(try await all(store) == recs)
        }
    }

    @Test func undoAfterLaterChangeRefused() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres")
        try await withRepo([x]) { d, p, store, job in
            let entries = try await d.router.applyOps([.create(rule), .supersede(id: x.id, by: nil, reason: "corrigido")], job: job)
            try await d.router.digest.append(entries)
            try await Task.sleep(for: .seconds(1.2))
            try await store.run { m in   // the user edits X afterwards
                var r = m.store.all().records.first { $0.id == x.id }!; r.title = "Editada"; r.updatedAt = Date(); try m.store.write(r)
            }
            let retired = try #require(entries.first { $0.action == "aposentado" })
            let r = try await admin(d, p, "memory.undo", ["entry": retired.id.uuidString])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "a memória mudou depois; desfaça pelo histórico", "\(r)")
        }
    }

    @Test func resolveKeepsOlder() async throws {
        let old = MemoryRecord(kind: .decision, subject: "indent", title: "Tabs", createdAt: Date().addingTimeInterval(-100))
        let new = MemoryRecord(kind: .decision, subject: "indentação", title: "Espaços", createdAt: Date().addingTimeInterval(-10))
        try await withRepo([old, new]) { d, p, store, _ in
            let job = try asJob(.proposals, ProposalsPayload(family: store.key, lot: nil, lotName: nil, root: store.root?.path, proposals: [],
                                                             candidates: [old, new].map { .init(id: $0.id, kind: $0.kind, title: $0.title, body: "") }))
            let entries = try await d.router.applyOps([.ask(ids: [old.id, new.id], question: "Tabs ou espaços?")], job: job)
            try await d.router.digest.append(entries)
            let ask = try #require(entries.first)
            let r = try await admin(d, p, "memory.resolve", ["entry": ask.id.uuidString, "keep": "older"])
            #expect(r.ok, "\(r)")
            let recs = try await all(store)
            #expect(recs.first { $0.id == old.id }?.status == .active)
            let n = try #require(recs.first { $0.id == new.id })
            #expect(n.status == .superseded && n.supersededBy == old.id)
            #expect(await d.router.digest.since(.distantPast).first { $0.id == ask.id }?.resolved == true)
            // the digest command lists it, with the curator line
            let dg = try await admin(d, p, "memory.digest")
            guard case .object(let o)? = dg.result, case .array(let es)? = o["entries"], case .object(let c)? = o["curator"] else { Issue.record("\(dg)"); return }
            #expect(es.count == 1 && c["cap"] == .number(40))
        }
    }

    /// M1: a correction that retires X and Y (Y pinned) is one job: Desfazer on any of its rows restores X and Y as they
    /// were and discards the rule; every row of the job is marked undone.
    @Test func undoJobRestoresAll() async throws {
        for pick in ["aposentado", "aprendido"] {
            let x = MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres")
            let y = MemoryRecord(kind: .decision, subject: "pool", title: "Pool de 20", pinned: true)
            try await withRepo([x, y]) { d, p, store, job in
                let entries = try await d.router.applyOps([.create(rule), .supersede(id: x.id, by: nil, reason: "corrigido"),
                                                           .supersede(id: y.id, by: nil, reason: "corrigido")], job: job)
                try await d.router.digest.append(entries)
                let ruleId = try #require(entries.first { $0.action == "aprendido" }?.created.first)
                #expect(entries.allSatisfy { $0.job == job.id })
                #expect(entries.filter { $0.action == "aposentado" }.allSatisfy { $0.created.isEmpty && $0.by == ruleId })
                let row = try #require(entries.first { $0.action == pick && ($0.before.first?.id == x.id || pick == "aprendido") })
                let r = try await admin(d, p, "memory.undo", ["entry": row.id.uuidString])
                #expect(r.ok, "\(pick): \(r)")
                let recs = try await all(store)
                #expect(recs.first { $0.id == x.id } == x, "\(pick)")
                #expect(recs.first { $0.id == y.id } == y, "\(pick)")   // active and pinned again
                #expect(recs.first { $0.id == ruleId }?.status == .discarded, "\(pick)")
                #expect(await d.router.digest.since(.distantPast).allSatisfy(\.undone), "\(pick)")
            }
        }
    }

    /// L1: a correction's rule replacing a pinned same-subject rule leaves it superseded (never active again) and unpinned.
    @Test func pinnedSameSubjectStaysSuperseded() async throws {
        let old = MemoryRecord(kind: .feedback, subject: "banco", title: "Use Postgres", pinned: true)
        try await withRepo([old]) { d, _, store, job in
            _ = try await d.router.applyOps([.create(rule)], job: job)
            let recs = try await all(store)
            let o = try #require(recs.first { $0.id == old.id })
            #expect(o.status == .superseded && !o.pinned && o.supersededBy == job.id, "\(o)")
            #expect(recs.filter { $0.status == .active }.map(\.id) == [job.id])
        }
    }

    /// L4: an open ask older than the panel's 7 days is still listed (its proposals expire at 14).
    @Test func openAskOutlivesWindow() async throws {
        try await withRepo([]) { d, p, store, _ in
            let old = Date().addingTimeInterval(-10 * 86400)
            try await d.router.digest.append([
                DigestEntry(id: UUID(), at: old, action: "ask", title: "Tabs ou espaços?", reason: "", store: store.key, created: [], before: [],
                            undone: false, resolved: false),
                DigestEntry(id: UUID(), at: old, action: "aprendido", title: "velho", reason: "", store: store.key, created: [], before: [],
                            undone: false, resolved: false)])
            let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86400))
            let dg = try await admin(d, p, "memory.digest", ["since": since])
            guard case .object(let o)? = dg.result, case .array(let es)? = o["entries"] else { Issue.record("\(dg)"); return }
            #expect(es.count == 1, "\(es)")
        }
    }
}
