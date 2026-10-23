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
