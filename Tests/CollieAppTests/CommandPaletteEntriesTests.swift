import Testing
@testable import CollieApp

/// L6: ⌘K reaches what left the screen; each entry is a command that runs its own action.
@MainActor @Suite(.appPT) struct CommandPaletteEntriesTests {
    @Test func everyEntryIsThere() {
        #expect(PaletteEntry.allCases == [.herds, .lots, .factory, .memory, .loops, .work, .tour, .diagnostics])
        let titles = PaletteEntry.allCases.map(\.title)
        #expect(titles == ["Rebanhos…", "Lotes…", "Fábrica…", "Memória", "Laços…", "Trabalho", "Tour das funções", "Diagnóstico"])
    }

    @Test func eachCommandRunsItsEntry() {
        var ran: [PaletteEntry] = []
        let commands = PaletteEntry.commands { e in { ran.append(e) } }
        #expect(Set(commands.map(\.id)).count == PaletteEntry.allCases.count)
        for c in commands { c.run() }
        #expect(ran == PaletteEntry.allCases)
    }

    @Test func theFilterFindsThemByWord() {
        let commands = PaletteEntry.commands { _ in {} }
        for word in ["Rebanhos", "Memória", "Laços", "Tour"] {
            #expect(CommandPalette.filter(commands, word).count == 1, "\(word)")
        }
    }

    @Test func aLeftOutEntryHasNoCommand() {
        let ids = PaletteEntry.commands(PaletteEntry.allCases.filter { $0 != .factory }) { _ in {} }.map(\.id)
        #expect(!ids.contains("entry.factory") && ids.count == PaletteEntry.allCases.count - 1)
    }
}
