import Foundation
import Testing
import CollieTheme
@testable import CollieApp

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("collie-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func theme(_ name: String) -> ThemeFile { ThemeFile(name: name, extends: .dark) }

private func put(_ data: Data, _ name: String, in dir: URL) throws {
    try data.write(to: dir.appendingPathComponent(name))
}

/// Counts `onChange` calls and lets a test wait for the next one with a continuation (no timers).
@MainActor private final class Hits {
    var count = 0
    private var waiting: CheckedContinuation<Void, Never>?

    func hit() {
        count += 1
        waiting?.resume()
        waiting = nil
    }

    /// Runs `action` (on the main actor, so no event is delivered before the wait starts), then waits for a hit.
    func next(after action: () throws -> Void) async throws {
        var failure: (any Error)?
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting = c
            do { try action() } catch { failure = error; waiting = nil; c.resume() }
        }
        if let failure { throw failure }
    }
}

@MainActor @Test(.appPT) func missingFolderIsAnEmptyList() throws {
    let root = try tempRoot()
    let lib = ThemeLibrary(folder: root.appendingPathComponent("themes"))
    #expect(lib.reload().isEmpty)
}

@MainActor @Test(.appPT) func createMakesFolderAndFileThatReadBack() throws {
    let root = try tempRoot()
    let folder = root.appendingPathComponent("themes")
    let lib = ThemeLibrary(folder: folder)
    let base = ThemeFile(name: "Base", extends: .light, colors: ["accent": RGB(hex: 0x6E9BFF)])

    let id = try lib.create(from: base, name: "Meu Tema")

    #expect(id == "meu-tema")
    let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    let entries = lib.reload()
    #expect(entries.count == 1)
    #expect(entries[0].id == "meu-tema")
    #expect(entries[0].theme == ThemeFile(name: "Meu Tema", extends: .light, colors: ["accent": RGB(hex: 0x6E9BFF)]))
}

@MainActor @Test(.appPT) func collidingNamesGetNumberedIds() throws {
    let lib = ThemeLibrary(folder: try tempRoot().appendingPathComponent("themes"))
    #expect(try lib.create(from: theme("A"), name: "Meu Tema") == "meu-tema")
    #expect(try lib.create(from: theme("A"), name: "Meu Tema") == "meu-tema-2")
    #expect(try lib.create(from: theme("A"), name: "Meu Tema") == "meu-tema-3")
    #expect(lib.reload().count == 3)
}

@MainActor @Test(.appPT) func accentedNameBecomesAValidId() throws {
    let lib = ThemeLibrary(folder: try tempRoot().appendingPathComponent("themes"))
    let id = try lib.create(from: theme("A"), name: "Café Noturno")
    #expect(ThemeFile.validId(id))
    #expect(id.hasSuffix("-noturno"))
    #expect(ThemeLibrary.slug("!!!") == "tema")
    #expect(ThemeLibrary.slug("  Dark, Mode!  ") == "dark--mode")
}

@MainActor @Test(.appPT) func importedLongNameIsCutAt48AndStillCollides() throws {
    let root = try tempRoot()
    let src = root.appendingPathComponent(String(repeating: "a", count: 60) + ".json")
    try theme("Longo").data.write(to: src)
    let lib = ThemeLibrary(folder: root.appendingPathComponent("themes"))

    let first = try lib.importFile(src)
    let second = try lib.importFile(src)

    #expect(first == String(repeating: "a", count: 48))
    #expect(second == String(repeating: "a", count: 46) + "-2")
    #expect(ThemeFile.validId(second))
}

@MainActor @Test(.appPT) func brokenFilesAreListedLastWithTheirReason() throws {
    let root = try tempRoot()
    let folder = root.appendingPathComponent("themes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try put(Data("nope".utf8), "ruim.json", in: folder)
    try put(theme("Zeta").data, "zeta.json", in: folder)
    try put(theme("Alfa").data, "alfa.json", in: folder)
    try put(theme("Maiúscula").data, "Tema.JSON", in: folder)
    try put(Data(#"{"name":"","extends":"dark"}"#.utf8), "sem-nome.json", in: folder)

    let entries = ThemeLibrary(folder: folder).reload()

    #expect(entries.map(\.id).prefix(2) == ["alfa", "zeta"])
    #expect(entries.count == 5)
    let broken = Dictionary(uniqueKeysWithValues: entries.dropFirst(2).map { ($0.id, $0.problem) })
    #expect(broken["ruim"] == "JSON inválido")
    #expect(broken["sem-nome"] == #""name": use de 1 a 48 caracteres, sem controle"#)
    #expect(broken["Tema"] == "nome de arquivo inválido")
}

@MainActor @Test(.appPT) func symbolicLinksAreIgnored() throws {
    let root = try tempRoot()
    let folder = root.appendingPathComponent("themes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("fora.json")
    try theme("Fora").data.write(to: outside)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.json"), withDestinationURL: outside)

    #expect(ThemeLibrary(folder: folder).reload().isEmpty)
}

@MainActor @Test(.appPT) func onlyTwoHundredFilesAreRead() throws {
    let folder = try tempRoot().appendingPathComponent("themes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<205 { try put(theme("X").data, String(format: "t%03d.json", i), in: folder) }

    let entries = ThemeLibrary(folder: folder).reload()

    #expect(entries.count == 200)
    #expect(entries.first?.id == "t000")
    #expect(entries.last?.id == "t199")
}

@MainActor @Test(.appPT) func importRefusesInvalidAndLeavesNothing() throws {
    let root = try tempRoot()
    let folder = root.appendingPathComponent("themes")
    let bad = root.appendingPathComponent("ruim.json")
    try Data(#"{"name":"","extends":"dark"}"#.utf8).write(to: bad)
    let lib = ThemeLibrary(folder: folder)

    #expect(throws: ThemeError.badName) { try lib.importFile(bad) }

    #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    #expect(lib.reload().isEmpty)
}

@MainActor @Test(.appPT) func importCopiesAValidFile() throws {
    let root = try tempRoot()
    let src = root.appendingPathComponent("Meu Import.json")
    let original = ThemeFile(name: "Importado", extends: .dark, colors: ["accent": RGB(hex: 0x112233)])
    try original.data.write(to: src)
    let lib = ThemeLibrary(folder: root.appendingPathComponent("themes"))

    let id = try lib.importFile(src)

    #expect(id == "meu-import")
    #expect(lib.reload().first?.theme == original)
}

@MainActor @Test(.appPT) func saveKeepsTheOldFileWhenTheWriteFails() throws {
    let root = try tempRoot()
    let folder = root.appendingPathComponent("themes")
    let lib = ThemeLibrary(folder: folder)
    let id = try lib.create(from: theme("A"), name: "Original")
    let before = try Data(contentsOf: folder.appendingPathComponent("\(id).json"))

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    #expect(throws: (any Error).self) { try lib.save(theme("Outro"), id: id) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

    #expect(try Data(contentsOf: folder.appendingPathComponent("\(id).json")) == before)
    #expect(lib.reload().first?.theme?.name == "Original")
}

@MainActor @Test(.appPT) func saveReplacesTheFile() throws {
    let lib = ThemeLibrary(folder: try tempRoot().appendingPathComponent("themes"))
    let id = try lib.create(from: theme("A"), name: "Tema")
    let edited = ThemeFile(name: "Editado", extends: .light, colors: ["accent": RGB(hex: 0xABCDEF)])

    try lib.save(edited, id: id)

    #expect(lib.reload().first?.theme == edited)
}

@MainActor @Test(.appPT) func idsThatEscapeTheFolderAreRefused() throws {
    let root = try tempRoot()
    let lib = ThemeLibrary(folder: root.appendingPathComponent("themes"))

    #expect(throws: ThemeLibrary.LibraryError.invalidId) { try lib.save(theme("A"), id: "../x") }
    #expect(throws: ThemeLibrary.LibraryError.invalidId) { try lib.delete(id: "../x") }
    #expect(throws: ThemeLibrary.LibraryError.invalidId) { try lib.save(theme("A"), id: "Tema") }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x.json").path))
}

@MainActor @Test(.appPT) func watchSeesWritesAndDeletes() async throws {
    let folder = try tempRoot().appendingPathComponent("themes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let hits = Hits()
    let lib = ThemeLibrary(folder: folder) { hits.hit() }

    try await hits.next {
        for n in ["a", "b", "c"] { try put(theme(n).data, "\(n).json", in: folder) }
    }
    // a burst may arrive in more than one turn of the main queue: at least one call, and the list is whole
    #expect(hits.count >= 1)
    #expect(lib.reload().count == 3)
    let seen = hits.count

    try await hits.next { try FileManager.default.removeItem(at: folder.appendingPathComponent("b.json")) }
    #expect(hits.count > seen)
    #expect(lib.reload().count == 2)
}
