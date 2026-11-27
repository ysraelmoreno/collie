import Foundation
import Testing
import CollieClient
import CollieCore
import CollieProtocol
@testable import CollieApp

private let edit = "Roda um programa a cada arquivo que um agente edita", read = "Pode ler os arquivos do projeto"
private func item(_ id: String, kind: PluginCatalog.Kind = .agent, latest: String? = "0.2.0", hooks: [String] = [], project: Bool = false,
                  installed: String? = nil, recalled: String? = nil) -> PluginCatalogView.Item {
    let l = latest.map { PluginCatalogView.Latest(version: $0, size: 812_345, permissions: project ? ["project": .string("read")] : [:], hooks: hooks) }
    let update = installed.map { i in latest.map { PluginCatalog.compare($0, i) == .orderedDescending } ?? false } ?? false
    return .init(id: id, name: id.capitalized, kind: kind, latest: l, installed: installed.map { .init(version: $0) },
                 update: update, recalled: recalled.map { .init(reason: $0) })
}

/// M5: the kind chips filter the cards; an item nothing here can install, and not installed, is hidden.
@Test(.appPT) func catalogRowsFilterByKind() {
    let v = PluginCatalogView(items: [item("vizinho"), item("notas", kind: .panel), item("figcraft", kind: .engine),
                                      item("futuro", latest: nil)])
    #expect(PluginCatalogModel.rows(v, filter: .all).map(\.id) == ["vizinho", "notas", "figcraft"])
    #expect(PluginCatalogModel.rows(v, filter: .panel).map(\.id) == ["notas"])
    #expect(PluginCatalogModel.rows(v, filter: .agent).map(\.id) == ["vizinho"])
    #expect(PluginCatalogModel.rows(v, filter: .engine).map(\.id) == ["figcraft"])
    #expect(CatalogFilter.allCases.map(\.title) == ["Todos", "Painéis", "Agentes", "Motores"])
}

/// M5: the button of each card (owner's rules of 2026-11-24): an update asks again only for a new permission line.
@Test(.appPT) func catalogActionPerState() {
    #expect(PluginCatalogModel.action(item("vizinho")) == .install)
    #expect(PluginCatalogModel.action(item("vizinho", installed: "0.2.0"), installed: PluginRow(id: "vizinho", name: "Vizinho", version: "0.2.0")) == .installed)
    // same lines as installed: one click, no confirmation
    let same = PluginRow(id: "vizinho", name: "Vizinho", version: "0.1.0", permissions: [edit])
    #expect(PluginCatalogModel.action(item("vizinho", hooks: ["edit"], installed: "0.1.0"), installed: same) == .update(needsConfirm: false))
    #expect(PluginCatalogModel.action(item("notas", installed: "0.1.0"), installed: PluginRow(id: "notas", name: "Notas", version: "0.1.0")) == .update(needsConfirm: false))
    // the new version reads the project too: confirmation
    #expect(PluginCatalogModel.action(item("vizinho", hooks: ["edit"], project: true, installed: "0.1.0"), installed: same) == .update(needsConfirm: true))
    // recalled: by the catalog row or by the installed row alone
    #expect(PluginCatalogModel.action(item("notas", installed: "0.1.0", recalled: "grava fora da pasta")) == .recalled(reason: "grava fora da pasta"))
    let gone = PluginRow(id: "notas", name: "Notas", version: "0.2.0", enabled: false, recalled: .init(reason: "vaza", at: Date()))
    #expect(PluginCatalogModel.action(item("notas", installed: "0.2.0"), installed: gone) == .recalled(reason: "vaza"))
    #expect(PluginCatalogModel.target(item("notas", installed: "0.1.0", recalled: "x"))?.version == "0.2.0")
    #expect(PluginCatalogModel.target(item("notas", installed: "0.2.0", recalled: "x")) == nil)
    #expect(PluginCatalogModel.action(item("figcraft", kind: .engine)) == .engine)
}

/// M5: unavailable and stale say so above the list; size in pt-BR.
@Test(.appPT) func catalogBannerAndSize() {
    #expect(PluginCatalogModel.banner(PluginCatalogView(state: "unavailable", items: [])) == "O catálogo não carregou. Os plug-ins instalados seguem funcionando.")
    #expect(PluginCatalogModel.banner(PluginCatalogView(state: "stale", items: []))?.hasPrefix("Catálogo desatualizado") == true)
    #expect(PluginCatalogModel.banner(PluginCatalogView(items: [])) == nil)
    #expect(PluginCatalogModel.size(812_345) == "0,8 MB")
}

/// M5: the client decodes M3's `plugin.catalog` reply as the daemon writes it.
@Test(.appPT) func catalogViewDecodesDaemonReply() throws {
    let json = #"{"state":"stale","reason":"sem rede","generatedAt":"2026-11-01T12:00:00Z","items":[{"id":"vizinho","name":"Vizinho","publisher":"collie","publisherName":"Collie","summary":"s","kind":"agent","latest":{"version":"0.2.0","size":812345,"permissions":{"project":"read"},"hooks":["edit"],"helperTeamId":"AG8JQAH6YB"},"installed":{"version":"0.1.0","source":"catalog"},"update":true,"recalled":{"reason":"r"}}]}"#
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let v = try dec.decode(PluginCatalogView.self, from: Data(json.utf8))
    #expect(v.state == "stale" && v.items.first?.latest?.permissionLines == [edit, read] && v.items.first?.recalled?.reason == "r")
}

/// T2: the card's author line; a third party's update without new permissions is one click, like Collie's.
@Test func catalogCardNamesTheAuthor() {
    #expect(PluginCatalogModel.byline(PluginCatalogView.Item(id: "v", name: "V")) == "Collie · revisado")
    #expect(PluginCatalogModel.byline(PluginCatalogView.Item(id: "g", name: "G", publisher: "acme", publisherName: "Acme Ltda")) == "Acme Ltda · revisado pelo Collie")
    let item = PluginCatalogView.Item(id: "g", name: "G", publisher: "acme", publisherName: "Acme Ltda", latest: .init(version: "1.1.0"),
                                      installed: .init(version: "1.0.0"), update: true)
    #expect(PluginCatalogModel.action(item, installed: PluginRow(id: "g", name: "G", version: "1.0.0")) == .update(needsConfirm: false))
}
