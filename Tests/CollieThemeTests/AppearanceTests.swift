import AppKit
import Foundation
import Testing
import CollieTheme

@Test func themeAppearance() {
    #expect(ThemeChoice.dark.appearance?.name == .darkAqua)
    #expect(ThemeChoice.light.appearance?.name == .aqua)
    #expect(ThemeChoice.system.appearance == nil)
}
@Test func unknownValuesUseDefaults() {
    let d = UserDefaults(suiteName: "collie.test.\(UUID())")!
    d.set("sepia", forKey: AppearanceKeys.theme)
    d.set("Comic Sans", forKey: AppearanceKeys.terminalFamily); d.set(40.0, forKey: AppearanceKeys.terminalSize)
    let s = AppearanceSettings(defaults: d)
    #expect(s.theme == .dark)
    #expect(s.terminalFont == TerminalFontChoice(family: "DM Mono", size: 16))
}
@Test func emptyDefaults() {
    let s = AppearanceSettings(defaults: UserDefaults(suiteName: "collie.test.\(UUID())")!)
    #expect(s == AppearanceSettings(theme: .dark, terminalFont: .default))
}
@Test func normalizeRewritesInvalidValues() {
    let d = UserDefaults(suiteName: "collie.test.\(UUID())")!
    d.set("sepia", forKey: AppearanceKeys.theme)
    d.set("Comic Sans", forKey: AppearanceKeys.terminalFamily); d.set(13.6, forKey: AppearanceKeys.terminalSize)
    AppearanceSettings.normalize(d)
    #expect(d.string(forKey: AppearanceKeys.theme) == "dark")
    #expect(d.string(forKey: AppearanceKeys.terminalFamily) == "DM Mono" && d.double(forKey: AppearanceKeys.terminalSize) == 14)
}
@Test func customThemeIsReadAndKept() {
    let d = UserDefaults(suiteName: "collie.test.\(UUID())")!
    d.set("custom:tinta", forKey: AppearanceKeys.theme)
    #expect(AppearanceSettings(defaults: d).theme == .custom("tinta"))
    AppearanceSettings.normalize(d)
    #expect(d.string(forKey: AppearanceKeys.theme) == "custom:tinta")
    #expect(ThemeSelection.custom("tinta").rawValue == "custom:tinta")
}
@Test(arguments: ["custom:../x", "custom:", "custom:Tinta", "custom:a b", "customtinta"])
func invalidCustomIdReadsDark(_ raw: String) {
    let d = UserDefaults(suiteName: "collie.test.\(UUID())")!
    d.set(raw, forKey: AppearanceKeys.theme)
    #expect(AppearanceSettings(defaults: d).theme == .dark)
    AppearanceSettings.normalize(d)
    #expect(d.string(forKey: AppearanceKeys.theme) == "dark")
}
@Test func builtInSelectionsRoundTrip() {
    for s in [ThemeSelection.dark, .light, .system] { #expect(ThemeSelection(rawValue: s.rawValue) == s) }
    #expect(ThemeSelection.system.appearance == nil)
    #expect(ThemeSelection.light.appearance?.name == .aqua)
}
