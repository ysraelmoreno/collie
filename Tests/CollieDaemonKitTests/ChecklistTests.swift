import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }
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
private func klass(_ title: String, hits: Int, age: TimeInterval = 0, status: MemoryStatus = .active, example: String? = nil,
                   scope: MemoryScope = .project, lot: UUID? = nil) -> MemoryRecord {
    MemoryRecord(kind: .pitfall, scope: scope, lotId: lot, subject: title, title: title,
                 body: PitfallClasses.withExamples("Como evitar.", example.map { [$0] } ?? []), status: status, hits: hits,
                 createdAt: Date().addingTimeInterval(-age))
}
private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { try m.store.write(r) } } }

@Suite(.serialized) struct ChecklistTests {
    @Test func checklistRankedByHitsAndRecency() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [klass("Antiga", hits: 9, age: 365 * 86400, example: "faz tempo"), klass("Recente", hits: 4, age: 7 * 86400)])
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(c.text == "Armadilhas deste projeto:\n- Recente (4×)\n- Antiga (9×): faz tempo", "\(c.text)")
            #expect(c.ids.count == 2)
        }
    }

    /// Review Focus 3: superseded/archived/proposed classes are never listed; one injected then superseded is retracted.
    @Test func checklistOnlyActive() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            let live = klass("Viva", hits: 3)
            try await put(store, [live, klass("Substituída", hits: 9, status: .superseded), klass("Arquivada", hits: 9, status: .archived),
                                  klass("Proposta", hits: 9, status: .proposed), MemoryRecord(kind: .pitfall, subject: "inst", title: "Só uma instância")])
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(c.text == "Armadilhas deste projeto:\n- Viva (3×)", "\(c.text)")
            let a = try await term(d, p, "A", cwd: repo)
            #expect(output(try await call(p, a, "memory.hookContext")).contains("- Viva (3×)"))
            #expect(output(try await call(p, a, "memory.checklist")) == c.text)
            var gone = live; gone.status = .archived; gone.updatedAt = Date()
            try await put(store, [gone])
            #expect(output(try await call(p, a, "memory.hookRelevant", ["prompt": "ok"])).contains("Não vale mais: Viva."))
            #expect(output(try await call(p, a, "memory.checklist")) == "Nenhuma armadilha registrada neste projeto.")
        }
    }

    @Test func checklistAtSessionStart() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [MemoryRecord(kind: .decision, subject: "pin", title: "Fixada", pinned: true),
                                  MemoryRecord(kind: .decision, subject: "idx", title: "No índice"), klass("Corrida", hits: 2)])
            let a = try await term(d, p, "A", cwd: repo)
            let out = output(try await call(p, a, "memory.hookContext"))
            let pin = try #require(out.range(of: "- Fixada")), cl = try #require(out.range(of: "Armadilhas deste projeto:\n- Corrida (2×)"))
            let idx = try #require(out.range(of: MemoryService.indexTitle))
            #expect(pin.upperBound <= cl.lowerBound && cl.upperBound <= idx.lowerBound, "\(out)")
            #expect(!out[idx.upperBound...].contains("Corrida"), "\(out)")   // not listed twice
        }
    }

    /// Review Focus 4: 300 pitfalls still fit 1 200 B in the checklist and 4 096 B at session start.
    @Test func checklistFitsBudget() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, (0..<300).map { klass("Classe \($0) " + String(repeating: "é", count: 150), hits: $0 + 1, example: String(repeating: "x", count: 300)) }
                          + (0..<20).map { MemoryRecord(kind: .decision, subject: "p\($0)", title: "Fixada \($0) " + String(repeating: "y", count: 150), pinned: true) })
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(c.text.utf8.count <= 1_200 && !c.ids.isEmpty && c.ids.count <= 7)
            let s = await d.router.memory.contextText(cwd: repo.path, paddock: nil)
            #expect(s.text.utf8.count <= 4_096)
        }
    }

    @Test func lotSeesProjectChecklist() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            let lid = try #require(await d.router.ws.lots.first { $0.name == "Login" }?.id)
            try await put(await d.router.memory.repo(for: repo.path), [klass("Do projeto", hits: 2)])
            try await put(await d.router.memory.lotStore(lid), [klass("Do lote", hits: 5, scope: .lot, lot: lid)])
            let out = output(try await call(p, a, "memory.checklist"))
            #expect(out == "Armadilhas deste projeto:\n- Do projeto (2×)\n\nArmadilhas deste lote:\n- Do lote (5×)", "\(out)")
            #expect(output(try await call(p, a, "memory.hookContext")).contains(out))
        }
    }

    @Test func projectNeverSeesLotPitfalls() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            _ = try await term(d, p, "A", cwd: repo)
            let b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            let lid = try #require(await d.router.ws.lots.first { $0.name == "Login" }?.id)
            try await put(await d.router.memory.lotStore(lid), [klass("Do lote", hits: 5, scope: .lot, lot: lid)])
            #expect(output(try await call(p, b, "memory.checklist")) == "Nenhuma armadilha registrada neste projeto.")
            #expect(!output(try await call(p, b, "memory.hookContext")).contains("Do lote"))
            #expect(output(try await admin(d, p, "memory.checklist", ["repo": repo.path])) == "Nenhuma armadilha registrada neste projeto.")
        }
    }

    @Test func otherLotNeverSeen() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "Pagamento", "members": "B"]).ok)
            let other = try #require(await d.router.ws.lots.first { $0.name == "Pagamento" }?.id)
            try await put(await d.router.memory.lotStore(other), [klass("De outro lote", hits: 5, scope: .lot, lot: other)])
            #expect(!output(try await call(p, a, "memory.checklist")).contains("De outro lote"))
            #expect(!(try await call(p, a, "memory.checklist", ["lot": "Pagamento"])).ok)
            #expect(!output(try await call(p, a, "memory.hookContext")).contains("De outro lote"))
        }
    }

    @Test func cliChecklist() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(output(try await admin(d, p, "memory.checklist", ["repo": repo.path])) == "Nenhuma armadilha registrada neste projeto.")
            try await put(await d.router.memory.repo(for: repo.path), [klass("Corrida", hits: 2, example: "stat e open")])
            let r = try await admin(d, p, "memory.checklist", ["repo": repo.path])
            #expect(output(r) == (await d.router.memory.checklist(cwd: repo.path, lot: nil)).text)
            #expect(Commands.all.first { $0.name == "memory.checklist" }?.exposedToMCP == true)
        }
    }
}
