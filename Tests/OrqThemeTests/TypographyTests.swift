import AppKit
import Testing
import OrqTheme

@Test func missingFamilyFallsBackToSystem() {
    let f = OrqFont.ui(14, .semibold, family: "Família Que Não Existe")
    #expect(f.familyName == NSFont.systemFont(ofSize: 14).familyName)
    let m = OrqFont.mono(13, family: "Família Que Não Existe")
    #expect(m.isFixedPitch)
}

@Test func sizeIsKept() { #expect(OrqFont.mono(13).pointSize == 13) }

/// Only meaningful when the fonts are installed/registered (bundle or system); skipped otherwise.
@Test func bundledFamilyUsedWhenAvailable() {
    guard NSFontManager.shared.availableMembers(ofFontFamily: OrqFont.uiFamily) != nil else { return }
    #expect(OrqFont.ui(14, .semibold).familyName == OrqFont.uiFamily)
}
