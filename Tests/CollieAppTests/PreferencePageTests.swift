import Testing
import CollieCore
import CollieProtocol
@testable import CollieApp

/// Preferências option B: the sidebar's pages, groups and search.
@Test(.appPT) func emptyQueryListsAllPagesInSidebarOrder() {
    #expect(PreferencePage.matching("") == [.aparencia, .terminal, .atualizacoes, .diagnostico, .desenho, .lacos, .memoria, .plugins, .celular, .android])
    #expect(PreferencePage.matching("").map(\.group) == ["Interface", "Interface", "Interface", "Interface", "Agentes", "Agentes", "Agentes", "Agentes", "Dispositivos", "Dispositivos"])
}

/// L3: what the status bar showed lives in Diagnóstico (Interface), found by its words in either language.
@Test(.appPT) func diagnosticoHoldsTheOldStatusLine() {
    #expect(PreferencePage.diagnostico.title == "Diagnóstico" && PreferencePage.diagnostico.group == "Interface")
    #expect(PreferencePage.matching("conexão") == [.diagnostico])
    #expect(PreferencePage.matching("rss") == [.diagnostico])
    #expect(PreferencePage.matching("status").contains(.diagnostico))
    #expect(PreferencePage.requested("diagnostico") == .diagnostico)
    #expect(!PreferencePage.matching("compacta").contains(.aparencia))   // Completa/Compacta is gone
}

/// Spec 2026-11-17 §3: Atualizações in the Interface group, found by its words.
@Test(.appPT) func atualizacoesInInterfaceGroup() {
    #expect(PreferencePage.atualizacoes.title == "Atualizações" && PreferencePage.atualizacoes.group == "Interface")
    #expect(PreferencePage.atualizacoes.icon == "↻")
    #expect(PreferencePage.matching("versão").contains(.atualizacoes))
    #expect(PreferencePage.matching("atualizacao").contains(.atualizacoes))
}

@Test(.appPT) func searchMatchesTitleOrKeywords() {
    #expect(PreferencePage.matching("licença").contains(.android))
    #expect(PreferencePage.matching("java").contains(.android))
    #expect(PreferencePage.matching("fonte").contains(.terminal))
    #expect(PreferencePage.matching("zzz").isEmpty)
}

@Test(.appPT) func searchIgnoresCaseAndDiacritics() {
    #expect(PreferencePage.matching("LICENCA").contains(.android))
    #expect(PreferencePage.matching("memoria") == [.memoria])
    #expect(PreferencePage.matching("  Aparência ").contains(.aparencia))
}

@Test(.appPT) func motorFindsDesenho() {
    #expect(PreferencePage.matching("motor") == [.desenho])
    #expect(PreferencePage.matching("reinstalar") == [.desenho])
}

/// Desenho e sandbox's badge from `design.engine.status`: `↓` while a job runs, `!` after a failed one or when the engine is stale.
@Test(.appPT) func designBadgeStates() {
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
@Test(.appPT) func androidBadgeFromStatus() {
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

/// `collieOpenPreferences` (posted by the Design panel's Abrir Preferências): its object names the page.
@Test(.appPT) func openRequestNamesPage() {
    #expect(PreferencePage.requested("desenho") == .desenho)
    #expect(PreferencePage.requested("android") == .android)
    #expect(PreferencePage.requested("lacos") == .lacos)
    #expect(PreferencePage.requested("nada") == nil)
    #expect(PreferencePage.requested(nil) == nil)
    #expect(PreferencePage.requested(3) == nil)
}

@Test(.appPT) func preferencePageListsCurator() {
    for q in ["curador", "provedor", "consentimento", "Cursor"] { #expect(PreferencePage.matching(q).contains(.memoria), "\(q)") }
}

/// B6.3: "Laços sem cartão" left Desenho e sandbox for its own page, Laços, in the Agentes group.
@Test(.appPT) func lacosPageOwnsLoopTrustWords() {
    #expect(PreferencePage(rawValue: "lacos") == .lacos)
    #expect(PreferencePage.lacos.title == "Laços" && PreferencePage.lacos.group == "Agentes")
    for q in ["laço", "lacos", "revogar", "cartão", "loop", "work run"] {
        #expect(PreferencePage.matching(q).contains(.lacos), "\(q)")
        #expect(!PreferencePage.matching(q).contains(.desenho), "\(q)")
    }
    #expect(PreferencePage.matching("sandbox") == [.desenho])
}

@Test(.appPT) func everyPageHasTitleGroupIconAndKeywords() {
    for p in PreferencePage.allCases {
        #expect(!p.title.isEmpty && !p.group.isEmpty && !p.icon.isEmpty && !p.keywords.isEmpty, "\(p)")
    }
    #expect(Set(PreferencePage.allCases.map(\.icon)).count == PreferencePage.allCases.count)
}
