import Testing
import CollieCore

@Suite struct L10nTests {
    @Test func systemPortugueseResolvesPt() { #expect(Lang.resolve(.system, preferred: ["pt-BR", "en"]) == .pt) }
    @Test func systemOtherResolvesEn() {
        #expect(Lang.resolve(.system, preferred: ["fr-FR"]) == .en)
        #expect(Lang.resolve(.system, preferred: []) == .en)
    }
    @Test func explicitWinsOverSystem() { #expect(Lang.resolve(.en, preferred: ["pt-BR"]) == .en) }
    @Test func unknownSettingIsSystem() {
        #expect(LanguageSetting.parse("klingon") == .system)
        #expect(LanguageSetting.parse(nil) == .system)
    }
    @Test func cliEnvWins() { #expect(Lang.forCLI(env: ["COLLIE_LANG": "en"], setting: "pt", preferred: ["pt-BR"]) == .en) }
    @Test func cliBadEnvFallsToSetting() { #expect(Lang.forCLI(env: ["COLLIE_LANG": "xx"], setting: "pt", preferred: ["en"]) == .pt) }
    @Test func trFollowsOverride() {
        L10n.$override.withValue(.en) { #expect(tr("Cercado", "Paddock") == "Paddock") }
        L10n.$override.withValue(.pt) { #expect(tr("Cercado", "Paddock") == "Cercado") }
    }
}
