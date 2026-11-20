import Testing
import Foundation
import CollieCore
import CollieProtocol

private func manifest(hooks: [String]? = nil, project: String? = nil) throws -> PluginManifest {
    var m: [String: Any] = ["apiVersion": 1, "id": "vizinho", "name": "Vizinho", "version": "0.1.0", "ui": "ui/index.html"]
    if let hooks { m["hooks"] = hooks; m["helper"] = "bin/vizinho" }
    if let project { m["permissions"] = ["project": project] }
    return try PluginManifest.decode(JSONSerialization.data(withJSONObject: m))
}

@Suite struct PluginPermissionLinesTests {
    static let edit = "Roda um programa a cada arquivo que um agente edita"
    static let stop = "Roda um programa ao fim de cada turno e pode pedir que o agente continue"
    static let read = "Pode ler os arquivos do projeto"

    @Test func nothingExtraIsEmpty() throws {
        #expect(try manifest().permissionLines.isEmpty)
        #expect(try manifest(project: "none").permissionLines.isEmpty)
    }
    @Test func editOnly() throws { #expect(try manifest(hooks: ["edit"]).permissionLines == [Self.edit]) }
    @Test func stopOnly() throws { #expect(try manifest(hooks: ["stop"]).permissionLines == [Self.stop]) }
    @Test func bothHooksAndProjectRead() throws {
        #expect(try manifest(hooks: ["edit", "stop"], project: "read").permissionLines == [Self.edit, Self.stop, Self.read])
        #expect(try manifest(project: "read").permissionLines == [Self.read])
    }
}
