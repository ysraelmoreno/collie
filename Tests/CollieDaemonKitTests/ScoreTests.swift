import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var name: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 60)
}
private func output(_ r: Response) -> String {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { return s }
    return ""
}
private func rec(_ title: String, body: String = "", pinned: Bool = false, created: Date = Date()) -> MemoryRecord {
    MemoryRecord(kind: .decision, subject: title, title: title, body: body, pinned: pinned, createdAt: created)
}
private func git(_ args: [String], _ dir: URL) async throws -> String { try await GitRunner.run(args, in: dir).stdout }
private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("collie-scores-\(UUID().uuidString)/learning/scores.json")
}

@Suite(.serialized) struct ScoreTests {
    /// A work with the memory injected, then closed by merge: +0.1, through the work store's change funnel.
    @Test func mergeRaisesInjected() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let r = rec("Webhook retries", body: "three retries with backoff")
            try await d.router.memory.repo(for: repo.path).run { try $0.store.write(r) }
            #expect(try await admin(d, p, "work.start", ["terminal": .string("T"), "title": .string("Feature")]).ok)
            #expect(output(try await call(p, t, "memory.hookRelevant", ["prompt": "webhook retries backoff"])).contains("Webhook retries"))
            let w = try #require(try await d.router.work.active(terminal: UUID(uuidString: t.id)!))
            #expect(await d.router.memory.scores.pending(w.id) == [r.id])
            try await d.router.work.update(w.id) { $0.closedAt = Date(); $0.closedBy = "merge" }
            #expect(await waitFor(10) { await d.router.memory.scores.factor(r.id) == 1.1 })
            #expect(await d.router.memory.scores.pending(w.id).isEmpty)   // pruned after its outcome
        }
    }

    @Test func closeWithoutMergeNeutral() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let r = rec("Webhook retries", body: "three retries with backoff")
            try await d.router.memory.repo(for: repo.path).run { try $0.store.write(r) }
            #expect(try await admin(d, p, "work.start", ["terminal": .string("T"), "title": .string("Feature")]).ok)
            _ = try await call(p, t, "memory.hookRelevant", ["prompt": "webhook retries backoff"])
            let w = try #require(try await d.router.work.active(terminal: UUID(uuidString: t.id)!))
            #expect(await d.router.memory.scores.pending(w.id) == [r.id])
            #expect(try await admin(d, p, "work.done", ["terminal": .string("T")]).ok)
            #expect(await waitFor(10) { await d.router.memory.scores.pending(w.id).isEmpty })
            #expect(await d.router.memory.scores.factor(r.id) == 1.0)
        }
    }

    /// A correction in the same work contradicting it (2R's `MemoryLearning` calls this): −0.5.
    @Test func correctionLowersStrongly() async throws {
        let s = ScoreStore(file: tempFile()), id = UUID()
        await s.penalize(id, ScoreStore.correction, reason: "corrigida")
        #expect(await s.factor(id) == 0.5)
        // it persists, 0600
        let again = ScoreStore(file: s.file)
        #expect(await again.factor(id) == 0.5)
        let mode = (try FileManager.default.attributesOfItem(atPath: s.file.path))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func editLowers() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let r = rec("Webhook retries", body: "three retries")
            try await d.router.memory.repo(for: repo.path).run { try $0.store.write(r) }
            #expect(try await admin(d, p, "memory.review", ["id": .string(r.id.uuidString), "action": .string("approve"), "repo": .string(repo.path)]).ok)
            #expect(await d.router.memory.scores.factor(r.id) == 1.0)   // approving alone is no edit
            #expect(try await admin(d, p, "memory.review", ["id": .string(r.id.uuidString), "action": .string("approve"),
                                                            "title": .string("Webhook: 3 retries"), "repo": .string(repo.path)]).ok)
            let f = await d.router.memory.scores.factor(r.id)
            #expect(abs(f - 0.8) < 1e-12)
            let got = try await admin(d, p, "memory.get", ["id": .string(r.id.uuidString), "repo": .string(repo.path)])
            guard case .object(let o)? = got.result, case .number(let score)? = o["score"] else { Issue.record("\(got)"); return }
            #expect(abs(score - 0.8) < 1e-12)
        }
    }

    @Test func clamped() async throws {
        let s = ScoreStore(file: tempFile()), id = UUID()
        for _ in 0..<5 { await s.penalize(id, ScoreStore.correction, reason: "x") }
        #expect(await s.factor(id) == 0.2)
        let w = UUID()
        for _ in 0..<30 { await s.noteInjected([id], work: w); await s.outcome(work: w, merged: true) }
        #expect(await s.factor(id) == 2.0)
        await s.penalize(id, 0.4, reason: "curador")   // a curator note never passes the ceiling either
        #expect(await s.factor(id) == 2.0)
    }

    @Test func scoreRanksRelevance() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let at = Date()
            let low = rec("Webhook retries alpha", body: "backoff", created: at), high = rec("Webhook retries bravo", body: "backoff", created: at)
            try await d.router.memory.repo(for: repo.path).run { m in try m.store.write(low); try m.store.write(high) }
            await d.router.memory.scores.penalize(high.id, 0.6, reason: "teste")
            await d.router.memory.scores.penalize(low.id, -0.4, reason: "teste")
            let text = output(try await call(p, t, "memory.hookRelevant", ["prompt": "webhook retries backoff"]))
            let a = try #require(text.range(of: "bravo")), b = try #require(text.range(of: "alpha"))
            #expect(a.lowerBound < b.lowerBound, "\(text)")
            let found = try await call(p, t, "memory.search", ["query": "webhook retries"])
            guard case .array(let rows)? = found.result, case .object(let first)? = rows.first, case .string(let title)? = first["title"] else {
                Issue.record("\(found)"); return
            }
            #expect(title == high.title && rows.count == 2)
        }
    }

    @Test func lowScoreColdArchived() async throws {
        let now = Date(), old = now.addingTimeInterval(-31 * 86400)
        let cold = rec("Cold", created: old), pinned = rec("Pinned", pinned: true, created: old)
        let recent = rec("Recent", created: old), okScore = rec("Fine", created: old)
        let stats: [UUID: MemoryStats] = [recent.id: MemoryStats(reads: 1, lastReadAt: now.addingTimeInterval(-5 * 86400), missingSince: nil)]
        let scores = [cold.id: 0.4, pinned.id: 0.4, recent.id: 0.4, okScore.id: 0.6]
        let plan = MemoryCleanup.plan(records: [cold, pinned, recent, okScore], stats: stats, scores: scores, now: now)
        #expect(plan == [CleanupItem(action: .archiveLowScore, id: cold.id, into: nil, reason: "nota baixa (0,4) e sem uso há 31 dias")])

        let repo = try await makeRepo()
        try await withDaemon { d, p in
            try await d.router.memory.repo(for: repo.path).run { m in try m.store.write(cold); try m.store.write(pinned) }
            await d.router.memory.scores.penalize(cold.id, -0.6, reason: "teste")
            await d.router.memory.scores.penalize(pinned.id, -0.6, reason: "teste")
            #expect(try await admin(d, p, "memory.cleanup", ["apply": .bool(true), "repo": .string(repo.path)]).ok)
            let st = try await d.router.memory.repo(for: repo.path).run { m in m.store.all().records.map { ($0.id, $0.status) } }
            #expect(Dictionary(uniqueKeysWithValues: st) == [cold.id: .archived, pinned.id: .active])
            #expect(try await admin(d, p, "memory.restore", ["id": .string(cold.id.uuidString), "repo": .string(repo.path)]).ok)
            #expect(await d.router.memory.scores.factor(cold.id) == 1.0)
        }
    }

    /// Scores live in Collie's root: score changes never touch the repo; only content/status changes do.
    @Test func scoresNotInRepo() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let r = rec("Webhook retries", body: "three retries with backoff")
            try await d.router.memory.repo(for: repo.path).run { try $0.store.write(r) }
            _ = try await git(["add", "."], repo); _ = try await git(["commit", "-qm", "memory"], repo)
            #expect(try await admin(d, p, "work.start", ["terminal": .string("T"), "title": .string("Feature")]).ok)
            _ = try await call(p, t, "memory.hookRelevant", ["prompt": "webhook retries backoff"])
            let w = try #require(try await d.router.work.active(terminal: UUID(uuidString: t.id)!))
            try await d.router.work.update(w.id) { $0.closedAt = Date(); $0.closedBy = "merge" }
            #expect(await waitFor(10) { await d.router.memory.scores.factor(r.id) == 1.1 })
            await d.router.memory.scores.penalize(r.id, ScoreStore.correction, reason: "teste")
            _ = try await admin(d, p, "memory.get", ["id": .string(r.id.uuidString), "repo": .string(repo.path)])
            #expect(try await git(["status", "--porcelain"], repo).isEmpty)
            #expect(FileManager.default.fileExists(atPath: p.root.appendingPathComponent("learning/scores.json").path))
            #expect(try await admin(d, p, "memory.review", ["id": .string(r.id.uuidString), "action": .string("approve"),
                                                            "body": .string("four retries"), "repo": .string(repo.path)]).ok)
            let lines = try await git(["status", "--porcelain"], repo).split(separator: "\n")
            #expect(lines.count == 1 && lines[0].contains(".collie/memory/"), "\(lines)")
        }
    }
}
