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
    d.set("sepia", forKey: AppearanceKeys.theme); d.set(7, forKey: AppearanceKeys.structure)
    d.set("Comic Sans", forKey: AppearanceKeys.terminalFamily); d.set(40.0, forKey: AppearanceKeys.terminalSize)
    let s = AppearanceSettings(defaults: d)
    #expect(s.theme == .dark && s.structure == .compact)
    #expect(s.terminalFont == TerminalFontChoice(family: "DM Mono", size: 16))
}
@Test func emptyDefaults() {
    let s = AppearanceSettings(defaults: UserDefaults(suiteName: "collie.test.\(UUID())")!)
    #expect(s == AppearanceSettings(theme: .dark, structure: .compact, terminalFont: .default))
}
@Test func chipsOverflow() {
    let all = Array(0..<15)
    let (shown, over) = chipSplit(all, current: 12, max: 4)
    #expect(shown == [0, 1, 2, 12] && over.count == 11 && !over.contains(12))
    #expect(chipSplit([0, 1], current: nil, max: 4) == ([0, 1], []))
}
@Test func normalizeRewritesInvalidValues() {
    let d = UserDefaults(suiteName: "collie.test.\(UUID())")!
    d.set("sepia", forKey: AppearanceKeys.theme); d.set("grid", forKey: AppearanceKeys.structure)
    d.set("Comic Sans", forKey: AppearanceKeys.terminalFamily); d.set(13.6, forKey: AppearanceKeys.terminalSize)
    AppearanceSettings.normalize(d)
    #expect(d.string(forKey: AppearanceKeys.theme) == "dark" && d.string(forKey: AppearanceKeys.structure) == "compact")
    #expect(d.string(forKey: AppearanceKeys.terminalFamily) == "DM Mono" && d.double(forKey: AppearanceKeys.terminalSize) == 14)
}
