import Testing
import Foundation
import CollieProtocol
@testable import CollieApp

/// Preferências › Memória (spec 2026-11-17 cursor memory §7, plan task 9): the model alone, no UI.
struct CursorMemoryModelTests {
    @Test func choicesAndLabels() {
        #expect(CursorMemoryChoice.allCases == [.full, .start, .off])
        #expect(CursorMemoryChoice.full.label == "Início + consulta por tarefa")
        #expect(CursorMemoryChoice.start.label == "Só início")
        #expect(CursorMemoryChoice.off.label == "Desligada")
        #expect(CursorMemoryChoice.from(reply: .object(["mode": .string("start")])) == .start)
        #expect(CursorMemoryChoice.from(reply: .object(["mode": .string("talvez")])) == nil)
        #expect(CursorMemoryChoice.from(reply: .null) == nil)
    }

    @Test func copySaysWhereTheDataGoesAndWhenItApplies() {
        let t = CursorMemoryChoice.full.detail
        #expect(t.contains("Cursor") && t.contains("memory_task") && t.contains("nuvem"), "\(t)")
        #expect(CursorMemoryChoice.off.detail.contains("Nenhuma memória"))
        #expect(CursorMemoryChoice.sessionsNote == "Vale para sessões novas.")
        #expect(CursorMemoryChoice.allowlistNote == "Na primeira chamada, escolha *Add to allowlist*.")
        #expect(CursorMemoryChoice.honest.hasPrefix("No Cursor a memória chega no início da sessão"))
    }

    @Test func untrustedDecodes() {
        let reply: JSONValue = .array([
            .object(["id": .string("a1"), "kind": .string("decision"), "title": .string("Deploy"), "status": .string("active"),
                     "repo": .string("/r"), "file": .string("/r/.collie/memory/x.md"), "before": .string("a\nb"), "after": .string("a\nc")]),
            .object(["id": .string("b2"), "kind": .string("feedback"), "title": .string("Plantada"), "status": .string("active"),
                     "lot": .string("Slides"), "file": .string("/l/x.md"), "after": .string("z")]),
            .string("lixo")])
        let xs = UntrustedMemory.list(reply)
        #expect(xs.count == 2 && xs[0].where == "/r" && xs[1].where == "lote Slides" && xs[1].before == nil)
        #expect(xs[0].trustArgs == ["id": .string("a1"), "repo": .string("/r")])
        #expect(xs[1].trustArgs == ["id": .string("b2"), "lot": .string("Slides")])
        #expect(xs[1].summary == "Arquivo que o Collie nunca gravou (criado à mão, por um agente ou por git).")
        #expect(xs[0].summary == "Editado fora do Collie depois da última gravação dele.")
    }

    @Test func diffByLines() {
        #expect(UntrustedMemory.diff(before: "a\nb\nc", after: "a\nB\nc") == [.same("a"), .removed("b"), .added("B"), .same("c")])
        #expect(UntrustedMemory.diff(before: nil, after: "x\ny") == [.added("x"), .added("y")])
        #expect(UntrustedMemory.diff(before: "x", after: "x") == [.same("x")])
    }

    @Test func ledgerNote() {
        #expect(UntrustedMemory.ledgerNote(.object(["restarted": .bool(false), "adopted": .number(0)])) == nil)
        #expect(UntrustedMemory.ledgerNote(.object(["restarted": .bool(false), "adopted": .number(12)]))
                == "12 memórias que já existiam foram aceitas como do Collie na primeira leitura.")
        #expect(UntrustedMemory.ledgerNote(.object(["restarted": .bool(false), "adopted": .number(1)]))
                == "1 memória que já existia foi aceita como do Collie na primeira leitura.")
        let r = UntrustedMemory.ledgerNote(.object(["restarted": .bool(true), "adopted": .number(3)]))
        #expect(r?.hasPrefix("O registro de quem gravou cada memória estava danificado e recomeçou") == true, "\(r ?? "nil")")
    }
}

/// The terminal card's memory badge for a Cursor (C6), from `memory.stats --terminal` (`byAgent.cursor`).
struct CursorMemoryBadgeTests {
    private func stats(_ cursor: [String: JSONValue]?) -> JSONValue {
        .object(["byAgent": .object(cursor.map { ["cursor": .object($0)] } ?? [:])])
    }

    @Test func onlyCursorTerminals() {
        #expect(CursorMemoryBadge.isCursor(preset: .cursor, command: nil))
        #expect(CursorMemoryBadge.isCursor(preset: .custom, command: "/usr/bin/env FOO=1 /opt/bin/cursor-agent --model m"))
        #expect(!CursorMemoryBadge.isCursor(preset: .custom, command: "codex"))
        #expect(!CursorMemoryBadge.isCursor(preset: .claude, command: nil))
    }

    @Test func countsPullsAndStart() {
        let b = CursorMemoryBadge.state(stats(["sessionsWithStart": .number(1), "pulls": .number(3), "asksDelivered": .number(0)]))
        #expect(b?.text == "Memória: início ✓ · 3 consultas" && b?.warn == false)
        #expect(CursorMemoryBadge.state(stats(["sessionsWithStart": .number(0), "pulls": .number(1)]))?.text == "Memória: sem início · 1 consulta")
        #expect(b?.help.contains("cobre só pedidos feitos pelo Collie; o que você digita no Cursor não é visto") == true)
        #expect(CursorMemoryBadge.state(stats(nil)) == nil && CursorMemoryBadge.state(.null) == nil)
    }

    @Test func warnsAfterTwoAsksWithoutAPull() {
        let b = CursorMemoryBadge.state(stats(["sessionsWithStart": .number(1), "pulls": .number(0), "asksDelivered": .number(2)]))
        #expect(b?.warn == true && b?.help.hasPrefix("o agente não está consultando a memória") == true, "\(b?.help ?? "")")
        #expect(CursorMemoryBadge.state(stats(["pulls": .number(0), "asksDelivered": .number(1)]))?.warn == false)
    }
}
