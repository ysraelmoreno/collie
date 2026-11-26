import Testing
import Foundation
import CollieDevice
@testable import CollieDaemonKit

/// Device flows d3: unnamed clickable controls and small touch targets, as one summary line.
struct ScreenAccessibilityTests {
    func node(text: String = "", desc: String = "", clickable: Bool = true, side: CGFloat = 200, parent: Int? = nil) -> UINode {
        UINode(ref: "e", cls: "android.widget.Button", text: text, desc: desc, id: "btn", bounds: CGRect(x: 0, y: 0, width: side, height: side),
               clickable: clickable, depth: 1, parent: parent)
    }
    let mdpi = ScreenAccessibility.Platform.android(density: 1)

    @Test func clickableWithoutLabelCountsAndLabelledDoesNot() {
        #expect(ScreenAccessibility.summary([node()], platform: mdpi) == "ACESSIBILIDADE: 1 sem nome, 0 alvos pequenos")
        #expect(ScreenAccessibility.summary([node(text: "Comprar")], platform: mdpi) == nil)
        #expect(ScreenAccessibility.summary([node(desc: "Fechar")], platform: mdpi) == nil)
        #expect(ScreenAccessibility.summary([node(text: "  ")], platform: mdpi) != nil)   // blank is no name
    }

    @Test func aChildLabelNamesItsClickableParent() {
        #expect(ScreenAccessibility.summary([node(), node(text: "Entrar", clickable: false, parent: 0)], platform: mdpi) == nil)
    }

    @Test func androidTargetsUnder48dpAreSmall() {
        let xhdpi = ScreenAccessibility.Platform.android(density: 2)
        #expect(ScreenAccessibility.summary([node(text: "a", side: 80)], platform: xhdpi) == "ACESSIBILIDADE: 0 sem nome, 1 alvos pequenos")   // 40 dp
        #expect(ScreenAccessibility.summary([node(text: "a", side: 96)], platform: xhdpi) == nil)   // 48 dp
        #expect(ScreenAccessibility.summary([node(text: "a", side: 80)], platform: .android(density: nil)) == nil)   // unknown density
    }

    @Test func iosTargetsUnder44ptAreSmall() {
        #expect(ScreenAccessibility.summary([node(text: "a", side: 40)], platform: .ios) == "ACESSIBILIDADE: 0 sem nome, 1 alvos pequenos")
        #expect(ScreenAccessibility.summary([node(text: "a", side: 44)], platform: .ios) == nil)
    }

    @Test func nonClickableUnnamedDoesNotCount() {
        #expect(ScreenAccessibility.summary([node(clickable: false, side: 10)], platform: .ios) == nil)
    }

    @Test func nothingFoundIsNil() {
        #expect(ScreenAccessibility.summary([], platform: .ios) == nil)
        #expect(ScreenAccessibility.summary([node(text: "OK", side: 60)], platform: .ios) == nil)
    }

    @Test func bothFindingsAreCounted() {
        let s = ScreenAccessibility.summary([node(side: 30), node(desc: "x", side: 20), node(text: "ok")], platform: .ios)
        #expect(s == "ACESSIBILIDADE: 1 sem nome, 2 alvos pequenos")
    }

    @Test func wmDensityOverrideWins() {
        #expect(ScreenAccessibility.density(wm: "Physical density: 320\n") == 2)
        #expect(ScreenAccessibility.density(wm: "Physical density: 320\nOverride density: 480\n") == 3)
        #expect(ScreenAccessibility.density(wm: "") == nil)
    }
}
