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
    let token = try await tokenOf(d, id)
    _ = await d.router.asks.provenance.take(UUID(uuidString: id)!, prompt: "")
    return Term(id: id, token: token)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func output(_ r: Response) -> String {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { return s }
    return "<\(r)>"
}
private func typed(_ d: Daemon, _ p: Paths, _ t: Term, _ prompt: String) async throws {
    await d.router.asks.provenance.typed(t.uuid, Data((prompt + "\r").utf8))
    _ = try await call(p, t, "memory.hookRelevant", ["prompt": prompt])
}
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private let stated = "sempre que mexer no sandbox, rode SandboxProfileTests e confira o perfil"
private func createProcedure() -> CuratorOutput {
    CuratorOutput(json: .object(["ops": .array([.object([
        "op": .string("create"), "kind": .string("procedure"), "scope": .string("project"), "title": .string("Mexer no sandbox"),
        "body": .string("1. Rode SandboxProfileTests\n- Confira o perfil\n\n"), "howToApply": .string("mexer no sandbox"),
    ])])]), inputTokens: 10, outputTokens: 5, costUSD: 0.0001)
}

@Suite struct StatedProcedureTests {
    @Test func detectsStatedProcedure() {
        for p in [stated, "toda vez que criar um plano, commite com os trailers", "whenever you add a command, update the MCP schema"] {
            #expect(CorrectionDetector.isProcedure(p), "\(p)")
        }
    }

    @Test func notAProcedure() {
        for p in ["sempre que possível", "sempre", "sempre que possível, rode o lint", "rode os testes sempre", "sempre que der, use X",
                  String(repeating: "sempre que mexer, rode ", count: 40)] {
            #expect(!CorrectionDetector.isProcedure(p), "\(p.prefix(40))")
        }
    }

    @Test func procedureBodyBounded() {
        let steps = (1...20).map { "\($0). " + String(repeating: "x", count: 300) }.joined(separator: "\n")
        let b = try! #require(MemoryLearning.procedureBody(when: "  mexer\nno sandbox ", steps: steps))
        let lines = b.components(separatedBy: "\n")
        #expect(lines[0] == "Quando: mexer no sandbox" && lines[1].isEmpty)
        #expect(lines.count == 2 + 12 && lines[2].hasPrefix("1. x") && lines[13].hasPrefix("12. x"))
        #expect(lines.dropFirst(2).allSatisfy { $0.unicodeScalars.count <= 200 + 4 })
        #expect(MemoryLearning.procedureBody(when: "x", steps: " \n- \n") == nil)
    }

    @Test func procedureOldFilesDecode() throws {
        // a file 2R wrote: unchanged by the new kind
        let text = """
            ---
            id: 6f1c2d3e-0000-4000-8000-000000000001
            kind: feedback
            scope: project
            subject: banco
            title: Use SQLite
            status: active
            reviewed: false
            pinned: false
            origin: curador (A)
            created: 2026-10-20T10:00:00.000Z
            updated: 2026-10-20T10:00:00.000Z
            ---

            O índice usa SQLite.

            """
        let r = try MemoryFile.parse(text)
        #expect(r.kind == .feedback && MemoryFile.render(r) == text)
        let p = try MemoryFile.parse(text.replacingOccurrences(of: "kind: feedback", with: "kind: procedure"))
        #expect(p.kind == .procedure && MemoryFile.fileName(p).hasPrefix("procedure/banco-"))
    }
}

@Suite(.serialized) struct ProcedureTests {
    @Test func statedProcedureCreated() async throws {
        let repo = try await makeRepo()
        let f = FakeCurator(); f.output = createProcedure()
        try await withDaemon(configure: { $0.curatorRunner = f }) { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let store = await d.router.memory.repo(for: repo.path)
            try await typed(d, p, a, stated)
            #expect(await waitFor(10) { (try? await all(store))?.contains { $0.kind == .procedure } == true })
            #expect(f.inputs.first?.contains(stated) == true)
            let proc = try #require(try await all(store).first { $0.kind == .procedure })
            #expect(proc.status == .active && proc.origin == "curador (A)" && proc.scope == .project)
            #expect(proc.subject == "mexer-no-sandbox" && proc.title == "Mexer no sandbox")
            #expect(proc.body == "Quando: mexer no sandbox\n\n1. Rode SandboxProfileTests\n2. Confira o perfil", "\(proc.body)")
            // the waiting quote is gone (replaced by the procedure)
            #expect(await waitFor(10) { (try? await all(store))?.contains { $0.status == .proposed } == false })
        }
    }

    /// R12: the same statement not typed by the user (an agent driving the hook) is a proposal only.
    @Test func statedProcedureWithoutUserIsProposed() async throws {
        let repo = try await makeRepo()
        let f = FakeCurator(); f.output = createProcedure()
        try await withDaemon(configure: { $0.curatorRunner = f }) { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let store = await d.router.memory.repo(for: repo.path)
            _ = try await call(p, a, "memory.hookRelevant", ["prompt": stated])
            #expect(await waitFor(10) { (try? await all(store))?.contains { $0.kind == .procedure } == true })
            let proc = try #require(try await all(store).first { $0.kind == .procedure })
            #expect(proc.status == .proposed)
        }
    }

    @Test func procedureInIndexAndGet() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let saved = try await admin(d, p, "memory.save", ["repo": repo.path, "kind": "procedure", "subject": "mexer-no-sandbox",
                                                               "title": "Mexer no sandbox", "body": "Quando: mexer no sandbox\n\n1. Rode SandboxProfileTests"])
            guard case .object(let o)? = saved.result, case .string(let id)? = o["id"] else { Issue.record("\(saved)"); return }
            let a = try await term(d, p, "A", cwd: repo)
            let ctx = output(try await call(p, a, "memory.hookContext"))
            #expect(ctx.contains("\n- [procedimento] Mexer no sandbox"), "\(ctx)")
            let got = try await call(p, a, "memory.get", ["id": id])
            guard case .object(let g)? = got.result, case .string(let body)? = g["body"] else { Issue.record("\(got)"); return }
            #expect(body.contains("1. Rode SandboxProfileTests"))
            let list = try await call(p, a, "memory.list", ["kind": "procedure"])
            guard case .object(let l)? = list.result, case .array(let rows)? = l["records"] else { Issue.record("\(list)"); return }
            #expect(rows.count == 1)
            let rel = output(try await call(p, a, "memory.hookRelevant", ["prompt": "vou mexer no sandbox agora"]))
            #expect(rel.contains("- [procedimento] Mexer no sandbox"), "\(rel)")
            // an agent may save one, but it waits for the user (R12: not active without the user's provenance)
            let mine = try await call(p, a, "memory.save", ["kind": "procedure", "subject": "lint", "title": "Rodar o lint", "body": "1. lint"])
            guard case .object(let m)? = mine.result, case .string(let st)? = m["status"] else { Issue.record("\(mine)"); return }
            #expect(st == "proposed")
        }
    }
}
