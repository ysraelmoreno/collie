import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieApp

/// One agent card per preset: known presets get the mockup's names; any other falls back to its raw value.
@Test func presetCards() {
    #expect(Preset.allCases.map(\.cardTitle) == ["Shell", "Claude", "Codex", "Próprio"])
    #expect(Preset.allCases.map(\.cardCommand) == ["zsh", "claude", "codex", "comando"])
}

@Test func designFirstPickerLabels() {
    #expect(DesignFirst.allCases.map(\.label) == ["Perguntar", "Sempre", "Nunca"])
    #expect(DesignFirst.from(reply: .object(["designFirst": .string("never")])) == .never)
    #expect(DesignFirst.from(reply: .object(["designFirst": .string("x")])) == nil)
}

@Test func lotPickerAndSidebarCopy() {
    let a = TerminalRecord(id: UUID(), name: "a", preset: .shell, command: nil, cwd: "/", isShepherd: false)
    let lots = [Lot(name: "zeta"), Lot(name: "Alfa", goal: "login", members: [a.id, UUID()])]
    #expect(LotChoice.all(lots).map(\.title) == ["Sem lote", "Alfa", "zeta"])
    #expect(LotChoice.all([]).map(\.id) == [nil])
    #expect(LotSummary.memberNames(lots[1], terminals: [a]) == ["a"])   // a gone terminal is skipped
    #expect(LotSummary.help(lots[1], names: ["a"]) == "Alfa · login · 1 terminal")
    #expect(LotSummary.help(lots[0], names: []) == "zeta · sem terminais")
}

@Test func lotBoardPostHeader() throws {
    let p = LotPost(kind: "handoff", from: "A", toName: "B", ref: "w1", text: "pronto")
    let h = LotSummary.postHeader(p)
    #expect(h.hasPrefix("entrega · A → B · ref w1 · "))
    #expect(LotSummary.postHeader(LotPost(kind: "future", from: "app", text: "x")).hasPrefix("future · app · "))
    // the board reply decodes into posts (ISO dates)
    let json = #"[{"id":"\#(p.id.uuidString)","at":"2026-10-23T12:00:00Z","kind":"status","from":"A","text":"oi"}]"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    #expect(try d.decode([LotPost].self, from: Data(json.utf8)).first?.text == "oi")
}

@Test func accessCardCopy() throws {
    #expect(["read", "write", "delete", "exec"].map(AccessCopy.verb) == ["ler", "escrever", "apagar", "executar"])
    let claude = TerminalRecord(id: UUID(), name: "a", preset: .claude, command: nil, cwd: "/", isShepherd: false)
    let codex = TerminalRecord(id: UUID(), name: "b", preset: .codex, command: nil, cwd: "/", isShepherd: false)
    #expect(AccessCopy.resumeNote(claude).contains("retoma a conversa"))
    #expect(AccessCopy.resumeNote(codex).contains("sem retomar"))
    // R29: control and bidi characters spelled out; distinct card ids per (op, folder)
    #expect(AccessCopy.shown("a\u{202E}txt.exe\nb é") == "a\\u{202E}txt.exe\\u{A}b é")
    let r = SandboxDenial(terminal: UUID(), op: "read", path: "/x/a"), w = SandboxDenial(terminal: r.terminal, op: "write", path: "/x/b")
    #expect(r.cardId != w.cardId)
    // the card and the detection state cross the events stream intact
    let d = SandboxDenial(terminal: UUID(), op: "read", path: "/Users/u/Doc é/x", count: 3, requested: true, reason: "r", refusal: nil, folderRefusal: "Amplo")
    for e in [WorkspaceEvent.sandboxDenied(d), .sandboxDetection(available: false)] {
        #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: JSONEncoder().encode(e)) == e)
    }
    #expect(d.folder == "/Users/u/Doc é" && d.access == .read)
}
