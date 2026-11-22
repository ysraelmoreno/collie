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

    @Test func lowCoverageEdgeIsFifteenPercentOfTheContentArea() {
        // content area: 1000 × 880 below the bars (120); 15% = 132000, i.e. three 44-tall rows
        #expect(abs(OCR.coverage(rows([44, 44, 44]), screen: CGRect(origin: .zero, size: square)) - 0.15) < 1e-9)
        #expect(OCR.trigger(rows([44, 44, 45]), size: square) == nil)
        #expect(OCR.trigger(rows([44, 44, 43]), size: square) == .lowCoverage)
        // overlaps count once: a copy of a row adds nothing
        var r = rows([44, 44, 43]); r.append(node("x", text: "copia", r[0].bounds, depth: 0))
        #expect(OCR.trigger(r, size: square) == .lowCoverage)
        // the bars band is not content: a labelled 1000 × 120 header adds nothing
        #expect(OCR.trigger(r + [node("h", text: "Cabeçalho", CGRect(x: 0, y: 0, width: 1000, height: 120), depth: 0)], size: square) == .lowCoverage)
        // clickable without label counts toward coverage
        r.append(node("c", cls: "android.view.View", CGRect(x: 0, y: 800, width: 1000, height: 10), clickable: true, depth: 0))
        #expect(OCR.trigger(r, size: square) == nil)
    }

    @Test func opaqueViewOverHalfTheScreen() {
        let good = rows([60, 60, 60]), screen = CGRect(origin: .zero, size: square)
        let surface = { (cls: String, h: CGFloat) in self.node("s", cls: cls, id: "game", CGRect(x: 0, y: 400, width: 1000, height: h), depth: 0) }
        for cls in ["android.view.SurfaceView", "android.opengl.GLSurfaceView", "android.view.TextureView"] {
            #expect(OCR.trigger(good + [surface(cls, 510)], size: square) == .opaqueView, "\(cls)")
            #expect(OCR.trigger(good + [surface(cls, 500)], size: square) == nil, "\(cls)")   // exactly 50%: not over
        }
        #expect(OCR.opaqueView([surface("android.view.SurfaceView", 510)], screen: screen)?.ref == "s")   // rule 3 alone
        // not an opaque class: a big unlabelled View is rule 2's business, not rule 3's
        #expect(OCR.opaqueView([surface("android.view.View", 1000)], screen: screen) == nil)
        let flutter = node("f", cls: "io.flutter.embedding.android.FlutterView", id: "f", CGRect(x: 0, y: 0, width: 1000, height: 1000), depth: 0)
        #expect(OCR.trigger(good + [flutter], size: square) == .opaqueView)
    }

    @Test func opaqueViewIsReadableWhenItsChildrenCoverTheText() {
        let web = node("w", cls: "android.webkit.WebView", id: "web", CGRect(x: 0, y: 0, width: 1000, height: 1000), depth: 0)
        let good = rows([60, 60, 60])
        #expect(OCR.trigger(good + [web], size: square) == .opaqueView)
        // labelled descendants covering 15% of the WebView: readable; 14%: still opaque. A sibling after it is not a child.
        let child = { (h: CGFloat) in self.node("wc", text: "Artigo", CGRect(x: 0, y: 700, width: 1000, height: h), depth: 1) }
        #expect(OCR.trigger(good + [web, child(150)], size: square) == nil)
        #expect(OCR.trigger(good + [web, child(140)], size: square) == .opaqueView)
        let sibling = node("sb", text: "Fora", CGRect(x: 0, y: 700, width: 1000, height: 300), depth: 0)
        #expect(OCR.trigger(good + [web, sibling], size: square) == .opaqueView)
    }

    @Test func iOSWebViewWithSixPageNodesFiresOpaque() {
        // corpus `webcanvas`: the WKWebView exposes 6 page nodes, the drawn text lives in a <canvas>
        let tree = UITree.linkParents([
            node("e1", cls: "Application", text: "Fixture", CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0),
            node("e2", cls: "WebView", text: "Gráfico", CGRect(x: 0, y: 0, width: 390, height: 844), depth: 1),
            node("e3", cls: "Heading", text: "Gráfico de Vendas", CGRect(x: 20, y: 120, width: 240, height: 34), depth: 2),
            node("e4", cls: "StaticText", text: "Página de relatório", CGRect(x: 20, y: 160, width: 180, height: 20), depth: 2),
            node("e5", cls: "Link", text: "Ajuda", CGRect(x: 20, y: 190, width: 60, height: 20), clickable: true, depth: 2),
            node("e6", cls: "Link", text: "Contato", CGRect(x: 90, y: 190, width: 70, height: 20), clickable: true, depth: 2),
            node("e7", cls: "Image", text: "canvas", CGRect(x: 20, y: 220, width: 40, height: 40), depth: 2),
            node("e8", cls: "StaticText", text: "Fim", CGRect(x: 20, y: 800, width: 40, height: 16), depth: 2),
        ])
        #expect(tree.filter { $0.depth == 2 }.count == 6)
        #expect(OCR.trigger(tree) == .opaqueView)
    }

    @Test func singleNodeMetalSceneSpriteViewIsOpaque() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        for cls in ["MTKView", "SCNView", "SKView"] {
            let v = node("v", cls: cls, id: "scene", screen, depth: 0)
            #expect(OCR.opaqueView([v], screen: screen)?.ref == "v", "\(cls)")
            // with any other node it is not (SpriteKit exposes its HUD: corpus `game`, 5 nodes, full recall)
            #expect(OCR.opaqueView([v, node("t", text: "Pontos", CGRect(x: 20, y: 100, width: 80, height: 20), depth: 1)], screen: screen) == nil)
            // rule order: a single node already has fewer than 3 labels
            #expect(OCR.trigger([v]) == .fewLabels)
        }
    }

    /// AXe-shaped good trees from the iOS corpus (390 × 844 points, labelled `Application` root): `normal` 6 nodes,
    /// `form` 13, `list` 28.
    private func iosNormal() -> [UINode] {
        UITree.linkParents([
            node("e1", cls: "Application", text: "Fixture", CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0),
            node("e2", cls: "StaticText", text: "Painel de Vendas", CGRect(x: 20, y: 70, width: 240, height: 34), depth: 1),
            node("e3", cls: "StaticText", text: "Total do mês: R$ 1.234,56 em 42 pedidos", CGRect(x: 20, y: 118, width: 330, height: 20), depth: 1),
            node("e4", cls: "Button", text: "Confirmar pedido", CGRect(x: 20, y: 152, width: 170, height: 35), clickable: true, depth: 1),
            node("e5", cls: "StaticText", text: "Confirmar pedido", CGRect(x: 34, y: 160, width: 142, height: 20), depth: 2),
            node("e6", cls: "StaticText", text: "Atualizado às 14:35. Versão 2.0.1", CGRect(x: 20, y: 201, width: 190, height: 13), depth: 1),
        ])
    }
    private func iosForm() -> [UINode] {
        var y: CGFloat = 70
        func next(_ h: CGFloat) -> CGFloat { defer { y += h + 14 }; return y }
        return UITree.linkParents([
            node("e1", cls: "Application", text: "Fixture", CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0),
            node("e2", cls: "StaticText", text: "Cadastro", CGRect(x: 20, y: next(34), width: 120, height: 34), depth: 1),
            node("e3", cls: "TextField", text: "Nome completo", CGRect(x: 20, y: next(34), width: 350, height: 34), clickable: true, depth: 1),
            node("e4", cls: "TextField", text: "E-mail", CGRect(x: 20, y: next(34), width: 350, height: 34), clickable: true, depth: 1),
            node("e5", cls: "StaticText", text: "Receber novidades", CGRect(x: 20, y: y + 6, width: 160, height: 20), depth: 1),
            node("e6", cls: "Switch", text: "Receber novidades", CGRect(x: 192, y: next(31), width: 51, height: 31), clickable: true, depth: 1),
            node("e7", cls: "Group", id: "plano", CGRect(x: 20, y: y, width: 350, height: 32), depth: 1),
            node("e8", cls: "Button", text: "Mensal", CGRect(x: 20, y: y, width: 116, height: 32), clickable: true, depth: 2),
            node("e9", cls: "Button", text: "Anual", CGRect(x: 137, y: y, width: 116, height: 32), clickable: true, depth: 2),
            node("e10", cls: "Button", text: "Vitalício", CGRect(x: 254, y: next(32), width: 116, height: 32), clickable: true, depth: 2),
            node("e11", cls: "Button", text: "Enviar cadastro", CGRect(x: 20, y: next(35), width: 350, height: 35), clickable: true, depth: 1),
            node("e12", cls: "Button", text: "Ver termos", CGRect(x: 20, y: y, width: 350, height: 35), clickable: true, depth: 1),
            node("e13", cls: "StaticText", text: "Ver termos", CGRect(x: 150, y: y + 8, width: 90, height: 20), depth: 2),
        ])
    }
    private func iosList() -> [UINode] {
        var n = [
            node("e1", cls: "Application", text: "Fixture", CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0),
            node("e2", cls: "Heading", text: "Catálogo", CGRect(x: 16, y: 100, width: 140, height: 41), depth: 1),
            node("e3", cls: "SearchField", text: "Buscar", CGRect(x: 16, y: 150, width: 358, height: 36), clickable: true, depth: 1),
            node("e4", cls: "Table", CGRect(x: 0, y: 196, width: 390, height: 648), depth: 1),
        ]
        for i in 1...11 {
            let r = CGRect(x: 0, y: 196 + CGFloat(i - 1) * 44, width: 390, height: 44), t = String(format: "Produto %03d", i)
            n.append(node("c\(i)", cls: "Cell", text: t, r, clickable: true, depth: 2))
            if i <= 10 { n.append(node("t\(i)", cls: "StaticText", text: t, r.insetBy(dx: 20, dy: 12), depth: 3)) }
        }
        n.append(node("tb", cls: "TabBar", text: "Barra de abas", CGRect(x: 20, y: 760, width: 350, height: 62), depth: 1))
        n.append(node("tb1", cls: "Button", text: "Produtos", CGRect(x: 30, y: 766, width: 160, height: 50), clickable: true, depth: 2))
        n.append(node("tb2", cls: "Button", text: "Favoritos", CGRect(x: 200, y: 766, width: 160, height: 50), clickable: true, depth: 2))
        return UITree.linkParents(n)
    }

    @Test func goodIOSCorpusTreesDoNotFire() {
        #expect(iosNormal().count == 6 && iosForm().count == 13 && iosList().count == 28)
        for t in [iosNormal(), iosForm(), iosList()] { #expect(OCR.trigger(t) == nil, "\(t.count) nós") }
    }

    /// The BEES product list (Android, 720 × 1600): toolbar, tabs, a RecyclerView of clickable cards (name, price, Add).
    @Test func beesAndroidTreeDoesNotFire() {
        var n = [
            node("r", cls: "android.widget.FrameLayout", CGRect(x: 0, y: 0, width: 720, height: 1600), depth: 0),
            node("tb", cls: "androidx.appcompat.widget.Toolbar", id: "toolbar", CGRect(x: 0, y: 48, width: 720, height: 136), depth: 1),
            UINode(ref: "up", cls: "android.widget.ImageButton", text: "", desc: "Navigate up", id: "", bounds: CGRect(x: 0, y: 64, width: 112, height: 112), clickable: true, depth: 2),
            node("ti", text: "Offers", CGRect(x: 140, y: 96, width: 200, height: 48), depth: 2),
            node("fi", cls: "android.widget.Button", text: "Filter", CGRect(x: 560, y: 80, width: 140, height: 80), clickable: true, depth: 2),
            node("t1", cls: "android.widget.TextView", text: "Points", CGRect(x: 0, y: 184, width: 360, height: 96), clickable: true, depth: 1),
            node("t2", cls: "android.widget.TextView", text: "Combos", CGRect(x: 360, y: 184, width: 360, height: 96), clickable: true, depth: 1),
            node("rv", cls: "androidx.recyclerview.widget.RecyclerView", id: "list", CGRect(x: 0, y: 280, width: 720, height: 1320), depth: 1),
        ]
        for i in 0..<15 {
            let y = 280 + CGFloat(i) * 168
            n.append(node("k\(i)", cls: "android.view.ViewGroup", CGRect(x: 0, y: y, width: 720, height: 160), clickable: true, depth: 2))
            n.append(node("n\(i)", text: "Cerveja \(i + 1) 350ml", CGRect(x: 24, y: y + 24, width: 460, height: 40), depth: 3))
            n.append(node("p\(i)", text: "R$ \(i + 3),99", CGRect(x: 24, y: y + 72, width: 200, height: 36), depth: 3))
            n.append(node("a\(i)", cls: "android.widget.Button", text: "Add", CGRect(x: 520, y: y + 44, width: 176, height: 72), clickable: true, depth: 3))
        }
        let tree = UITree.linkParents(n)
        #expect(tree.count >= 50)
        #expect(OCR.trigger(tree, size: CGSize(width: 720, height: 1600)) == nil)
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
