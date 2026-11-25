import Foundation
import CollieProtocol

extension PluginManifest {
    /// What installing this plug-in lets it do beyond its own page, one pt-BR line each. Shown before the install is
    /// confirmed, in Preferências → Plug-ins, in `plugin.list` and in `collie plugin install`. Empty: nothing extra.
    public var permissionLines: [String] { Self.permissionLines(hooks: hookEvents, permissions: permissions) }

    /// The same lines from a catalog version's `hooks` and raw `permissions` (no manifest at hand before the download).
    public static func permissionLines(hooks: [String], permissions: [String: JSONValue]?) -> [String] {
        var lines: [String] = []
        if hooks.contains("edit") { lines.append("Roda um programa a cada arquivo que um agente edita") }
        if hooks.contains("stop") { lines.append("Roda um programa ao fim de cada turno e pode pedir que o agente continue") }
        if permissions?["project"] == JSONValue.string("read") { lines.append("Pode ler os arquivos do projeto") }
        return lines
    }
}
