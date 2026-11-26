import AppKit
import Testing
import CollieTheme

@Test(.themePT) func tokensMatchSpec() {
    #expect(Palette.dark.background == RGB(hex: 0x0E1326))
    #expect(Palette.dark.accent == RGB(hex: 0x6EE7B7))
    #expect(Palette.light.accent == RGB(hex: 0x2448C9))
    #expect(Palette.light.attention == RGB(hex: 0xA14A06))
}
@Test(arguments: [Palette.dark, Palette.light], .themePT) func textTokensPassAA(_ p: Palette) {
    for fg in [p.text, p.textSecondary, p.muted, p.accent, p.attention, p.secondary, p.danger] {
        for bg in [p.background, p.surface, p.sidebar, p.sunken] { #expect(contrastRatio(fg, bg) >= 4.5) }
    }
    #expect(contrastRatio(p.onAccent, p.accent) >= 4.5)
}
@Test(.themePT) func dynamicColorsFollowAppearance() {
    func rgb(_ name: NSAppearance.Name) -> NSColor {
        var c = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { c = CollieColor.background.usingColorSpace(.sRGB)! }
        return c
    }
    #expect(abs(rgb(.darkAqua).redComponent - 0x0E / 255) < 0.01)
    #expect(abs(rgb(.aqua).redComponent - 0xF3 / 255) < 0.01)
}
@Test(.themePT) func contrastKnownPair() { #expect(abs(contrastRatio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)) - 21) < 0.01) }
@Test(.themePT) func rolesCoverEveryProperty() {
    let keys = Palette.roles.map(\.key)
    #expect(keys.count == 18)
    #expect(Set(keys).count == 18)
    let props = Set(Mirror(reflecting: Palette.dark).children.compactMap(\.label))
    #expect(Set(keys) == props)
    for r in Palette.roles { #expect(Palette.dark[role: r.key] == Palette.dark[keyPath: r.keyPath]) }
    #expect(Palette.dark[role: "nope"] == nil)
}
@Test(.themePT) func replacingChangesOnlyWhatIsAsked() {
    let p = Palette.dark.replacing(["accent": RGB(hex: 0x010203), "nope": RGB(hex: 0x040506)])
    #expect(p.accent == RGB(hex: 0x010203))
    for r in Palette.roles where r.key != "accent" { #expect(p[role: r.key] == Palette.dark[role: r.key]) }
}
