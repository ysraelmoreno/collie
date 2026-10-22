import AppKit
import Testing
import CollieTheme

@Test func missingFamilyFallsBackToSystem() {
    let f = CollieFont.ui(14, .semibold, family: "Família Que Não Existe")
    #expect(f.familyName == NSFont.systemFont(ofSize: 14).familyName)
    let m = CollieFont.mono(13, family: "Família Que Não Existe")
    #expect(m.isFixedPitch)
}

@Test func sizeIsKept() { #expect(CollieFont.mono(13).pointSize == 13) }

/// Only meaningful when the fonts are installed/registered (bundle or system); skipped otherwise.
@Test func bundledFamilyUsedWhenAvailable() {
    guard NSFontManager.shared.availableMembers(ofFontFamily: CollieFont.uiFamily) != nil else { return }
    #expect(CollieFont.ui(14, .semibold).familyName == CollieFont.uiFamily)
}
