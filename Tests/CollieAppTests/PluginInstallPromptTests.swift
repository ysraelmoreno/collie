import Foundation
import Testing
import CollieClient
import CollieCore
import CollieProtocol
@testable import CollieApp

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")

/// Task 1 review: installing over an installed id says what it replaces (old and new author and version) before anything happens.
@Test(.appPT) func pluginInstallPromptNamesWhatItReplaces() throws {
    let fresh = try PluginInstallPrompt.make(folder: notas, installed: [PluginRow(id: "kanban", name: "Kanban", version: "1.0.0")])
    #expect(fresh.replacing == nil && fresh.title == "Instalar Notas 0.1.0?" && fresh.confirm == "Instalar")
    #expect(fresh.details == ["Autor: Collie · Licença: MIT", "3 comandos"])
    #expect(fresh.commands == ["collie notas add — Add a note; returns it {id,text,at}", "collie notas list — The notes, oldest first [{id,text,at}]",
                               "collie notas export — Export the notes to a file; returns {path}"])
    let old = PluginRow(id: "notas", name: "Notas velhas", version: "0.0.9", author: "Fulano")
    let over = try PluginInstallPrompt.make(folder: notas, installed: [old])
    #expect(over.replacing == old && over.title == "Substituir Notas velhas?" && over.confirm == "Substituir")
    #expect(over.replaceLine == "Substitui Notas velhas 0.0.9 (de Fulano) por Notas 0.1.0 (de Collie).")
    let unknown = try PluginInstallPrompt.make(folder: notas, installed: [PluginRow(id: "notas", name: "notas", version: "0.1.0")])
    #expect(unknown.replaceLine == "Substitui notas 0.1.0 (de autor desconhecido) por Notas 0.1.0 (de Collie).")
    // a folder that isn't a plug-in: the manifest's own error, verbatim
    #expect(throws: ProtocolError.self) { try PluginInstallPrompt.make(folder: notas.appendingPathComponent("ui"), installed: []) }
}

/// G6: the confirmation lists what a hooks plug-in may do, and marks what a replacement adds to the installed one.
@Test(.appPT) func pluginInstallPromptShowsPermissions() throws {
    let fresh = try PluginInstallPrompt.make(folder: notas, installed: [])
    #expect(fresh.permissions.isEmpty && fresh.newPermissions.isEmpty)
    let edit = "Roda um programa a cada arquivo que um agente edita", read = "Pode ler os arquivos do projeto"
    let hooked = PluginInstallPrompt(folder: notas, manifest: try hookManifest(), replacing: PluginRow(id: "vizinho", name: "Vizinho", version: "0.1.0", permissions: [edit]))
    #expect(hooked.permissions == [edit, read] && hooked.newPermissions == [read])
    let first = PluginInstallPrompt(folder: notas, manifest: try hookManifest(), replacing: nil)
    #expect(first.newPermissions.isEmpty && first.permissions == [edit, read])
}
/// M5: a catalog install says where it comes from, who published it and its size; an update marks what's new.
@Test(.appPT) func pluginInstallPromptFromCatalog() {
    let item = PluginCatalogView.Item(id: "vizinho", name: "Vizinho", publisherName: "Collie")
    let latest = PluginCatalogView.Latest(version: "0.2.0", size: 812_345, permissions: ["project": .string("read")], hooks: ["edit"])
    let fresh = PluginInstallPrompt(catalog: item, latest: latest, replacing: nil)
    #expect(fresh.catalogLine == "Do catálogo, publicado por Collie · revisado" && fresh.folder == nil)
    #expect(fresh.title == "Instalar Vizinho 0.2.0?" && fresh.details == ["Autor: Collie", "0,8 MB"] && fresh.commands.isEmpty)
    #expect(fresh.permissions == ["Roda um programa a cada arquivo que um agente edita", "Pode ler os arquivos do projeto"])
    let over = PluginInstallPrompt(catalog: item, latest: latest, replacing: PluginRow(id: "vizinho", name: "Vizinho", version: "0.1.0",
                                                                                     permissions: ["Roda um programa a cada arquivo que um agente edita"]))
    #expect(over.newPermissions == ["Pode ler os arquivos do projeto"] && over.confirm == "Substituir")
    let folder = PluginInstallPrompt(folder: notas, manifest: try! PluginManifest.load(folder: notas), replacing: nil)
    #expect(folder.catalogLine == nil)
}
private func hookManifest() throws -> PluginManifest {
    let m: [String: Any] = ["apiVersion": 1, "id": "vizinho", "name": "Vizinho", "version": "0.2.0", "ui": "ui/index.html",
                            "hooks": ["edit"], "helper": "bin/vizinho", "permissions": ["project": "read"]]
    return try PluginManifest.decode(JSONSerialization.data(withJSONObject: m))
}
