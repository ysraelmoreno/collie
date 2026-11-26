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

@Suite(.serialized) struct PluginPermissionLinesTests {
    static let edit = "Roda um programa a cada arquivo que um agente edita"
    static let stop = "Roda um programa ao fim de cada turno e pode pedir que o agente continue"
    static let read = "Pode ler os arquivos do projeto"

    @Test func nothingExtraIsEmpty() throws {
        #expect(try manifest().permissionLines.isEmpty)
        #expect(try manifest(project: "none").permissionLines.isEmpty)
    }
    @Test func editOnly() throws {
        let m = try manifest(hooks: ["edit"])
        L10n.$override.withValue(.pt) { #expect(m.permissionLines == [Self.edit]) }
    }
    @Test func stopOnly() throws {
        let m = try manifest(hooks: ["stop"])
        L10n.$override.withValue(.pt) { #expect(m.permissionLines == [Self.stop]) }
    }
    @Test func bothHooksAndProjectRead() throws {
        let both = try manifest(hooks: ["edit", "stop"], project: "read"), read = try manifest(project: "read")
        L10n.$override.withValue(.pt) {
            #expect(both.permissionLines == [Self.edit, Self.stop, Self.read])
            #expect(read.permissionLines == [Self.read])
        }
    }
}

@Suite struct PluginPermissionLinesEnglishTests {
    @Test func linesInEnglish() throws {
        let m = try manifest(hooks: ["edit", "stop"], project: "read")
        L10n.$override.withValue(.en) {
            #expect(m.permissionLines == [
                "Runs a program on every file an agent edits",
                "Runs a program at the end of every turn and can ask the agent to continue",
                "Can read the project files"])
        }
    }
}
