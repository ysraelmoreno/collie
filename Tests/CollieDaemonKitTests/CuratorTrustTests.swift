import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let full = CuratedBy(provider: "claude", model: "haiku", trust: .full)
private let limited = CuratedBy(provider: "cursor", model: "", trust: .limited)

private func rec(_ title: String, subject: String? = nil, status: MemoryStatus = .active, pinned: Bool = false, body: String = "") -> MemoryRecord {
    MemoryRecord(kind: .decision, subject: subject ?? title, title: title, body: body, status: status, pinned: pinned)
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func one(_ s: RepoMemory, _ id: UUID) async throws -> MemoryRecord? { try await all(s).first { $0.id == id } }
private func cand(_ r: MemoryRecord) -> CorrectionPayload.Candidate { .init(id: r.id, kind: r.kind, title: r.title, body: r.body) }
/// A proposals job over `proposals` with `candidates`, in `store`.
private func job(_ store: RepoMemory, _ proposals: [MemoryRecord], _ candidates: [MemoryRecord] = []) throws -> CuratorJob {
    let p = ProposalsPayload(family: store.key, lot: nil, lotName: nil, root: store.root?.path,
                             proposals: proposals.map(cand), candidates: candidates.map(cand))
    return CuratorJob(id: UUID(), kind: .proposals, store: store.key, payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)),
                      dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
}
/// Through the store: the daemon wrote it (verified in the ledger).
private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { try m.store.write(r) } } }
/// By hand, past the store (an agent writing in `.collie/memory`, a clone): not in the ledger.
private func plant(_ s: RepoMemory, _ r: MemoryRecord) throws {
    let f = s.store.dir.appendingPathComponent(MemoryFile.fileName(r))
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(MemoryFile.render(r).utf8).write(to: f)
}
/// A daemon and a repo store holding `recs` (written by the daemon), its first read done (adoption behind us).
private func withStore(_ recs: [MemoryRecord], configure: (inout DaemonConfig) -> Void = { _ in },
                       _ body: (Daemon, Paths, RepoMemory, URL) async throws -> Void) async throws {
    let repo = try await makeRepo()
    try await withDaemon(configure: configure) { d, p in
        let store = await d.router.memory.repo(for: repo.path)
        try await put(store, [rec("Âncora")] + recs)
        _ = try await all(store)
        try await body(d, p, store, repo)
    }
}
private func verified(_ d: Daemon, _ s: RepoMemory, _ id: UUID) async throws -> Bool {
    guard let r = try await one(s, id) else { return false }
    return d.router.memory.provenance.isVerified(r)
}

/// Task 10 (spec 2026-11-17 curator provider §2.3): a limited curator proposes and asks, never decides.
@Suite(.serialized, .curatorPT) struct CuratorTrustTests {
    @Test func limitedCreateIsProposed() async throws {
        try await withStore([]) { d, _, store, _ in
            let j = try job(store, [])
            let new = CuratorNew(kind: .decision, scope: .project, subject: "cache", title: "Cache no Redis", body: "ttl 60", why: "", howToApply: "")
            _ = try await d.router.applyOps([.create(new)], job: j, curatedBy: limited)
            let r = try #require(try await one(store, j.id))
            #expect(r.status == .proposed && r.curatedBy == limited)
        }
    }

    @Test func limitedActivateAsks() async throws {
        let pr = rec("Use SQLite", status: .proposed)
        try await withStore([pr]) { d, _, store, _ in
            let e = try await d.router.applyOps([.activate(id: pr.id, reason: "boa")], job: job(store, [pr]), curatedBy: limited)
            #expect(e.map(\.action) == ["ask"])
            #expect(try await one(store, pr.id)?.status == .proposed)
        }
    }

    @Test func limitedRetireAsks() async throws {
        let a = rec("Use Postgres")
        try await withStore([a]) { d, _, store, _ in
            let e = try await d.router.applyOps([.retire(id: a.id, reason: "velha")], job: job(store, [], [a]), curatedBy: limited)
            #expect(e.map(\.action) == ["ask"])
            #expect(try await one(store, a.id)?.status == .active)
        }
    }

    @Test func limitedDropAndSupersedeAsk() async throws {
        let pr = rec("Trivial", status: .proposed), a = rec("Velha", subject: "v"), b = rec("Nova", subject: "n")
        try await withStore([pr, a, b]) { d, _, store, _ in
            let e = try await d.router.applyOps([.drop(id: pr.id, reason: "x"), .supersede(id: a.id, by: b.id, reason: "y")],
                                                job: job(store, [pr], [a, b]), curatedBy: limited)
            #expect(e.map(\.action) == ["ask", "ask"])
            #expect(try await one(store, pr.id)?.status == .proposed)
            #expect(try await one(store, a.id)?.status == .active)
        }
    }

    @Test func limitedMergeAsks() async throws {
        let m = rec("Cache no Redis", body: "ttl 60"), pr = rec("Cache Redis ttl", status: .proposed)
        try await withStore([m, pr]) { d, _, store, _ in
            let e = try await d.router.applyOps([.merge(ids: [pr.id], into: m.id, title: nil, body: "ttl 60; chave", reason: "mesma")],
                                                job: job(store, [pr], [m]), curatedBy: limited)
            #expect(e.map(\.action) == ["ask"])
            #expect(try await one(store, m.id)?.body == "ttl 60")
            #expect(try await one(store, pr.id)?.status == .proposed)
        }
    }

    /// A limited curator's new pitfall class is a proposal and absorbs nothing; a bump of an existing class applies.
    @Test func limitedPitfallClassIsProposed() async throws {
        let cls = MemoryRecord(kind: .pitfall, subject: "symlink", title: "Symlink quebra o build", hits: 1)
        try await withStore([cls]) { d, _, store, _ in
            let p = PitfallPayload(family: store.key, scope: .project, instance: nil, review: .init(file: "r.md", excerpt: "x"), classes: [])
            let j = CuratorJob(id: UUID(), kind: .pitfall, store: store.key, payload: .null, dedupe: "x", createdAt: Date(), attempts: 0)
            _ = try await d.router.applyPitfallOps([.create(CuratorNew(kind: .pitfall, scope: .project, subject: "corrida", title: "Corrida",
                                                                       body: "", why: "", howToApply: "")),
                                                    .bump(id: cls.id, example: "de novo")], p, job: j, store: store, curatedBy: limited)
            #expect(try await one(store, j.id)?.status == .proposed)
            #expect(try await one(store, cls.id)?.hits == 2)
        }
    }

    /// The same ops from a full curator apply as before.
    @Test func fullUnchanged() async throws {
        let pr = rec("Use SQLite", status: .proposed), a = rec("Velha", subject: "v")
        try await withStore([pr, a]) { d, _, store, _ in
            let e = try await d.router.applyOps([.activate(id: pr.id, reason: "boa"), .retire(id: a.id, reason: "x")],
                                                job: job(store, [pr], [a]), curatedBy: full)
            #expect(e.map(\.action) == ["ativado", "aposentado"])
        }
    }

    /// A limited "valid" decides nothing: the contest stays (only the objective check archives).
    @Test func limitedValidKeepsContest() async throws {
        let a = rec("Use Postgres")
        try await withStore([a]) { d, _, store, _ in
            await d.router.memory.lifecycle.update(a.id, now: Date()) { e in
                e.flags.append(LifecycleFlag(verdict: .wrong, session: "s9", day: "2026-11-17", reason: "stale")); e.contestedNow = true; e.store = store.key
            }
            let r = try #require(try await one(store, a.id))
            let j = CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: MemoryVerify.payload(memory: r, flags: [], facts: []),
                               dedupe: "", createdAt: Date(), attempts: 0)
            try await d.router.runVerifyJob(j) { _ in
                var o = CuratorOutput(json: .object(["ops": .array([])]), inputTokens: nil, outputTokens: nil, costUSD: nil); o.curatedBy = limited; return o
            }
            let e = await d.router.memory.lifecycle.entry(a.id)
            #expect(e?.contestedNow == true && e?.flags.count == 1 && e?.recheckedAt == nil)
        }
    }

    @Test func limitedNoPromotionQueued() async throws {
        let cursor = FakeCurator(); cursor.avail = .unavailable("sem modelo")
        cursor.info = CuratorProviderInfo(provider: .cursor, trust: .limited, destination: "Cursor", structuredOutput: false, reportsUsage: false,
                                          timeout: .seconds(120), inputMax: 12_000)
        let claude = FakeCurator(); claude.avail = .unavailable("sem modelo")
        let a = rec("Use Postgres")
        try await withStore([a], configure: { $0.curatorRunners = [.claude: claude, .cursor: cursor] }) { d, p, _, repo in
            // a terminal in the repo: its store is one the verify queue knows
            let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
                "name": .string("A"), "preset": .string("shell"), "cwd": .string(repo.path)]), to: p.socket, timeoutSeconds: 60)
            #expect(r.ok, "\(r)")
            await d.router.curator.consent(.cursor); try await d.router.curator.setProvider(.cursor, model: nil)
            #expect(await d.router.enqueueVerify(a.id, kind: .verifyPromotion) == false)
            #expect(await d.router.curator.queued(kind: .verifyPromotion).isEmpty)
            try await d.router.curator.setProvider(.claude, model: nil)
            #expect(await d.router.enqueueVerify(a.id, kind: .verifyPromotion) == true)
        }
    }
}
