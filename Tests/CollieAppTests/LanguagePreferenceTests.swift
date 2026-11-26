import Testing
import CollieCore
import CollieProtocol
@testable import CollieApp

@Test func restartOnlyWhenResolvedLanguageChanges() {
    #expect(!LanguagePreference.needsRestart(old: .system, new: .pt, preferred: ["pt-BR"]))
    #expect(LanguagePreference.needsRestart(old: .pt, new: .en, preferred: ["pt-BR"]))
    #expect(LanguagePreference.needsRestart(old: .system, new: .pt, preferred: ["en-US"]))
    #expect(!LanguagePreference.needsRestart(old: .en, new: .system, preferred: ["fr"]))
}

@Test func languageReplyDecodes() {
    #expect(LanguagePreference.from(reply: .object(["language": .string("en"), "active": .string("en")])) == .en)
    #expect(LanguagePreference.from(reply: .object(["language": .string("xx")])) == nil)
    #expect(LanguagePreference.from(reply: .string("en")) == nil)
}

@Test func languageLabelsFollowActiveLanguage() {
    L10n.$override.withValue(.pt) { #expect(LanguagePreference.label(.system) == "Sistema") }
    L10n.$override.withValue(.en) { #expect(LanguagePreference.label(.system) == "System") }
    #expect(LanguagePreference.label(.pt) == "Português" && LanguagePreference.label(.en) == "English")
}

/// Preferences speak English under `.en` (spec 2026-11-26 idiomas); the technical ids and group keys stay the same.
@Suite(.appEN) struct PreferencesEnglishTests {
    @Test func pageTitlesAndGroups() {
        #expect(PreferencePage.atualizacoes.title == "Updates" && PreferencePage.lacos.title == "Loops")
        #expect(PreferencePage.groupTitle("Agentes") == "Agents" && PreferencePage.lacos.group == "Agentes")
    }
    @Test func searchFindsEitherLanguage() {
        #expect(PreferencePage.matching("licença").contains(.android) && PreferencePage.matching("license").contains(.android))
        #expect(PreferencePage.matching("language").contains(.aparencia))
    }
    @Test func androidAndUpdateCopy() {
        #expect(AndroidCopy.label(for: .nada).button == "Install")
        #expect(UpdateModel.localBuild == "Local build: update with the scripts")
        #expect(UpdateModel.rollbackLabel(previous: "0.1.3") == "Go back to 0.1.3")
    }
    @Test func engineAndCursorCopy() {
        #expect(DesignEngineRow.absent(download: "").button == "Download")
        #expect(CursorMemoryChoice.off.label == "Off")
        #expect(PluginCatalogModel.size(800_000) == "0.8 MB")
    }
}
