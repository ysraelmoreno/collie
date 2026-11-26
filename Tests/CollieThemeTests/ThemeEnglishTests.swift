import Foundation
import Testing
import CollieCore
import CollieTheme

@Suite(.themeEN) struct ThemeEnglishTests {
    @Test func parseErrorsSpeakEnglish() {
        #expect(ThemeError.invalidJSON.message == "invalid JSON")
        #expect(ThemeError.missing("name").message == "missing \"name\"")
        #expect(ThemeError.unknownRole("x").message == "unknown role: \"x\"")
    }
    @Test func paletteRolesAreNamedInEnglish() {
        let names = Palette.roles.map(\.name)
        #expect(names.contains("Background") && names.contains("Soft border") && names.contains("Danger"))
        #expect(PaletteRole.Group.destaques.title == "Accents")
    }
    @Test func jsonErrorPrefix() {
        var m = ThemeEditorModel(theme: ThemeFile(name: "T", extends: .dark))
        m.setJSON("{")
        #expect(m.jsonError?.hasPrefix("not applied: ") == true)
    }
}
