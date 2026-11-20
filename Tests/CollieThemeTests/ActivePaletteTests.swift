import AppKit
import Testing
import CollieTheme

/// `ActivePalette` is global: the suite runs one test at a time and only ever changes `accent`, so the palette
/// tests that run beside it (which read other roles) stay valid.
@Suite(.serialized) struct ActivePaletteTests {
    private let custom = Palette.dark.replacing(["accent": RGB(hex: 0x010203)])

    private func accent(_ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var out = NSColor.clear
        appearance.performAsCurrentDrawingAppearance { out = CollieColor.accent.usingColorSpace(.sRGB) ?? .clear }
        return out
    }

    @Test func setChangesTheSideItWasGivenOnly() throws {
        defer { ActivePalette.reset() }
        ActivePalette.set(dark: custom, light: Palette.light)
        let dark = try accent(.darkAqua), light = try accent(.aqua)
        #expect(abs(dark.redComponent - 1.0 / 255) < 0.01)
        #expect(abs(dark.greenComponent - 2.0 / 255) < 0.01)
        #expect(abs(dark.blueComponent - 3.0 / 255) < 0.01)
        #expect(abs(light.redComponent - 0x24 / 255.0) < 0.01)   // light stays the built-in 0x2448C9
        #expect(ActivePalette.dark == custom)
        #expect(ActivePalette.light == Palette.light)
    }

    @Test func resetGoesBackToTheBuiltIns() throws {
        ActivePalette.set(dark: custom, light: custom)
        ActivePalette.reset()
        #expect(ActivePalette.dark == Palette.dark && ActivePalette.light == Palette.light)
        #expect(abs(try accent(.darkAqua).redComponent - 0x6E / 255.0) < 0.01)   // built-in 0x6EE7B7
    }

    @Test func concurrentReadsSeeWholePalettes() async {
        defer { ActivePalette.reset() }
        let custom = self.custom
        let seen = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 2 == 0 { ActivePalette.set(dark: custom, light: Palette.light); return true }
                    let p = ActivePalette.dark
                    return p == custom || p == Palette.dark   // never a mix of the two
                }
            }
            var all: [Bool] = []
            for await ok in group { all.append(ok) }
            return all
        }
        #expect(seen.count == 100 && !seen.contains(false))
    }
}
