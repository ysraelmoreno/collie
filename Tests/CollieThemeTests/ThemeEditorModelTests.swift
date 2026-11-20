import Foundation
import Testing
import CollieTheme

private func model() -> ThemeEditorModel {
    ThemeEditorModel(theme: ThemeFile(name: "Meu", extends: .dark))
}

@Test func editorRowsCoverEighteenRolesInGroups() {
    let rows = model().rows
    #expect(rows.count == 18)
    #expect(rows.map(\.key) == Palette.roles.map(\.key))
    #expect(rows.filter { $0.group == .fundos }.count == 5)
    #expect(rows.filter { $0.group == .texto }.count == 3)
    #expect(rows.filter { $0.group == .destaques }.count == 6)
    #expect(rows.filter { $0.group == .outros }.count == 4)
    #expect(rows.allSatisfy { !$0.changed })
}

@Test func editorSetShowsInJSONAndMarksChanged() throws {
    var m = model()
    m.set("accent", RGB(hex: 0xFF0000))
    let row = try #require(m.rows.first { $0.key == "accent" })
    #expect(row.changed)
    #expect(row.color == RGB(hex: 0xFF0000))
    #expect(m.jsonText.contains("\"accent\": \"#FF0000\""))
}

@Test func editorSetEqualToInheritedStillCounts() throws {
    var m = model()
    m.set("accent", Palette.dark.accent)
    let row = try #require(m.rows.first { $0.key == "accent" })
    #expect(row.changed)
}

@Test func editorResetDropsKeyFromJSON() throws {
    var m = model()
    m.set("accent", RGB(hex: 0xFF0000))
    m.reset("accent")
    let row = try #require(m.rows.first { $0.key == "accent" })
    #expect(!row.changed)
    #expect(row.color == Palette.dark.accent)
    #expect(!m.jsonText.contains("accent"))
}

@Test func editorBackgroundChangeUpdatesReadings() throws {
    var m = model()
    let before = try #require(m.rows.first { $0.key == "text" })
    #expect(before.low == false)
    m.set("surface", RGB(hex: 0xFFFFFF)) // near-white text on white
    let after = try #require(m.rows.first { $0.key == "text" })
    #expect(after.low)
    let (ra, rb) = (try #require(after.ratio), try #require(before.ratio))
    #expect(ra < rb)
}

@Test func editorRowsWithoutReadingHaveNoRatio() throws {
    let row = try #require(model().rows.first { $0.key == "border" })
    #expect(row.ratio == nil)
    #expect(row.low == false)
}

@Test func editorValidJSONChangesRows() throws {
    var m = model()
    var other = ThemeFile(name: "Outro", extends: .light)
    other.colors["accent"] = RGB(hex: 0x123456)
    m.setJSON(String(decoding: other.data, as: UTF8.self))
    #expect(m.theme == other)
    #expect(m.jsonError == nil)
    let row = try #require(m.rows.first { $0.key == "accent" })
    #expect(row.changed)
    #expect(row.color == RGB(hex: 0x123456))
    let bg = try #require(m.rows.first { $0.key == "background" })
    #expect(bg.color == Palette.light.background)
}

@Test func editorInvalidJSONKeepsTextThemeAndRows() {
    var m = model()
    m.set("accent", RGB(hex: 0xFF0000))
    let rows = m.rows
    let theme = m.theme
    m.setJSON("nope")
    #expect(m.jsonText == "nope")
    #expect(m.theme == theme)
    #expect(m.rows == rows)
    #expect(m.jsonError == "não aplicado: JSON inválido")
}

@Test func editorBackToValidJSONClearsError() {
    var m = model()
    m.setJSON("nope")
    m.setJSON(String(decoding: ThemeFile(name: "Meu", extends: .dark).data, as: UTF8.self))
    #expect(m.jsonError == nil)
}

@Test func editorListEditAfterInvalidJSONReplacesText() {
    var m = model()
    m.setJSON("nope")
    m.set("accent", RGB(hex: 0xFF0000))
    #expect(m.jsonError == nil)
    #expect(m.jsonText == String(decoding: m.theme.data, as: UTF8.self))
}

@Test func editorRenameValidAndInvalid() {
    var m = model()
    m.rename("Novo nome")
    #expect(m.theme.name == "Novo nome")
    #expect(m.jsonText.contains("\"name\": \"Novo nome\""))
    let text = m.jsonText
    for bad in ["", String(repeating: "a", count: 49), "a\u{7}b"] {
        m.rename(bad)
        #expect(m.theme.name == "Novo nome")
        #expect(m.jsonText == text)
    }
}

@Test func editorPendingSaveTracksValidEditsOnly() throws {
    var m = model()
    #expect(m.pendingSave == nil)
    m.setJSON("nope")
    #expect(m.pendingSave == nil)
    m.set("accent", RGB(hex: 0xFF0000))
    #expect(try #require(m.pendingSave) == m.theme)
    m.markSaved()
    #expect(m.pendingSave == nil)
    #expect(m.palette == m.theme.palette)
}
