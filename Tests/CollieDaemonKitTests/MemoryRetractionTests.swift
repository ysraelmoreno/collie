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
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]), to: p.socket, timeoutSeconds: 60)
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
private func relevant(_ p: Paths, _ t: Term, _ prompt: String) async throws -> String {
    output(try await call(p, t, "memory.hookRelevant", ["prompt": prompt]))
}
private func rec(_ title: String, kind: MemoryKind = .decision, subject: String? = nil, body: String = "", pinned: Bool = false) -> MemoryRecord {
    MemoryRecord(kind: kind, subject: subject ?? title, title: title, body: body, pinned: pinned)
}

@Suite(.serialized) struct MemoryRetractionTests {
    /// Review Focus 5: X reached A (session start) and B (prompt relevance); X superseded by Y on disk → each gets the line once.
    @Test func retractionOnceToReceivers() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            let store = await d.router.memory.repo(for: repo.path)
            let x = rec("Use Postgres pool", subject: "db", body: "postgres pool sizing", pinned: true)
            _ = try await store.run { try $0.store.save(x) }
            #expect(output(try await call(p, a, "memory.hookContext")).contains("Use Postgres pool"))
            #expect(try await relevant(p, b, "postgres pool sizing").contains("Use Postgres pool"))
            let y = rec("Use SQLite", subject: "db", body: "embedded")
            _ = try await store.run { try $0.store.save(y) }   // plain save: no curator
            let line = "Memória retirada (Collie):\nNão vale mais: Use Postgres pool. Use: Use SQLite."
            let first = try await relevant(p, a, "zebra quokka")
            #expect(first.hasPrefix(line), "\(first)")
            #expect(!(try await relevant(p, a, "zebra quokka")).contains("Não vale mais"))
            let fromB = try await relevant(p, b, "ok")   // no significant term: retractions still run
            #expect(fromB.hasPrefix(line), "\(fromB)")
            #expect(!(try await relevant(p, b, "ok")).contains("Não vale mais"))
        }
    }

    /// A session started after the supersede never sees the line.
    @Test func newSessionNoRetraction() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        _ = try await store.run { try $0.store.save(rec("Old cache rule", subject: "cache", body: "redis cache ttl", pinned: true)) }
        let a = UUID(), late = UUID()
        _ = await mem.context(for: a, cwd: repo.path)
        _ = try await store.run { try $0.store.save(rec("New cache rule", subject: "cache", body: "redis cache ttl", pinned: true)) }
        _ = await mem.context(for: a, cwd: repo.path)   // A restarted its session: a new set
        _ = await mem.context(for: late, cwd: repo.path)
        #expect(await mem.retractions(for: a, limit: 2048).isEmpty)
        #expect(await mem.retractions(for: late, limit: 2048).isEmpty)
        #expect(!(await mem.relevant(for: late, cwd: repo.path, prompt: "redis cache ttl")).contains("Não vale mais"))
    }

    /// The index is the path: a hand edit to `archived` retracts like a supersede (no "Use:").
    @Test func handEditRetracts() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        let x = rec("Deploy on fridays", pinned: true)
        _ = try await store.run { try $0.store.save(x) }
        let t = UUID()
        #expect(await mem.context(for: t, cwd: repo.path).contains("Deploy on fridays"))
        let file = URL(fileURLWithPath: store.file(x))
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "status: active", with: "status: archived").write(to: file, atomically: true, encoding: .utf8)
        #expect(await mem.retractions(for: t, limit: 2048) == "Memória retirada (Collie):\nNão vale mais: Deploy on fridays.")
        #expect(await mem.retractions(for: t, limit: 2048).isEmpty)
    }

    /// 30 retracted ids with 200-character titles, plus board posts: the retraction block fills the 2048 budget first.
    @Test func retractionFirstInBudget() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "L", "members": "A,B"]).ok)
            let lot = await d.router.ws.lots.first { $0.name == "L" }!.id
            let store = await d.router.memory.repo(for: repo.path)
            let long = String(repeating: "á", count: 190)
            let olds = (0..<30).map { rec("\($0) \(long)", subject: "s\($0)", pinned: true) }
            _ = try await store.run { m in for r in olds { _ = try m.store.save(r) } }
            _ = await d.router.memory.context(for: a.uuid, cwd: repo.path, lot: lot, limit: 1_000_000)
            _ = try await store.run { m in for i in 0..<30 { _ = try m.store.save(rec("novo \(i) \(long)", subject: "s\(i)")) } }
            for i in 0..<3 {
                #expect(try await call(p, b, "lot.post", ["kind": "question", "text": "pergunta \(i)", "to": "A"]).ok)
            }
            let out = try await relevant(p, a, "zebra quokka")
            #expect(out.utf8.count <= 2048)
            #expect(out.hasPrefix("Memória retirada (Collie):\nNão vale mais: "))
            #expect(out.range(of: #"\n… e mais \d+$"#, options: .regularExpression) != nil, "\(out.utf8.count) \(out.suffix(300))")
        }
    }

    /// A pushed rule comes before the other hits and is not repeated.
    @Test func pushedRuleFirst() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        let rule = rec("Sempre rode swiftlint", kind: .feedback, body: "swiftlint config antes do commit")
        let dec = rec("Swiftlint config strict", body: "swiftlint config strict mode")
        _ = try await store.run { m in _ = try m.store.save(rule); _ = try m.store.save(dec) }
        let t = UUID()
        await mem.pushRule(rule.id, to: t)
        let out = await mem.relevant(for: t, cwd: repo.path, prompt: "swiftlint config")
        let r = try #require(out.range(of: "- [regra] Sempre rode swiftlint")), dr = try #require(out.range(of: "[decisão] Swiftlint config strict"))
        #expect(r.lowerBound < dr.lowerBound, "\(out)")
        #expect(out.components(separatedBy: "Sempre rode swiftlint").count == 2)
        #expect(!(await mem.relevant(for: t, cwd: repo.path, prompt: "swiftlint config")).contains("Sempre rode swiftlint"))
    }

    /// Feedback is the user's: an agent can't save one, the admin can.
    @Test func agentCannotSaveFeedback() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let args = ["kind": "feedback", "subject": "idioma", "title": "Responda em português"]
            let r = try await call(p, a, "memory.save", args)
            #expect(r.error?.code == .invalidArgs && r.error?.message == "kind must be decision|map|pitfall", "\(r)")
            #expect(try await admin(d, p, "memory.save", args.merging(["repo": repo.path]) { a, _ in a }).ok)
        }
    }

    /// Moved from lot A to lot B: a lot A memory superseded afterwards never reaches the session (its set started over).
    @Test func lotMoveNoForeignRetraction() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let la = UUID(), lb = UUID(), t = UUID()
        let store = await mem.lotStore(la)
        _ = try await store.run { try $0.store.save(MemoryRecord(kind: .decision, scope: .lot, lotId: la, subject: "s", title: "Segredo do lote A", pinned: true)) }
        #expect(await mem.context(for: t, cwd: repo.path, lot: la).contains("Segredo do lote A"))
        _ = try await store.run { try $0.store.save(MemoryRecord(kind: .decision, scope: .lot, lotId: la, subject: "s", title: "Novo do lote A")) }
        #expect(await mem.retractions(for: t, lot: lb, limit: 2048).isEmpty)
        #expect(await mem.retractions(for: t, lot: la, limit: 2048).isEmpty)   // the set started over at the move
    }

    /// "Use:" names only a successor the receiving session may see (another paddock's is omitted).
    @Test func successorMustBeVisible() async throws {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        var x = MemoryRecord(kind: .decision, scope: .paddock, paddock: "p1", subject: "s", title: "Regra do p1", pinned: true)
        let y = MemoryRecord(kind: .decision, scope: .paddock, paddock: "p2", subject: "s", title: "Segredo do p2")
        let x0 = x
        _ = try await store.run { try $0.store.save(x0) }
        let t = UUID()
        #expect(await mem.context(for: t, cwd: repo.path, paddock: "p1").contains("Regra do p1"))
        x.status = .superseded; x.supersededBy = y.id
        let gone = x
        try await store.run { try $0.store.write(y); try $0.store.write(gone) }
        #expect(await mem.retractions(for: t, paddock: "p1", limit: 2048) == "Memória retirada (Collie):\nNão vale mais: Regra do p1.")
    }

    /// A feedback is the user's rule: no agent path archives, edits, supersedes or moves it.
    @Test func agentCannotChangeFeedback() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "L", "members": "A"]).ok)
            let lot = await d.router.ws.lots.first { $0.name == "L" }!.id
            let store = await d.router.memory.lotStore(lot)
            let f = MemoryRecord(kind: .feedback, scope: .lot, lotId: lot, subject: "idioma", title: "Responda em português")
            _ = try await store.run { try $0.store.save(f) }
            #expect(try await call(p, a, "memory.promote", ["id": f.id.uuidString]).error?.code == .unauthorized)
            for cmd in ["memory.review", "memory.pin", "memory.restore"] {
                #expect(try await call(p, a, cmd, ["id": f.id.uuidString, "action": "archive"]).error?.code == .unauthorized, "\(cmd)")
            }
            #expect(try await call(p, a, "memory.save", ["kind": "decision", "subject": "idioma", "title": "Responda em inglês"]).ok)
            #expect(try await store.run { $0.store.all().records.first { $0.id == f.id } } == f)
        }
    }

    @Test func feedbackSectionAndLabel() {
        let (text, _) = MemoryService.renderContext([rec("D", pinned: true), rec("F", kind: .feedback, pinned: true)], limit: 4096)
        let f = try! #require(text.range(of: "Regras do usuário:\n- F")), dd = try! #require(text.range(of: "Decisões:\n- D"))
        #expect(f.lowerBound < dd.lowerBound)
    }
}
