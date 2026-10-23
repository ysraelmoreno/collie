import Testing
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
