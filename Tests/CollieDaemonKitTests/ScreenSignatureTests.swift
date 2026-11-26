import Testing
import Foundation
import CollieDevice
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// Device flows d1: `sig` names a screen, not what it shows right now.
struct ScreenSignatureTests {
    typealias N = ScreenSignature.Node

    /// A cart screen: title, two tabs (Cart selected), a total, a clock, a counter, and list rows.
    func cart(total: String = "R$ 12,90", time: String = "14:32", count: String = "3 itens",
              rows: [N] = [N(label: "Cerveja 350ml", role: "text", inList: true), N(label: "Água", role: "text", inList: true)],
              cartSelected: Bool = true) -> [N] {
        [N(label: "Carrinho", role: "title"),
         N(label: "Cart", role: "tab", selected: cartSelected), N(label: "Orders", role: "tab", selected: !cartSelected),
         N(label: "Total \(total)", role: "text"), N(label: time, role: "text"), N(label: count, role: "text"),
         N(label: "Finalizar", id: "checkout", role: "button")] + rows
    }

    @Test func numbersPricesAndTimesDoNotChangeIt() {
        let a = ScreenSignature.compute(cart())
        #expect(a.count == 12 && a.allSatisfy(\.isHexDigit), "\(a)")
        #expect(ScreenSignature.compute(cart(total: "US$ 99.00", time: "09:05", count: "17 itens")) == a)
    }

    @Test func differentScreensDiffer() {
        let a = ScreenSignature.compute(cart())
        var other = cart(); other[0].label = "Pedidos"
        #expect(ScreenSignature.compute(other) != a)                       // another title
        #expect(ScreenSignature.compute(cart(cartSelected: false)) != a)  // another tab selected
        var noCheckout = cart(); noCheckout[6].id = "pay"
        #expect(ScreenSignature.compute(noCheckout) != a)                  // another fixed id
    }

    @Test func listItemsSwappedOrReorderedKeepIt() {
        let a = ScreenSignature.compute(cart())
        #expect(ScreenSignature.compute(cart(rows: [N(label: "Vinho", role: "text", inList: true)])) == a)
        #expect(ScreenSignature.compute(cart(rows: [])) == a)
        // rows with an id: their id counts (digits dropped), not their label nor order
        let rows = [N(label: "Cerveja", id: "row_1", role: "button", inList: true), N(label: "Água", id: "row_2", role: "button", inList: true)]
        let b = ScreenSignature.compute(cart(rows: rows))
        #expect(ScreenSignature.compute(cart(rows: rows.reversed())) == b)
        #expect(ScreenSignature.compute(cart(rows: [N(label: "Suco", id: "row_9", role: "button", inList: true)])) == b)
    }

    @Test func nodeOrderDoesNotMatter() {
        #expect(ScreenSignature.compute(cart().reversed()) == ScreenSignature.compute(cart()))
    }

    /// The same Android dump with other bounds (light/dark theme, another density or offset) gives the same sig:
    /// the tree carries no colour and the signature reads no coordinates.
    @Test func lightAndDarkThemeKeepIt() throws {
        let xml = try String(contentsOf: fixtures.appendingPathComponent("offers-ui.xml"), encoding: .utf8)
        let dark = try Regex(#"bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#)
        let shifted = xml.replacing(dark) { m in
            let v = (1...4).map { Int(m.output[$0].substring ?? "") ?? 0 }
            return "bounds=\"[\(v[0] + 2),\(v[1] + 4)][\(v[2] + 2),\(v[3] + 4)]\""
        }
        #expect(shifted != xml)
        #expect(sig(Data(shifted.utf8)) == sig(Data(xml.utf8)))
    }

    @Test func fiveReadsOfAFixtureAgree() throws {
        let xml = try Data(contentsOf: fixtures.appendingPathComponent("offers-ui.xml"))
        let sigs = (1...5).map { _ in sig(xml) }
        #expect(Set(sigs).count == 1, "\(sigs)")
        let other = try Data(contentsOf: fixtures.appendingPathComponent("ui-dump.xml"))
        #expect(sig(other) != sigs[0])
    }

    @Test func normalizeDropsNumbersAndSymbols() {
        #expect(ScreenSignature.normalize("Total R$ 12,90 • Hoje 14:32") == "total hoje")
        #expect(ScreenSignature.normalize("Points") == "points")
    }

    private func sig(_ xml: Data) -> String { ScreenSignature.compute(ScreenModel.build(UITree.parse(xml).nodes)) }
}
