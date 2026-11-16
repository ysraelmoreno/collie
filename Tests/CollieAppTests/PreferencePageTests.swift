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

@Test func motorFindsDesenho() {
    #expect(PreferencePage.matching("motor") == [.desenho])
    #expect(PreferencePage.matching("reinstalar") == [.desenho])
}

/// Desenho e sandbox's badge from `design.engine.status`: `↓` while a job runs, `!` after a failed one or when the engine is stale.
@Test func designBadgeStates() {
    func s(_ state: String, _ phase: String? = nil) -> DesignEngineStatus {
        var o: [String: JSONValue] = ["state": .string(state)]
        if let phase { o["job"] = .object(["phase": .string(phase)]) }
        return DesignEngineStatus.from(.object(o))!
    }
    #expect(PreferencePage.designBadge(nil) == nil)
    #expect(PreferencePage.designBadge(s("absent")) == nil)
    #expect(PreferencePage.designBadge(s("installed")) == nil)
    #expect(PreferencePage.designBadge(s("absent", "downloading")) == "↓")
    #expect(PreferencePage.designBadge(s("absent", "verifying")) == "↓")
    #expect(PreferencePage.designBadge(s("needsUpdate", "installing")) == "↓")
    #expect(PreferencePage.designBadge(s("absent", "failed")) == "!")
    #expect(PreferencePage.designBadge(s("needsUpdate")) == "!")
    #expect(PreferencePage.designBadge(s("installed", "done")) == nil)
    #expect(PreferencePage.designBadge(s("absent", "cancelled")) == nil)
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
