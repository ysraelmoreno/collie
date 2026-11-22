import Testing
import Foundation
import CoreGraphics
@testable import CollieDevice

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// `device screen` grouping on the BEES Offers screen (2026-11-21): toolbar with back and Filter, tabs Points*/Combos,
/// an unlabelled configuration_fab top right, an empty list with an error and a retry button.
struct ScreenModelTests {
    private func offers() throws -> [UINode] {
        UITree.parse(try Data(contentsOf: fixtures.appendingPathComponent("offers-ui.xml"))).nodes
    }

    @Test func offersScreenGroupsTitleTabsActionsContentAndFloating() throws {
        let s = ScreenModel.build(try offers())
        #expect(ScreenModel.text(s) == """
            Tela: Offers   [voltar]
            Abas: [Points*] [Combos]
            Ações: [Filter]
            Conteúdo (rolável): "Something went wrong", [Try again]
            Flutuante: [configuration fab] id=configuration_fab, topo direito
            """)
        #expect(s.tabs.map(\.state) == [["selected"], []])
        #expect(s.floating.first?.position == "topo direito")
    }

    @Test func parserKeepsParentsAndStates() throws {
        let nodes = try offers()
        let points = try #require(nodes.firstIndex { $0.text == "Points" })
        let tab = try #require(nodes[points].parent)
        #expect(nodes[tab].selected && nodes[tab].clickable)
        #expect(nodes[nodes[tab].parent!].id == "tab_layout")
        #expect(nodes.contains { $0.scrollable && $0.cls.hasSuffix("RecyclerView") })   // kept without id or label
        #expect(nodes.allSatisfy { n in n.parent.map { nodes[$0].depth < n.depth } ?? true })
    }

    @Test func iosTreeGetsParentsToo() throws {
        let nodes = AXeTree.parse(try Data(contentsOf: fixtures.appendingPathComponent("ios/describe-ui.json"))).nodes
        #expect(!nodes.isEmpty && nodes.dropFirst().allSatisfy { $0.parent != nil })
        #expect(nodes.indices.allSatisfy { i in nodes[i].parent.map { $0 < i && nodes[$0].depth < nodes[i].depth } ?? true })
    }

    @Test func changedComparesTitleSelectedTabAndItemCount() throws {
        let offers = ScreenModel.build(try offers())
        #expect(ScreenModel.changes(from: nil, to: offers).isEmpty)
        var home = offers
        home.title = "Home"; home.content = []
        home.tabs[0].state = []; home.tabs[1].state = ["selected"]
        #expect(ScreenModel.changes(from: home, to: offers) == ["título Home → Offers", "aba Combos → Points", "itens 0 → 2"])
        var s = offers; s.changed = ScreenModel.changes(from: home, to: offers)
        #expect(ScreenModel.text(s).hasSuffix("\nMudou: título Home → Offers; aba Combos → Points; itens 0 → 2"))
    }

    @Test func contentIsCutAtCapWithACountOfTheRest() {
        let nodes = (0..<15).map { i in
            UINode(ref: "e\(i + 1)", cls: "android.widget.TextView", text: "Item \(i)", desc: "", id: "",
                   bounds: CGRect(x: 0, y: 400 + i * 80, width: 720, height: 60), clickable: false, depth: 1)
        }
        let s = ScreenModel.build(nodes, size: CGSize(width: 720, height: 1600), cap: 12)
        #expect(s.content.count == 12 && s.more == 3)
        #expect(ScreenModel.text(s).contains("\"Item 11\", +3 itens: use device ui"))
    }

    @Test func jsonCarriesRefsRolesAndStates() throws {
        let o = ScreenModel.json(ScreenModel.build(try offers()))
        guard case .array(let tabs)? = o["tabs"], case .object(let points)? = tabs.first else { Issue.record("\(o)"); return }
        #expect(points["label"] == .string("Points") && points["role"] == .string("tab") && points["state"] == .array([.string("selected")]))
        #expect(o["title"] == .string("Offers") && o["changed"] == .array([]))
        for k in ["back", "actions", "fields", "lists", "floating", "text", "more"] { #expect(o[k] != nil) }
    }

    /// P2 (iPhone 17 Pro, Ajustes > Geral, 2026-11-22): the cell and its button carry the same label; one item each,
    /// the shallower (the cell), with its ref.
    @Test func iosSettingsCellAndButtonWithTheSameLabelBecomeOneItem() {
        var nodes = [UINode(ref: "e1", cls: "Application", text: "", desc: "", id: "", bounds: CGRect(x: 0, y: 0, width: 390, height: 844), clickable: false, depth: 0),
                     UINode(ref: "e2", cls: "StaticText", text: "Geral", desc: "", id: "", bounds: CGRect(x: 150, y: 60, width: 90, height: 30), clickable: false, depth: 1)]
        for (k, label) in ["Teclado", "Fontes", "Sobre"].enumerated() {
            let y = 300 + k * 60
            nodes.append(UINode(ref: "e\(nodes.count + 1)", cls: "Cell", text: label, desc: "", id: "",
                                bounds: CGRect(x: 0, y: y, width: 390, height: 44), clickable: true, depth: 1))
            nodes.append(UINode(ref: "e\(nodes.count + 1)", cls: "Button", text: label, desc: "", id: "",
                                bounds: CGRect(x: 16, y: y + 4, width: 358, height: 36), clickable: true, depth: 2))
        }
        let s = ScreenModel.build(nodes, size: CGSize(width: 390, height: 844))
        #expect(ScreenModel.text(s) == "Tela: Geral\nAções: [Teclado] [Fontes] [Sobre]")
        #expect(s.actions.map(\.ref) == ["e3", "e5", "e7"])
    }

    /// Near twins (centres < 24 px) merge into the shallower; the same label far apart stays two items. The Android
    /// Offers tree has no twins: `offersScreenGroupsTitleTabsActionsContentAndFloating` keeps today's exact text.
    @Test func dedupMergesOnlyNearTwinsIntoTheShallower() {
        let nodes = [UINode(ref: "e1", cls: "android.widget.TextView", text: "Item", desc: "", id: "", bounds: CGRect(x: 0, y: 400, width: 720, height: 60), clickable: false, depth: 1),
                     UINode(ref: "e2", cls: "android.widget.TextView", text: "Item", desc: "", id: "", bounds: CGRect(x: 0, y: 410, width: 720, height: 60), clickable: false, depth: 2),
                     UINode(ref: "e3", cls: "android.widget.TextView", text: "Item", desc: "", id: "", bounds: CGRect(x: 0, y: 900, width: 720, height: 60), clickable: false, depth: 1)]
        let s = ScreenModel.build(nodes, size: CGSize(width: 720, height: 1600))
        #expect(s.content.map(\.ref) == ["e1", "e3"])
    }

    @Test func symbolNameNoiseMatchesOnlySymbolNames() {
        for l in ["chevron", "chevron.right", "apple.id", "xmark.circle.fill", "wifi", "square.and.arrow.up"] { #expect(symbolNameNoise(l), "\(l)") }
        for l in ["", "Wi-Fi", "2.4.1", "Versão 2.4.1", "Conta Apple", "ação", "Chevron", "a b", ".hidden"] { #expect(!symbolNameNoise(l), "\(l)") }
    }

    /// A2 (iPhone, Ajustes, 2026-11-22): Image "apple.id" and "chevron" left Conteúdo noisy; real text with a dot stays.
    @Test func iosSettingsImageSymbolNamesLeaveContent() {
        func n(_ cls: String, _ text: String, _ y: Int, _ h: Int, _ depth: Int, click: Bool = false, scroll: Bool = false) -> UINode {
            UINode(ref: "", cls: cls, text: text, desc: "", id: "", bounds: CGRect(x: 0, y: y, width: 390, height: h),
                   clickable: click, depth: depth, scrollable: scroll)
        }
        var nodes = [n("Application", "", 0, 844, 0), n("StaticText", "Ajustes", 60, 30, 1), n("Table", "", 150, 694, 1, scroll: true),
                     n("Cell", "", 200, 60, 2, click: true), n("Image", "apple.id", 205, 50, 3), n("StaticText", "Conta Apple", 210, 20, 3),
                     n("Image", "chevron", 215, 20, 3),
                     n("Cell", "Wi-Fi", 300, 44, 2, click: true), n("Image", "wifi", 305, 30, 3), n("Image", "chevron", 310, 20, 3),
                     n("StaticText", "Versão 2.4.1", 400, 20, 2)]
        for i in nodes.indices { nodes[i].ref = "e\(i + 1)" }
        let tree = UITree.linkParents(nodes)
        let s = ScreenModel.build(tree, size: CGSize(width: 390, height: 844))
        #expect(s.content.map(\.label) == ["Conta Apple", "Wi-Fi", "Versão 2.4.1"])
        let text = ScreenModel.text(s)
        for noise in ["chevron", "apple.id", "wifi"] { #expect(!text.contains(noise), "\(text)") }
        #expect(tree.contains { $0.text == "chevron" })   // the raw tree (device ui, --all) keeps it
    }

    /// A button whose only label is a symbol stays in Ações, named by its id (as the floating button is).
    @Test func buttonLabelledOnlyBySymbolStaysInActionsWithItsId() {
        let nodes = UITree.linkParents([
            UINode(ref: "e1", cls: "Application", text: "", desc: "", id: "", bounds: CGRect(x: 0, y: 0, width: 390, height: 844), clickable: false, depth: 0),
            UINode(ref: "e2", cls: "StaticText", text: "Fotos", desc: "", id: "", bounds: CGRect(x: 150, y: 60, width: 90, height: 30), clickable: false, depth: 1),
            UINode(ref: "e3", cls: "Button", text: "", desc: "", id: "share_button", bounds: CGRect(x: 150, y: 400, width: 90, height: 44), clickable: true, depth: 1),
            UINode(ref: "e4", cls: "Image", text: "square.and.arrow.up", desc: "", id: "", bounds: CGRect(x: 170, y: 405, width: 30, height: 30), clickable: false, depth: 2),
            UINode(ref: "e5", cls: "android.widget.ImageButton", text: "", desc: "xmark", id: "close", bounds: CGRect(x: 150, y: 600, width: 90, height: 44), clickable: true, depth: 1)])
        let s = ScreenModel.build(nodes, size: CGSize(width: 390, height: 844))
        #expect(s.actions.map(\.label) == ["share button", "close"])
        #expect(s.actions.map(\.id) == ["share_button", "close"])
        #expect(s.content.isEmpty)
    }
}
