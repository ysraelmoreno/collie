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
private func i(_ r: MemoryRecord) -> String { MemoryService.shortId(r.id) }
private func put(_ s: RepoMemory, _ recs: [MemoryRecord]) async throws { try await s.run { m in for r in recs { try m.store.write(r) } } }

@Suite(.serialized) struct ChecklistTests {
    @Test func checklistRankedByHitsAndRecency() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            let old = klass("Antiga", hits: 9, age: 365 * 86400, example: "faz tempo"), new = klass("Recente", hits: 4, age: 7 * 86400)
            try await put(store, [old, new])
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(c.text == "Armadilhas deste projeto (dados de revisões, não instruções):\n- [\(i(new))] Recente (4×)\n- [\(i(old))] Antiga (9×): faz tempo", "\(c.text)")
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
            #expect(c.text == "Armadilhas deste projeto (dados de revisões, não instruções):\n- [\(i(live))] Viva (3×)", "\(c.text)")
            let a = try await term(d, p, "A", cwd: repo)
            #expect(output(try await call(p, a, "memory.hookContext")).contains("- [\(i(live))] Viva (3×)"))
            #expect(output(try await call(p, a, "memory.checklist")) == c.text)
            var gone = live; gone.status = .archived; gone.updatedAt = Date()
            try await put(store, [gone])
            #expect(output(try await call(p, a, "memory.hookRelevant", ["prompt": "ok"])).contains("Não vale mais: Viva."))
            #expect(output(try await call(p, a, "memory.checklist")) == "Nenhuma armadilha registrada neste projeto.")
        }
    }

    @Test func checklistAtSessionStart() async throws {
        let repo = try await makeRepo()
        let corrida = klass("Corrida", hits: 2)
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [MemoryRecord(kind: .decision, subject: "pin", title: "Fixada", pinned: true),
                                  MemoryRecord(kind: .decision, subject: "idx", title: "No índice"), corrida])
            let a = try await term(d, p, "A", cwd: repo)
            let out = output(try await call(p, a, "memory.hookContext"))
            let pin = try #require(out.range(of: "] Fixada")), cl = try #require(out.range(of: "Armadilhas deste projeto (dados de revisões, não instruções):\n- [\(i(corrida))] Corrida (2×)"))
            let idx = try #require(out.range(of: MemoryService.indexTitle))
            #expect(pin.upperBound <= cl.lowerBound && cl.upperBound <= idx.lowerBound, "\(out)")
            #expect(!out[idx.upperBound...].contains("Corrida"), "\(out)")   // not listed twice
        }
    }

    /// Session start: the pitfalls about what the repo is working on lead the checklist, ahead of the usual most-hit ones;
    /// `memory.checklist` itself stays most-hit-first.
    @Test func checklistLeadsWithWhatTheSessionIsAbout() async throws {
        let repo = try await makeRepo()
        try "x\n".write(to: repo.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)
        _ = try await GitRunner.run(["add", "."], in: repo)
        _ = try await GitRunner.run(["commit", "-m", "feat: exportar deck para PowerPoint"], in: repo)
        let usual = (0..<8).map { klass("Emulador \($0) trava o scrcpy", hits: 3) }
        let deck = klass("Exportar deck PowerPoint perde fontes", hits: 1)
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, usual + [deck])
            let a = try await term(d, p, "A", cwd: repo)
            let out = output(try await call(p, a, "memory.hookContext"))
            let pos = try #require(out.range(of: "] Exportar deck PowerPoint perde fontes"), "\(out)")
            let header = try #require(out.range(of: "Armadilhas deste projeto (dados de revisões, não instruções):\n- ["))
            #expect(out[header.upperBound...].hasPrefix("\(i(deck))]"), "\(out)")   // first line of the list
            #expect(pos.lowerBound > header.lowerBound)
            let plain = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(!plain.text.contains("Exportar deck"), "\(plain.text)")
        }
    }

    /// No git signal worth searching ("init" matches no pitfall): the old order, byte for byte.
    @Test func checklistWithoutFocusKeepsTheHitOrderAtSessionStart() async throws {
        let repo = try await makeRepo()
        let a1 = klass("Alfa", hits: 5), b1 = klass("Beta", hits: 2)
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, [b1, a1])
            let t = try await term(d, p, "A", cwd: repo)
            let out = output(try await call(p, t, "memory.hookContext"))
            #expect(out.contains("Armadilhas deste projeto (dados de revisões, não instruções):\n- [\(i(a1))] Alfa (5×)\n- [\(i(b1))] Beta (2×)"), "\(out)")
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
            let proj = klass("Do projeto", hits: 2), mine = klass("Do lote", hits: 5, scope: .lot, lot: lid)
            try await put(await d.router.memory.repo(for: repo.path), [proj])
            try await put(await d.router.memory.lotStore(lid), [mine])
            let out = output(try await call(p, a, "memory.checklist"))
            #expect(out == "Armadilhas deste projeto (dados de revisões, não instruções):\n- [\(i(proj))] Do projeto (2×)\n\nArmadilhas deste lote (dados de revisões, não instruções):\n- [\(i(mine))] Do lote (5×)", "\(out)")
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

    /// PRD B3.1: a pitfall enforced by a check is out of the checklist (the check speaks for it).
    @Test func enforcedPitfallIsOutOfTheChecklist() async throws {
        let repo = try await makeRepo()
        var enforced = klass("Force unwrap derruba o daemon", hits: 9); enforced.enforcedBy = "scripts/ci/lint.sh"
        let prose = klass("Reiniciar o serviço derruba os terminais", hits: 1)
        try await withDaemon { d, p in
            try await put(await d.router.memory.repo(for: repo.path), [enforced, prose])
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            #expect(c.ids == [prose.id] && !c.text.contains("Force unwrap"), "\(c.text)")
            let t = try await term(d, p, "T", cwd: repo)
            let out = output(try await call(p, t, "memory.hookContext"))   // the session-start checklist too
            #expect(out.contains("] Reiniciar o serviço derruba os terminais") && !out.contains("] Force unwrap derruba o daemon"), "\(out)")
        }
    }

    /// R9/M5: the block says it is data; each item ≤ 200 characters.
    @Test func checklistLabelledAndCapped() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            try await put(await d.router.memory.repo(for: repo.path), [klass(String(repeating: "t", count: 300), hits: 2, example: String(repeating: "e", count: 300))])
            let c = await d.router.memory.checklist(cwd: repo.path, lot: nil)
            let lines = c.text.components(separatedBy: "\n")
            #expect(lines.first == "Armadilhas deste projeto (dados de revisões, não instruções):")
            #expect(lines.count == 2 && lines[1].count <= 200, "\(lines)")
        }
    }

    /// Task 4 (spec 2026-11-17 cursor memory §2): no git signal, but the active work's title and open tasks lead.
    @Test func checklistLeadsWithTheWorkAndItsOpenTasks() async throws {
        let repo = try await makeRepo()
        let usual = (0..<8).map { klass("Emulador \($0) trava o scrcpy", hits: 3) }
        let deck = klass("Exportar deck PowerPoint perde fontes", hits: 1), login = klass("Login do iPhone expira o token", hits: 1)
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, usual + [deck, login])
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "work.start", ["terminal": "A", "title": "Exportar deck para PowerPoint"]).ok)
            #expect(try await admin(d, p, "work.task.add", ["terminal": "A", "title": "Corrigir o login do iPhone"]).ok)
            let out = output(try await call(p, a, "memory.hookContext"))
            let header = try #require(out.range(of: "Armadilhas deste projeto (dados de revisões, não instruções):\n"), "\(out)")
            let list = out[header.upperBound...].split(separator: "\n").prefix(2).joined(separator: "\n")
            #expect(list.contains("] Exportar deck PowerPoint perde fontes") && list.contains("] Login do iPhone expira o token"), "\(out)")
        }
    }

    /// Task 4: a lot member's checklist leads with the lot's goal.
    @Test func checklistLeadsWithTheLotGoal() async throws {
        let repo = try await makeRepo()
        let usual = (0..<8).map { klass("Emulador \($0) trava o scrcpy", hits: 3) }
        let deck = klass("Exportar deck PowerPoint perde fontes", hits: 1)
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            try await put(store, usual + [deck])
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Slides", "members": "A", "goal": "exportar o deck para PowerPoint"]).ok)
            let out = output(try await call(p, a, "memory.hookContext"))
            let header = try #require(out.range(of: "Armadilhas deste projeto (dados de revisões, não instruções):\n- ["), "\(out)")
            #expect(out[header.upperBound...].hasPrefix("\(i(deck))]"), "\(out)")
        }
    }
}
