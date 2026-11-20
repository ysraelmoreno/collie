import Foundation
import Testing
import CollieTheme
@testable import CollieApp

@MainActor private final class FakeScheduler: ThemeEditScheduler {
    private(set) var delays: [TimeInterval] = []
    private var work: (@MainActor () -> Void)?

    var hasPending: Bool { work != nil }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        delays.append(seconds)
        self.work = work
    }

    func cancel() { work = nil }

    /// The wait ends: runs the pending work, if any.
    func fire() {
        let w = work
        work = nil
        w?()
    }
}

@MainActor private final class Disk {
    var saves: [ThemeFile] = []
    var failing = false
}

@MainActor private struct Rig {
    let scheduler = FakeScheduler()
    let disk = Disk()
    let session: ThemeEditorSession

    init(_ theme: ThemeFile = base) {
        let disk = disk
        session = ThemeEditorSession(id: "tinta", theme: theme, scheduler: scheduler) { t in
            if disk.failing { throw ThemeLibrary.LibraryError.writeFailed }
            disk.saves.append(t)
        }
    }
}

private let base = ThemeFile(name: "Tinta", extends: .dark, colors: ["accent": RGB(hex: 0x112233)])
private let other = ThemeFile(name: "Fora", extends: .light, colors: ["text": RGB(hex: 0x445566)])

@MainActor @Test func aBurstWritesOnceAfterTheWait() {
    let rig = Rig()
    rig.session.set("muted", RGB(hex: 0x010203))
    rig.session.set("text", RGB(hex: 0x040506))
    rig.session.set("muted", RGB(hex: 0x070809))
    #expect(rig.disk.saves.isEmpty)
    #expect(rig.scheduler.delays == [0.3, 0.3, 0.3])

    rig.scheduler.fire()
    #expect(rig.disk.saves.count == 1)
    #expect(rig.disk.saves.first?.colors["muted"] == RGB(hex: 0x070809))
    #expect(rig.disk.saves.first?.colors["text"] == RGB(hex: 0x040506))
    #expect(rig.disk.saves.first?.colors["accent"] == RGB(hex: 0x112233))
    #expect(rig.session.model.pendingSave == nil)

    rig.scheduler.fire()
    #expect(rig.disk.saves.count == 1)
}

@MainActor @Test func invalidJSONNeitherSchedulesNorWrites() {
    let rig = Rig()
    rig.session.setJSON("{")
    #expect(rig.session.model.jsonError == "não aplicado: JSON inválido")
    #expect(rig.session.model.jsonText == "{")
    #expect(!rig.scheduler.hasPending)
    rig.scheduler.fire()
    #expect(rig.disk.saves.isEmpty)
}

@MainActor @Test func validJSONWritesTheNewTheme() {
    let rig = Rig()
    rig.session.setJSON(String(decoding: other.data, as: UTF8.self))
    #expect(rig.session.model.jsonError == nil)
    rig.scheduler.fire()
    #expect(rig.disk.saves == [other])
}

@MainActor @Test func leavingWritesWhatIsPendingOnce() {
    let rig = Rig()
    rig.session.set("muted", RGB(hex: 0x010203))
    rig.session.flush()
    #expect(rig.disk.saves.count == 1)
    #expect(!rig.scheduler.hasPending)
    rig.session.flush()
    rig.scheduler.fire()
    #expect(rig.disk.saves.count == 1)
}

@MainActor @Test func aChangeFromDiskReloadsWhenNothingIsPending() {
    let rig = Rig()
    rig.session.external(other)
    #expect(rig.session.model.theme == other)
    #expect(rig.session.model.jsonText == String(decoding: other.data, as: UTF8.self))
    #expect(rig.session.model.pendingSave == nil)

    // the watcher may report the same change again
    rig.session.external(other)
    rig.session.external(nil)
    #expect(rig.session.model.theme == other)
    #expect(rig.disk.saves.isEmpty)
    #expect(!rig.scheduler.hasPending)
}

@MainActor @Test func theUsersPendingEditWinsOverADiskChange() throws {
    let rig = Rig()
    rig.session.set("muted", RGB(hex: 0x010203))
    rig.session.external(other)
    #expect(rig.session.model.theme.name == "Tinta")
    #expect(rig.session.model.theme.colors["muted"] == RGB(hex: 0x010203))

    rig.scheduler.fire()
    let saved = try #require(rig.disk.saves.last)
    #expect(saved.colors["muted"] == RGB(hex: 0x010203))
    #expect(saved.name == "Tinta")
}

@MainActor @Test func textThatIsNotValidYetIsNotReplacedByADiskChange() {
    let rig = Rig()
    rig.session.setJSON("{")
    rig.session.external(other)
    #expect(rig.session.model.jsonText == "{")
    #expect(rig.session.model.theme == base)
}

@MainActor @Test func aFailedWriteKeepsTheTextAndShowsTheWarning() {
    let rig = Rig()
    rig.disk.failing = true
    rig.session.set("muted", RGB(hex: 0xABCDEF))
    rig.scheduler.fire()
    #expect(rig.session.saveError == "não gravado: não foi possível gravar o arquivo")
    #expect(rig.session.model.jsonText.contains("#ABCDEF"))
    #expect(rig.session.model.pendingSave != nil)
    #expect(rig.disk.saves.isEmpty)

    rig.disk.failing = false
    rig.session.flush()
    #expect(rig.session.saveError == nil)
    #expect(rig.disk.saves.count == 1)
}

@Test func theReadingColumnText() {
    #expect(ThemeEditorFormat.reading(5.84, low: false) == "5,8")
    #expect(ThemeEditorFormat.reading(3.66, low: true) == "3,7 baixo")
    #expect(ThemeEditorFormat.reading(nil, low: false) == nil)
}

@Test func hexAcceptsWithOrWithoutTheHash() {
    #expect(ThemeEditorFormat.parseHex("#0a1B2c") == RGB(hex: 0x0A1B2C))
    #expect(ThemeEditorFormat.parseHex(" 0A1B2C ") == RGB(hex: 0x0A1B2C))
    #expect(ThemeEditorFormat.parseHex("0A1B2") == nil)
    #expect(ThemeEditorFormat.parseHex("zzzzzz") == nil)
}
