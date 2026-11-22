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
}
