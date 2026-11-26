import Foundation
import Testing
import CollieTheme
@testable import CollieApp

private struct Call: Equatable {
    var selection: ThemeSelection
    var theme: ThemeFile?
}

@MainActor private final class Rig {
    let folder: URL
    let defaults: UserDefaults
    var calls: [Call] = []
    let model: ThemeGalleryModel

    init(preference: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-gallery-\(UUID().uuidString)")
        folder = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "collie-gallery-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let preference { defaults.set(preference, forKey: AppearanceKeys.theme) }
        var sink: (ThemeSelection, ThemeFile?) -> Void = { _, _ in }
        model = ThemeGalleryModel(library: ThemeLibrary(folder: folder), defaults: defaults, apply: { sink($0, $1) })
        sink = { [unowned self] s, t in calls.append(Call(selection: s, theme: t)) }
    }

    func put(_ theme: ThemeFile, id: String) throws {
        try theme.data.write(to: folder.appendingPathComponent(id + ".json"))
    }

    func put(raw: String, id: String) throws {
        try Data(raw.utf8).write(to: folder.appendingPathComponent(id + ".json"))
    }

    func card(_ id: String) throws -> ThemeCard { try #require(model.cards.first { $0.id == id }) }
    var stored: String? { defaults.string(forKey: AppearanceKeys.theme) }
}

private let tinta = ThemeFile(name: "Tinta", extends: .dark, colors: ["accent": RGB(hex: 0xFF00AA)])

@MainActor @Test(.appPT) func cardsComeInOrder() throws {
    let rig = try Rig()
    try rig.put(ThemeFile(name: "Beta", extends: .dark), id: "b")
    try rig.put(ThemeFile(name: "Alfa", extends: .light), id: "a")
    try rig.put(raw: "{", id: "bad")
    rig.model.start()

    #expect(rig.model.cards.map(\.id) ==
            ["builtin:dark", "builtin:light", "builtin:system", "custom:a", "custom:b", "broken:bad"])
    #expect(rig.model.cards.map(\.name) == ["Escuro", "Claro", "Sistema", "Alfa", "Beta", "bad.json"])
    #expect(rig.model.cards.map(\.subtitle) == ["do Collie", "do Collie", "segue o macOS", "a.json", "b.json", "JSON inválido"])
    let dark = try rig.card("builtin:dark")
    #expect(rig.model.isSelected(dark))
}

@MainActor @Test(.appPT) func selectingStoresThePreferenceAndApplies() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    #expect(rig.calls == [Call(selection: .dark, theme: nil)])

    let custom = try rig.card("custom:tinta")
    rig.model.select(custom)
    #expect(rig.stored == "custom:tinta")
    #expect(rig.calls.last == Call(selection: .custom("tinta"), theme: tinta))
    #expect(rig.model.isSelected(custom))

    rig.model.select(try rig.card("builtin:light"))
    #expect(rig.stored == "light")
    #expect(rig.calls.last == Call(selection: .light, theme: nil))
}

@MainActor @Test(.appPT) func aBrokenCardDoesNotSelect() throws {
    let rig = try Rig()
    try rig.put(raw: "{", id: "bad")
    rig.model.start()

    rig.model.select(try rig.card("broken:bad"))

    #expect(rig.stored == nil)
    #expect(rig.calls.count == 1)
    #expect(rig.model.selection == .dark)
}

@MainActor @Test(.appPT) func newFromBuiltInCreatesNamesAndSelects() throws {
    let rig = try Rig()
    rig.model.start()

    rig.model.newFrom(try rig.card("builtin:light"))

    let card = try #require(rig.model.cards.first { $0.name == "Claro (cópia)" })
    #expect(card.isCustom && rig.model.isSelected(card))
    let theme = try #require(rig.model.entries.first?.theme)
    #expect(theme == ThemeFile(name: "Claro (cópia)", extends: .light))
    #expect(rig.stored == card.selection?.rawValue)
    let selection = try #require(card.selection)
    #expect(rig.calls.last == Call(selection: selection, theme: theme))
}

@MainActor @Test(.appPT) func newFromACustomThemeKeepsItsColors() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()

    rig.model.newFrom(try rig.card("custom:tinta"))

    let copy = try #require(rig.model.entries.first { $0.theme?.name == "Tinta (cópia)" }?.theme)
    #expect(copy.colors == tinta.colors && copy.extends == .dark)
    #expect(rig.model.entries.count == 2)
}

@MainActor @Test(.appPT) func newFromIsNotOfferedForSistemaOrABrokenCard() throws {
    let rig = try Rig()
    try rig.put(raw: "{", id: "bad")
    rig.model.start()
    let offered = rig.model.cards.filter(\.canBeBase).map(\.id)
    #expect(offered == ["builtin:dark", "builtin:light"])

    rig.model.newFrom(try rig.card("builtin:system"))
    rig.model.newFrom(try rig.card("broken:bad"))

    #expect(rig.model.entries.count == 1)
    #expect(rig.stored == nil)
}

@MainActor @Test(.appPT) func deletingTheSelectedGoesBackToEscuro() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))

    rig.model.delete(try rig.card("custom:tinta"))

    #expect(rig.model.error == nil)
    #expect(rig.stored == "dark")
    #expect(rig.calls.last == Call(selection: .dark, theme: nil))
    #expect(!rig.model.cards.contains { $0.id == "custom:tinta" })
    #expect(!FileManager.default.fileExists(atPath: rig.folder.appendingPathComponent("tinta.json").path))
}

@MainActor @Test(.appPT) func deletingAnotherThemeKeepsTheSelection() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    try rig.put(ThemeFile(name: "Outro", extends: .light), id: "outro")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))
    let before = rig.calls.count

    rig.model.delete(try rig.card("custom:outro"))

    #expect(rig.stored == "custom:tinta")
    #expect(rig.calls.count == before)
}

@MainActor @Test(.appPT) func changingTheSelectedFileOnDiskAppliesAgain() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))
    let before = rig.calls.count

    let changed = ThemeFile(name: "Tinta", extends: .dark, colors: ["accent": RGB(hex: 0x00FF00)])
    try rig.put(changed, id: "tinta")
    rig.model.reload()

    #expect(rig.calls.count == before + 1)
    #expect(rig.calls.last == Call(selection: .custom("tinta"), theme: changed))
    #expect(rig.stored == "custom:tinta")
}

@MainActor @Test(.appPT) func reloadingTwiceForOneChangeAppliesOnce() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))
    let before = rig.calls.count

    try rig.put(ThemeFile(name: "Tinta", extends: .dark, colors: ["accent": RGB(hex: 0x00FF00)]), id: "tinta")
    rig.model.reload()
    rig.model.reload()
    rig.model.sync()

    #expect(rig.calls.count == before + 1)
}

@MainActor @Test(.appPT) func reloadingWithoutChangeAppliesNothing() throws {
    let rig = try Rig()
    rig.model.start()
    rig.model.reload()
    rig.model.reload()
    #expect(rig.calls == [Call(selection: .dark, theme: nil)])
}

@MainActor @Test(.appPT) func deletingTheSelectedFileOnDiskGoesBackToEscuro() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))

    try FileManager.default.removeItem(at: rig.folder.appendingPathComponent("tinta.json"))
    rig.model.reload()

    #expect(rig.stored == "dark")
    #expect(rig.calls.last == Call(selection: .dark, theme: nil))
    #expect(rig.model.selection == .dark)
}

@MainActor @Test(.appPT) func breakingTheSelectedFileOnDiskGoesBackToEscuroAndTheCardIsBroken() throws {
    let rig = try Rig()
    try rig.put(tinta, id: "tinta")
    rig.model.start()
    rig.model.select(try rig.card("custom:tinta"))

    try rig.put(raw: "{", id: "tinta")
    rig.model.reload()

    #expect(rig.stored == "dark")
    #expect(rig.calls.last == Call(selection: .dark, theme: nil))
    #expect(rig.model.cards.contains { $0.id == "broken:tinta" })
}

@MainActor @Test(.appPT) func startWithTheSavedCustomThemeAppliesItFirst() throws {
    let rig = try Rig(preference: "custom:tinta")
    try rig.put(tinta, id: "tinta")

    rig.model.start()

    #expect(rig.calls == [Call(selection: .custom("tinta"), theme: tinta)])
}

@MainActor @Test(.appPT) func startWithAMissingCustomThemeAppliesEscuroAndKeepsThePreference() throws {
    let rig = try Rig(preference: "custom:fantasma")

    rig.model.start()
    #expect(rig.calls == [Call(selection: .custom("fantasma"), theme: nil)])   // no theme: the app applies Escuro
    #expect(rig.stored == "custom:fantasma")

    rig.model.reload()
    #expect(rig.calls.count == 1)
    #expect(rig.stored == "custom:fantasma")

    try rig.put(tinta, id: "fantasma")   // it shows up later: it is applied then
    rig.model.reload()
    #expect(rig.calls.last == Call(selection: .custom("fantasma"), theme: tinta))
}

@MainActor @Test(.appPT) func importingAnInvalidFileShowsTheReasonAndDoesNotEnter() throws {
    let rig = try Rig()
    rig.model.start()
    let outside = rig.folder.deletingLastPathComponent().appendingPathComponent("x.json")
    try Data("{}".utf8).write(to: outside)

    rig.model.importFile(outside)

    #expect(rig.model.error == "falta \"name\"")
    #expect(rig.model.entries.isEmpty)
}

@MainActor @Test(.appPT) func importingAValidFileAddsACardWithoutSelectingIt() throws {
    let rig = try Rig()
    rig.model.start()
    let outside = rig.folder.deletingLastPathComponent().appendingPathComponent("gruvbox.json")
    try tinta.data.write(to: outside)

    rig.model.importFile(outside)

    #expect(rig.model.error == nil)
    #expect(rig.model.cards.contains { $0.id == "custom:gruvbox" })
    #expect(rig.stored == nil)
    #expect(rig.calls.count == 1)
}
