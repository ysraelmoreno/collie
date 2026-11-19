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
            #expect(es.count == 1 && c["cap"] == nil)   // no daily cap by default
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

@Suite(.serialized) struct MemoryDigestScopeTests {
    private func entry(_ title: String, store: String) -> DigestEntry {
        DigestEntry(id: UUID(), at: Date(), action: "aprendido", title: title, reason: "", store: store, created: [], before: [], undone: false, resolved: false)
    }

    /// The Aprendizado tab asks `memory.digest` with the picked store as `repo`: another project's learnings must not show.
    @Test func digestOfAPickedRepoHasOnlyItsOwnAndTheLots() async throws {
        let a = try await makeRepo(), b = try await makeRepo()
        try await withDaemon { d, p in
            let sa = await d.router.memory.repo(for: a.path), sb = await d.router.memory.repo(for: b.path)
            try await d.router.digest.append([entry("de A", store: sa.key), entry("de B", store: sb.key),
                                              entry("de um lote", store: "lot:\(UUID().uuidString.lowercased())"), entry("global", store: "global")])
            func titles(_ args: [String: String]) async throws -> Set<String> {
                let r = try await admin(d, p, "memory.digest", args)
                guard case .object(let o)? = r.result, case .array(let es)? = o["entries"] else { throw ProtocolError(code: .internal, message: "\(r)") }
                return Set(es.compactMap { if case .object(let e) = $0, case .string(let t)? = e["title"] { t } else { nil } })
            }
            #expect(try await titles(["repo": a.path]) == ["de A", "de um lote"])
            #expect(try await titles(["repo": b.path]) == ["de B", "de um lote"])
            #expect(try await titles([:]) == ["de A", "de B", "de um lote", "global"])   // no store named: everything (the daily notification)
        }
    }

    @Test func digestListsPromotionAndUndoRestoresIt() async throws {
        var x = MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres")
        x.createdAt = Date().addingTimeInterval(-40 * 86_400)
        try await withRepo([x]) { d, p, store, _ in
            let lc = d.router.memory.lifecycle, onDisk = try await all(store)
            var uses: Set<UseKey> = []
            let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
            for i in 0..<8 { uses.insert(UseKey(day: f.string(from: Date().addingTimeInterval(-[20.0, 14, 7, 1][i % 4] * 86_400)), session: "u\(i)")) }
            await lc.update(x.id, now: Date().addingTimeInterval(-30 * 86_400)) { $0.tier = .earned; $0.usefulUses = uses; $0.store = store.key }
            let job = CuratorJob(id: UUID(), kind: .verifyPromotion, store: store.key,
                                 payload: MemoryVerify.payload(memory: x, flags: [], facts: []), dedupe: "", createdAt: Date(), attempts: 0)
            try await d.router.runVerifyJob(job) { _ in CuratorOutput(json: .object(["ops": .array([])]), inputTokens: 1, outputTokens: 1, costUSD: 0) }
            #expect(await lc.entry(x.id)?.tier == .longTerm)
            let row = try #require(await d.router.digest.since(.distantPast).first { $0.action == "promovida" })
            #expect(row.before.map(\.id) == [x.id] && row.title == "Use Postgres")
            d.router.memory.events.flush()
            #expect(d.router.memory.events.read(since: Date().addingTimeInterval(-60)).contains { $0.type == .promoted && $0.ids == [x.id] })
            #expect(try await admin(d, p, "memory.undo", ["entry": row.id.uuidString]).ok)
            let e = try #require(await lc.entry(x.id))
            #expect(e.tier == .earned && e.gatedAt != nil && e.promotionUndone == true && e.recheckedAt == nil)
            #expect(await d.router.digest.since(.distantPast).first { $0.id == row.id }?.undone == true)
            #expect(try await all(store) == onDisk)   // the record file is untouched
        }
    }

    @Test func undoRestoresUnusedArchive() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Sem uso")
        try await withRepo([x]) { d, p, store, _ in
            let now = Date()
            await d.router.lifecyclePass(store, now: now)
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(22 * 86_400))
            #expect(try await all(store).first { $0.id == x.id }?.status == .archived)
            let row = try #require(await d.router.digest.since(.distantPast).first { $0.before.first?.id == x.id })
            d.router.memory.events.flush()
            #expect(d.router.memory.events.read(since: Date().addingTimeInterval(-60)).contains { $0.type == .archivedUnused && $0.ids == [x.id] })
            #expect(try await admin(d, p, "memory.undo", ["entry": row.id.uuidString]).ok)
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
            await d.router.lifecyclePass(store, now: Date().addingTimeInterval(86_400))   // the next pass leaves it be
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
        }
    }

    private func contest(_ d: Daemon, _ id: UUID, at: Date) async {
        await d.router.memory.lifecycle.update(id, now: at) { e in
            e.contestedNow = true; e.lastContestedAt = at
            e.flags = [LifecycleFlag(verdict: .wrong, session: "a", day: "2026-11-01", reason: "velha")]
        }
    }

    /// The user keeping a memory (resolve, restore, undo) settles its contest and restarts its unused clock.
    @Test func resolveKeepingContestedSettlesIt() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Contestada")
        try await withRepo([x]) { d, p, store, _ in
            let now = Date()
            await contest(d, x.id, at: now.addingTimeInterval(-15 * 86_400))
            await d.router.lifecyclePass(store, now: now)
            let ask = try #require(await d.router.digest.since(.distantPast).first { $0.action == "ask" })
            #expect(try await admin(d, p, "memory.resolve", ["entry": ask.id.uuidString, "keep": "newer"]).ok)
            let e = await d.router.memory.lifecycle.entry(x.id)
            #expect(e?.contestedNow == false && e?.flags.isEmpty == true && e?.recheckedAt != nil)
            await d.router.lifecyclePass(store, now: Date())
            #expect(await d.router.digest.since(.distantPast).filter { $0.action == "ask" }.count == 1)
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
        }
    }

    @Test func restoreSettlesContestAndClock() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Sem uso contestada")
        try await withRepo([x]) { d, p, store, _ in
            let now = Date().addingTimeInterval(-22 * 86_400)
            await d.router.lifecyclePass(store, now: now)
            await d.router.lifecyclePass(store, now: Date())
            #expect(try await all(store).first { $0.id == x.id }?.status == .archived)
            await contest(d, x.id, at: Date())
            let root = try #require(store.root).path
            #expect(try await admin(d, p, "memory.restore", ["id": x.id.uuidString, "repo": root]).ok)
            let e = await d.router.memory.lifecycle.entry(x.id)
            #expect(e?.contestedNow == false && e?.flags.isEmpty == true)
            await d.router.lifecyclePass(store, now: Date())
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
        }
    }

    /// Any archive row undone (here a retire), not only an unused one.
    @Test func undoOfRetireSettlesContest() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Retirada contestada")
        try await withRepo([x]) { d, p, store, _ in
            let now = Date()
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(-22 * 86_400))
            await contest(d, x.id, at: now)
            let job = CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: .null, dedupe: "", createdAt: now, attempts: 0)
            let rows = try await d.router.applyOps([.retire(id: x.id, reason: "checagem falhou")], job: job)
            try await d.router.digest.append(rows)
            let row = try #require(rows.first { $0.action == "aposentado" })
            #expect(try await admin(d, p, "memory.undo", ["entry": row.id.uuidString]).ok)
            let e = await d.router.memory.lifecycle.entry(x.id)
            #expect(e?.contestedNow == false && e?.flags.isEmpty == true)
            await d.router.lifecyclePass(store, now: Date())
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
        }
    }

    /// Kept by the user after two flags: score neutral again, so 30+ days unread it is not low-score archived.
    @Test func resolveKeepingResetsFlagPenalty() async throws {
        var x = MemoryRecord(kind: .decision, subject: "db", title: "Duas marcas")
        x.createdAt = Date().addingTimeInterval(-40 * 86_400)
        try await withRepo([x]) { d, p, store, _ in
            let mem = d.router.memory, then = Date().addingTimeInterval(-15 * 86_400)
            _ = try await mem.applyFlag(session: "a", id: x.id, record: x, verdict: .wrong, reason: "x", now: then)
            _ = try await mem.applyFlag(session: "b", id: x.id, record: x, verdict: .outdated, reason: "y", now: then)
            #expect(await mem.scores.factor(x.id) <= MemoryCleanup.lowScore)
            await d.router.lifecyclePass(store, now: Date())
            let ask = try #require(await d.router.digest.since(.distantPast).first { $0.action == "ask" })
            #expect(try await admin(d, p, "memory.resolve", ["entry": ask.id.uuidString, "keep": "newer"]).ok)
            #expect(await mem.scores.factor(x.id) == 1)
            await d.router.consolidate(store, now: Date())
            #expect(try await all(store).first { $0.id == x.id }?.status == .active)
        }
    }

    /// Undoing one row of a job undoes the group: every record it writes back is kept by the user.
    @Test func undoOfJobGroupSettlesEveryRecord() async throws {
        let x = MemoryRecord(kind: .decision, subject: "db", title: "Primeira"), y = MemoryRecord(kind: .decision, subject: "fila", title: "Segunda")
        try await withRepo([x, y]) { d, p, store, _ in
            let now = Date()
            await d.router.lifecyclePass(store, now: now.addingTimeInterval(-22 * 86_400))
            await contest(d, x.id, at: now); await contest(d, y.id, at: now)
            let job = CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: .null, dedupe: "", createdAt: now, attempts: 0)
            let group = UUID()   // only a correction job's rows carry `job`: grouped here by hand
            let rows = try await d.router.applyOps([.retire(id: x.id, reason: "a"), .retire(id: y.id, reason: "b")], job: job)
                .map { var r = $0; r.job = group; return r }
            try await d.router.digest.append(rows)
            let row = try #require(rows.first { $0.before.first?.id == x.id })
            #expect(try await admin(d, p, "memory.undo", ["entry": row.id.uuidString]).ok)
            for id in [x.id, y.id] {
                let e = await d.router.memory.lifecycle.entry(id)
                #expect(e?.contestedNow == false && e?.flags.isEmpty == true, "\(id)")
            }
            #expect(try await all(store).filter { $0.status == .active }.count == 2)
        }
    }
}
