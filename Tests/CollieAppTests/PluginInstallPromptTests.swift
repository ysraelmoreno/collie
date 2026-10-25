import Foundation
import Testing
import CollieClient
import CollieCore
import CollieProtocol
@testable import CollieApp

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")

/// Task 1 review: installing over an installed id says what it replaces (old and new author and version) before anything happens.
@Test func pluginInstallPromptNamesWhatItReplaces() throws {
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
