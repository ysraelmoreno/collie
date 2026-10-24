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
}
