import Testing
import CollieProtocol
@testable import CollieApp

/// Preferências option B: the sidebar's pages, groups and search.
@Test func emptyQueryListsAllPagesInSidebarOrder() {
    #expect(PreferencePage.matching("") == [.aparencia, .terminal, .desenho, .memoria, .plugins, .celular, .android])
    #expect(PreferencePage.matching("").map(\.group) == ["Interface", "Interface", "Agentes", "Agentes", "Agentes", "Dispositivos", "Dispositivos"])
}

@Test func searchMatchesTitleOrKeywords() {
    #expect(PreferencePage.matching("licença").contains(.android))
    #expect(PreferencePage.matching("java").contains(.android))
    #expect(PreferencePage.matching("fonte").contains(.terminal))
    #expect(PreferencePage.matching("zzz").isEmpty)
}

@Test func searchIgnoresCaseAndDiacritics() {
    #expect(PreferencePage.matching("LICENCA").contains(.android))
    #expect(PreferencePage.matching("memoria") == [.memoria])
    #expect(PreferencePage.matching("  Aparência ").contains(.aparencia))
}

/// The Android item's badge comes from `android.status` alone: `↓` while a job runs, `!` after a failed one or while licenses wait.
@Test func androidBadgeFromStatus() {
    func s(_ phase: String?, needs: String = "needsPrepare") -> AndroidSetupStatus {
        AndroidSetupStatus(sdk: .init(path: "/x", source: "collie"), items: [], needs: needs,
                           job: phase.map { .init(phase: $0) }, lite: false)
    }
    #expect(PreferencePage.androidBadge(nil) == nil)
    #expect(PreferencePage.androidBadge(s(nil)) == nil)
    #expect(PreferencePage.androidBadge(s("prepare")) == "↓")
    #expect(PreferencePage.androidBadge(s("install")) == "↓")
    #expect(PreferencePage.androidBadge(s("failed")) == "!")
    #expect(PreferencePage.androidBadge(s("done")) == nil)
    #expect(PreferencePage.androidBadge(s("cancelled")) == nil)
    #expect(PreferencePage.androidBadge(s(nil, needs: "needsLicense")) == "!")
    #expect(PreferencePage.androidBadge(s("done", needs: "needsLicense")) == "!")
    #expect(PreferencePage.androidBadge(s("install", needs: "needsLicense")) == "↓")
    #expect(PreferencePage.androidBadge(s(nil, needs: "ready")) == nil)
}
