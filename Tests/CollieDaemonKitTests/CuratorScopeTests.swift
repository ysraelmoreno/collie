import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func create(scope: String, kind: String = "pitfall", title: String = "Slug por regex ASCII apaga letras",
                    body: String = "Evite regex ASCII.") -> [String: JSONValue] {
    ["op": .string("create"), "kind": .string(kind), "scope": .string(scope), "subject": .string(title), "title": .string(title),
     "body": .string(body), "why": .string(""), "howToApply": .string("")]
}

private func job(_ p: CorrectionPayload) throws -> CuratorJob {
    CuratorJob(id: UUID(), kind: .correction, store: p.family,
               payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)), dedupe: "", createdAt: Date(), attempts: 0)
}

private func payload(family: String, lot: UUID?, root: String?) -> CorrectionPayload {
    CorrectionPayload(terminal: UUID(), name: "A", family: family, lot: lot, lotName: nil, root: root, prompt: "não, corrija o slug",
                      lastTurn: nil, work: nil, candidates: [], proposal: nil, user: true, likelyUser: nil)
}

private func apply(_ d: Daemon, _ p: CorrectionPayload, _ op: [String: JSONValue]) async throws -> [DigestEntry] {
    let ops = CuratorOps.validate(.object(["ops": .array([.object(op)])]), scope: CommandRouter.correctionScope(p)).ops
    return try await d.router.applyOps(ops, job: try job(p))
}

@Suite(.serialized) struct CuratorScopeTests {
    /// A lot job: the model asking `project` is written as `lot` of that lot (the owner promotes with `memory promote`).
    @Test func projectInLotBecomesLot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let lot = UUID()
            let store = await d.router.memory.lotStore(lot)
            let pl = payload(family: store.key, lot: lot, root: repo.path)
            let rows = try await apply(d, pl, create(scope: "project"))
            let recs = try await store.run { $0.store.all().records }
            #expect(recs.count == 1 && recs[0].scope == .lot && recs[0].lotId == lot, "\(recs)")
            #expect(rows.contains { $0.reason.contains("lote") })
            #expect(try await d.router.memory.repo(for: repo.path).run { $0.store.all().records }.isEmpty)
        }
    }

    /// No lot: `project` as before.
    @Test func projectWithoutLotStaysProject() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            let pl = payload(family: store.key, lot: nil, root: repo.path)
            _ = try await apply(d, pl, create(scope: "project", body: "Evite regex ASCII em Sources/Slug.swift."))
            let recs = try await store.run { $0.store.all().records }
            #expect(recs.count == 1 && recs[0].scope == .project && recs[0].status == .active, "\(recs)")
        }
    }

    /// Only about files under `.collie/` of the worktree: a proposal, not active.
    @Test func onlyScratchPathsIsProposed() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            let pl = payload(family: store.key, lot: nil, root: repo.path)
            let rows = try await apply(d, pl, create(scope: "project", body: "Em .collie/cursor-test/slug.py o regex apaga letras; veja \(repo.path)/.collie/x/y.py."))
            let recs = try await store.run { $0.store.all().records }
            #expect(recs.count == 1 && recs[0].status == .proposed, "\(recs)")
            #expect(!rows.isEmpty)
            // a tracked path next to a scratch one: stays active
            _ = try await apply(d, pl, create(scope: "project", title: "Outro caso", body: "Veja .collie/a/b.py e Sources/Slug.swift."))
            let other = try await store.run { $0.store.all().records.first { $0.title == "Outro caso" } }
            #expect(other?.status == .active)
        }
    }
}
