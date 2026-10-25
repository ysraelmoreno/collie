import Foundation
import CollieCore
import CollieProtocol

/// `plugin.*`: external plug-ins (`PluginStore`). Install, uninstall, enable and disable are the user's alone (the admin
/// token with the same peer checks as `admin.*`: never from inside a Collie terminal); `plugin.list` and `plugin.specs`
/// answer terminals too, with ids, names, versions and commands, never a filesystem path.
extension CommandRouter {
    func pluginAdminCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the app, or collie outside a terminal)
        switch r.command {
        case "plugin.list":
            var rows: [JSONValue] = []
            for e in await plugins.list() { rows.append(try await pluginRow(e)) }
            return .array(rows)
        case "plugin.specs":
            return .object(["plugins": try isoJSON(await plugins.loaded().map(\.0))])
        default: break
        }
        guard caller == nil else {
            throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is the user's alone: only the user installs or changes plug-ins (no app, ou collie fora de um terminal)")
        }
        switch r.command {
        case "plugin.install":
            let base = URL(fileURLWithPath: r.cwd ?? NSHomeDirectory(), isDirectory: true)
            let e = try await plugins.install(from: URL(fileURLWithPath: try need(r, "path"), relativeTo: base).absoluteURL)
            return try await pluginRow(e)
        case "plugin.uninstall":
            try await plugins.uninstall(try need(r, "id"))
            return .object([:])
        case "plugin.enable", "plugin.disable":
            let id = try need(r, "id")
            try await plugins.setEnabled(id, r.command == "plugin.enable")
            guard let e = await plugins.list().first(where: { $0.id == id }) else { return .object([:]) }
            return try await pluginRow(e)
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    private func pluginRow(_ e: InstalledPlugin) async throws -> JSONValue {
        guard case .object(var o) = try isoJSON(e) else { return .null }
        o["name"] = .string(e.id)   // a plug-in that fails to load has no readable manifest
        if let m = await plugins.manifest(e.id) {
            o["name"] = .string(m.name); o["author"] = .string(m.author); o["license"] = .string(m.license)
            o["commands"] = .array(m.commands.map { .string($0.name) })
        }
        return .object(o)
    }
}
