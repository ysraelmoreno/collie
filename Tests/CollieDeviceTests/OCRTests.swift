import Testing
import Foundation
import CoreGraphics
@testable import CollieDevice

/// OCR fallback, pure half (spec 2026-11-22-device-ocr-fallback-design.md, O2 and O3), on trees shaped like the
/// `com.collie.fixture` screens (720×1280): the poor ones keep 1 labelled node (the action bar title), the normal one 5.
struct OCRTests {
    private static let phone = CGSize(width: 720, height: 1280)

    private func node(_ ref: String, cls: String = "android.widget.TextView", text: String = "", id: String = "",
                      _ r: CGRect, clickable: Bool = false, depth: Int = 1) -> UINode {
        UINode(ref: ref, cls: cls, text: text, desc: "", id: id, bounds: r, clickable: clickable, depth: depth)
    }

    /// Action bar (Toolbar + title) over a canvas with only an id: what the helper reads on `--es screen canvas`.
    private func poorFixture() -> [UINode] {
        UITree.linkParents([
            node("e1", cls: "android.widget.Toolbar", id: "action_bar", CGRect(x: 0, y: 48, width: 720, height: 112), depth: 1),
            node("e2", text: "Fixture Collie", CGRect(x: 32, y: 80, width: 300, height: 48), depth: 2),
            node("e3", cls: "android.view.View", id: "canvas", CGRect(x: 0, y: 160, width: 720, height: 1120), depth: 1),
        ])
    }

    /// `--es screen normal`: the title and 4 labelled rows (one a button).
    private func normalFixture() -> [UINode] {
        UITree.linkParents([
            node("e1", cls: "android.widget.Toolbar", id: "action_bar", CGRect(x: 0, y: 48, width: 720, height: 112), depth: 1),
            node("e2", text: "Fixture Collie", CGRect(x: 32, y: 80, width: 300, height: 48), depth: 2),
            node("e3", text: "Bem-vindo", CGRect(x: 0, y: 200, width: 720, height: 100), depth: 1),
            node("e4", text: "Saldo: R$ 120,00", CGRect(x: 0, y: 320, width: 720, height: 100), depth: 1),
            node("e5", text: "Último pedido", CGRect(x: 0, y: 440, width: 720, height: 100), depth: 1),
            node("e6", cls: "android.widget.Button", text: "Continuar", CGRect(x: 0, y: 560, width: 720, height: 100), clickable: true, depth: 1),
        ])
    }

    /// `n` labelled rows 1000 wide on a 1000×1000 screen, the first `heights` tall, all below the bars.
    private func rows(_ heights: [CGFloat]) -> [UINode] {
        var y: CGFloat = 200
        return heights.enumerated().map { i, hgt in
            defer { y += hgt + 10 }
            return node("e\(i + 1)", text: "linha \(i + 1)", CGRect(x: 0, y: y, width: 1000, height: hgt), depth: 0)
        }
    }
    private let square = CGSize(width: 1000, height: 1000)

    // MARK: O2 trigger

    @Test func fixtureTreesSplitPoorFromNormal() {
        #expect(poorFixture().filter(OCR.labelled).count == 1)
        #expect(OCR.trigger(poorFixture(), size: Self.phone) == .fewLabels)
        #expect(normalFixture().filter(OCR.labelled).count == 5)
        #expect(OCR.trigger(normalFixture(), size: Self.phone) == nil)
    }

    @Test func fewLabelsEdgeIsThreeContentNodes() {
        #expect(OCR.trigger(rows([60, 60, 60]), size: square) == nil)
        #expect(OCR.trigger(rows([90, 90]), size: square) == .fewLabels)
        // a label in the status/action bar band does not count as content
        let bar = node("b", text: "12:30", CGRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        #expect(OCR.trigger([bar] + rows([90, 90]), size: square) == .fewLabels)
    }

    @Test func lowCoverageEdgeIsFifteenPercent() {
        #expect(OCR.trigger(rows([50, 50, 50]), size: square) == nil)            // 150000 / 1e6 = 15%: not below
        #expect(OCR.trigger(rows([50, 50, 49]), size: square) == .lowCoverage)   // 14.9%
        // overlaps count once: a copy of a row adds nothing
        var r = rows([50, 50, 49]); r.append(node("x", text: "copia", r[0].bounds, depth: 0))
        #expect(OCR.trigger(r, size: square) == .lowCoverage)
        // clickable without label counts toward coverage
        r.append(node("c", cls: "android.view.View", CGRect(x: 0, y: 800, width: 1000, height: 10), clickable: true, depth: 0))
        #expect(OCR.trigger(r, size: square) == nil)
    }

    @Test func opaqueViewOverHalfTheScreen() {
        let good = rows([60, 60, 60])
        let surface = { (h: CGFloat) in self.node("s", cls: "android.view.SurfaceView", id: "game", CGRect(x: 0, y: 400, width: 1000, height: h), depth: 0) }
        #expect(OCR.trigger(good + [surface(510)], size: square) == .opaqueView)
        #expect(OCR.trigger(good + [surface(500)], size: square) == nil)        // exactly 50%: not over
        let flutter = node("f", cls: "io.flutter.embedding.android.FlutterView", id: "f", CGRect(x: 0, y: 0, width: 1000, height: 1000), depth: 0)
        #expect(OCR.trigger(good + [flutter], size: square) == .opaqueView)
        // a WebView is opaque only without labelled children
        let web = node("w", cls: "android.webkit.WebView", id: "web", CGRect(x: 0, y: 0, width: 1000, height: 1000), depth: 0)
        #expect(OCR.trigger(good + [web], size: square) == .opaqueView)
        let child = node("wc", text: "Artigo", CGRect(x: 0, y: 900, width: 200, height: 40), depth: 1)
        #expect(OCR.trigger(good + [web, child], size: square) == nil)
    }

    // MARK: O3 fusion

    private func item(_ t: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 100, h: CGFloat = 30, conf: Double = 0.9) -> OCRItem {
        OCRItem(text: t, confidence: conf, box: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func itemsBecomeTextNodesWithoutClick() {
        let n = OCR.nodes([item("Jogar", 100, 600)], tree: poorFixture())
        #expect(n.count == 1)
        #expect(n[0].ocr && !n[0].clickable && n[0].ref == "o1" && n[0].text == "Jogar")
        #expect(n[0].bounds == CGRect(x: 100, y: 600, width: 100, height: 30))
    }

    @Test func minimumConfidenceAndLength() {
        let n = OCR.nodes([item("baixa", 0, 300, conf: 0.49), item("limite", 0, 400, conf: 0.5), item("x", 0, 500), item(" ok ", 0, 600)],
                          tree: poorFixture())
        #expect(n.map(\.text) == ["limite", "ok"])
    }

    @Test func treeWinsWhenCentreIsInALabelledNode() {
        // centre inside the title "Fixture Collie" (32...332, 80...128): dropped, whatever the text
        let n = OCR.nodes([item("Fixture Collie", 40, 90), item("Outro", 200, 95), item("Livre", 100, 700)], tree: poorFixture())
        #expect(n.map(\.text) == ["Livre"])
        // the canvas has only an id: not a label, so text over it stays
        #expect(OCR.nodes([item("Sobre a tela", 100, 300)], tree: poorFixture()).count == 1)
    }

    @Test func duplicateWithin24Pixels() {
        // same text 20 px below the title's box (ends at y 128): duplicate; 30 px below: kept
        #expect(OCR.nodes([item("fixture collie", 32, 148)], tree: poorFixture()).isEmpty)
        #expect(OCR.nodes([item("Fixture Collie", 32, 158)], tree: poorFixture()).count == 1)
        // between two items: the second copy 10 px to the right goes; a different text there stays
        let n = OCR.nodes([item("Pontos", 0, 600), item("Pontos", 110, 600), item("Vidas", 220, 600)], tree: poorFixture())
        #expect(n.map(\.text) == ["Pontos", "Vidas"])
    }

    @Test func readingOrderByRowThenLeftToRight() {
        // row 1 at y≈400 (slightly ragged), row 2 at y≈500, given shuffled
        let named = [item("Delta", 300, 500), item("Beta", 300, 405), item("Gama", 10, 498), item("Alfa", 10, 400)]
        #expect(OCR.nodes(named, tree: poorFixture()).map(\.text) == ["Alfa", "Beta", "Gama", "Delta"])
        #expect(OCR.nodes(named, tree: poorFixture()).map(\.ref) == ["o1", "o2", "o3", "o4"])
    }

    // MARK: ScreenModel

    @Test func screenShowsOcrItemsInContentWithMark() {
        let ocr = OCR.nodes([item("12:30", 10, 5, h: 30), item("Pontos: 40", 100, 600), item("Jogar", 100, 800)], tree: poorFixture())
        let s = ScreenModel.build(poorFixture() + ocr, size: Self.phone)
        #expect(s.title == "Fixture Collie")
        #expect(ScreenModel.text(s) == """
            Tela: Fixture Collie
            Conteúdo: "12:30" (ocr), "Pontos: 40" (ocr), "Jogar" (ocr)
            """)
        guard case .array(let lists)? = ScreenModel.json(s)["lists"], case .object(let first)? = lists.first else {
            Issue.record("no lists"); return
        }
        #expect(first["source"] == .string("ocr"))
        #expect(first["role"] == .string("text"))
        // a good tree's screen is unchanged: no item carries the mark
        #expect(!ScreenModel.text(ScreenModel.build(normalFixture(), size: Self.phone)).contains("(ocr)"))
    }

    // MARK: provider

    private struct FakeOCR: OCRProvider {
        let items: [OCRItem]
        func recognize(png: Data, level: OCRLevel, languages: [String]) async throws -> [OCRItem] { items }
    }

    @Test func fakeProviderFeedsTheFusion() async throws {
        let p: any OCRProvider = FakeOCR(items: [item("Iniciar", 200, 700), item("?", 0, 0, conf: 0.2)])
        let tree = poorFixture()
        guard OCR.trigger(tree, size: Self.phone) != nil else { Issue.record("poor tree should trigger"); return }
        let read = try await p.recognize(png: Data(), level: .accurate, languages: ["pt-BR", "en-US"])
        #expect(OCR.nodes(read, tree: tree).map(\.text) == ["Iniciar"])
    }
}
