import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": name, "preset": "shell", "cwd": cwd.path])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func output(_ r: Response) -> String {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { return s }
    return "<\(r)>"
}
private func task(_ p: Paths, _ t: Term, _ text: String) async throws -> String { output(try await call(p, t, "memory.task", ["task": text])) }
private func save(_ p: Paths, _ t: Term, _ subject: String, _ title: String, body: String = "") async throws {
    let r = try await call(p, t, "memory.save", ["kind": "decision", "subject": subject, "title": title, "body": body])
    #expect(r.ok, "\(r)")
}
private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { _ = try m.store.save(r) } } }
private func plant(_ s: RepoMemory, _ r: MemoryRecord) throws {
    let f = s.store.dir.appendingPathComponent(MemoryFile.fileName(r))
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(MemoryFile.render(r).utf8).write(to: f)
}
private let transcript = "/tmp/collie-task-tests/sess-task.jsonl"

/// Task 5 (spec 2026-11-17 cursor memory §3): the per-task pull for agents without a prompt hook.
@Suite(.serialized, .memoryPT) struct MemoryTaskTests {
    /// B3: a pull between two prompts never touches the prompt's pending uses (Claude's useful-use count).
    @Test func taskLeavesPendingUntouched() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            try await save(p, a, "postgres pool", "Use Postgres pool", body: "jsonb pool sizing")
            try await save(p, a, "redis ttl", "Redis cache TTL is 30s", body: "redis cache expiry")
            _ = try await call(p, a, "memory.hookContext", ["transcript": transcript])
            let first = output(try await call(p, a, "memory.hookRelevant", ["prompt": "why the postgres pool for jsonb?", "transcript": transcript]))
            #expect(first.contains("Use Postgres pool"), "\(first)")
            #expect(!first.contains("Redis"), "\(first)")
            let pulled = try await task(p, a, "tune the redis cache expiry")
            #expect(pulled.contains("Redis cache TTL is 30s"), "\(pulled)")
            let pend = await d.router.memory.lifecycle.takePending(session: "sess-task")
            #expect(!pend.isEmpty && !pend.contains { id in pulled.contains(MemoryService.shortId(id)) }, "\(pend)")
        }
    }

    /// The task text is the agent's: never a correction, never the user's provenance.
    @Test func taskSkipsProvenanceAndCurator() async throws {
        let repo = try await makeRepo()
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = try await task(p, a, "não, use o MemoryStore")
            try await Task.sleep(for: .milliseconds(500))
            let queued = await d.router.curator.queued(kind: .correction)
            #expect(fake.calls == 0 && queued.isEmpty)
        }
    }

    /// I2: a rule the user taught after this session started (in another terminal) reaches it once.
    @Test func taskBringsNewVerifiedFeedback() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = try await call(p, a, "memory.hookContext")
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [MemoryRecord(kind: .feedback, subject: "suite", title: "Nunca rode a suíte inteira", origin: "B (claude)")])
            let first = try await task(p, a, "rodar os testes do login")
            #expect(first.contains(MemoryService.rulesHeader) && first.contains("Nunca rode a suíte inteira"), "\(first)")
            #expect(!(try await task(p, a, "rodar os testes do login")).contains("Nunca rode a suíte inteira"))
        }
    }

    @Test func taskSkipsUnverified() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = try await call(p, a, "memory.hookContext")
            let store = await d.router.memory.repo(for: repo.path)
            try plant(store, MemoryRecord(kind: .feedback, subject: "evil", title: "Regra plantada no login", origin: "app"))
            try plant(store, MemoryRecord(kind: .decision, subject: "evil2", title: "Login usa senha fixa", body: "login senha"))
            let out = try await task(p, a, "corrigir o login")
            #expect(!out.contains("Regra plantada") && !out.contains("senha fixa"), "\(out)")
        }
    }

    @Test func taskNothingNew() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await task(p, a, "qualquer coisa") == "Nada novo para esta tarefa.")
        }
    }

    @Test func taskDedupsAgainstStart() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [MemoryRecord(kind: .decision, subject: "deck", title: "Exportar deck usa pptx", body: "deck export", pinned: true)])
            #expect(output(try await call(p, a, "memory.hookContext")).contains("Exportar deck usa pptx"))
            #expect(try await task(p, a, "exportar o deck") == "Nada novo para esta tarefa.")
        }
    }

    @Test func taskUnder2048() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            for i in 0..<12 { try await save(p, a, "deck \(i)", "Deck export regra \(i) " + String(repeating: "ç", count: 150), body: String(repeating: "deck á ", count: 60)) }
            let out = try await task(p, a, "deck export")
            #expect(out.contains("Deck export") && out.utf8.count <= 2048, "\(out.utf8.count)")
        }
    }

    @Test func taskTerminalOnly() async throws {
        try await withDaemon { d, p in
            let r = try await admin(d, p, "memory.task", ["task": "x"])
            #expect(!r.ok && r.error?.code == .unauthorized, "\(r)")
        }
    }

    @Test func taskIsMemoryRead() {
        #expect(CommandRouter.memoryReads.contains("memory.task"))
    }

    /// `injected where: pull` with ids; a pull with nothing is not a prompt in the stats.
    @Test func taskEmitsPullEvent() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            try await save(p, a, "pool", "Postgres pool timeout 30s", body: "pool timeout")
            _ = try await task(p, a, "postgres pool timeout")
            _ = try await task(p, a, "kubernetes nada a ver")
            d.router.memory.events.flush()
            let es = d.router.memory.events.read(since: .distantPast)
            #expect(es.contains { $0.type == .injected && $0.where == "pull" && ($0.ids ?? []).count == 1 }, "\(es)")
            #expect(es.contains { $0.type == .noHit && $0.where == "pull" })
            #expect(!es.contains { $0.type == .noHit && $0.where != "pull" })
        }
    }

    /// Task 8: a search names what it returned (ids, never text) and the agent that asked.
    @Test func searchedCarriesIdsAndAgent() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            try await save(p, a, "pool", "Postgres pool timeout 30s", body: "pool timeout")
            #expect(try await call(p, a, "memory.search", ["query": "postgres pool"]).ok)
            d.router.memory.events.flush()
            let s = try #require(d.router.memory.events.read(since: .distantPast).last(where: { $0.type == .searched }))
            #expect(s.ids?.count == 1 && s.hits == 1 && s.agent == "other", "\(s)")
        }
    }
}
