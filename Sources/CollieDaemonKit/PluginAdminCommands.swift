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
            return .object(["plugins": try isoJSON(await plugins.loaded().map(\.0)), "version": .number(Double(PluginRegistry.catalogVersion))])
        default: break
        }
        guard caller == nil else {
            throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is the user's alone: only the user installs or changes plug-ins (no app, ou collie fora de um terminal)")
        }
        switch r.command {
        case "plugin.install":
            let base = URL(fileURLWithPath: r.cwd ?? NSHomeDirectory(), isDirectory: true)
            let expect = str(r, "expectId").map { ($0, str(r, "expectVersion") ?? "") }
            let e = try await plugins.install(from: URL(fileURLWithPath: try need(r, "path"), relativeTo: base).absoluteURL,
                                              expect: expect, replace: flag(r, "replace"))
            await publishPlugins()
            return try await pluginRow(e)
        case "plugin.uninstall":
            try await plugins.uninstall(try need(r, "id"))
            await publishPlugins()
            return .object([:])
        case "plugin.enable", "plugin.disable":
            let id = try need(r, "id")
            try await plugins.setEnabled(id, r.command == "plugin.enable")
            await publishPlugins()
            guard let e = await plugins.list().first(where: { $0.id == id }) else { return .object([:]) }
            return try await pluginRow(e)
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// The store's loaded plug-ins become this process's registry (`Commands.all`, routing, help) and the app hears
    /// `pluginsChanged`. At start (`atStart`) an empty store leaves the registry alone and emits nothing.
    func publishPlugins(atStart: Bool = false) async {
        let ms = await plugins.loaded().map(\.0)
        if atStart && ms.isEmpty { return }   // ponytail: tests run many daemons in one process; one with none must not clear another's
        PluginRegistry.setExternal(ms.map { $0.pluginSpec() })
        if !atStart { await hub.emit(.pluginsChanged(ms)) }
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

extension CommandRouter {
    /// An external plug-in's output command result: its `path` must be `<root>/plugins-out/<id>/<file>`, every
    /// component a real directory and the file a regular one (lstat, no link followed), never a dot name. The app's host
    /// writes these files from the bytes the page hands it; the page never picks a path. No `path`: unchanged.
    nonisolated func vetPluginOutput(_ result: JSONValue, plugin id: String) throws(ProtocolError) -> JSONValue {
        guard case .object(var o) = result, let v = o["path"] else { return result }
        let bad = ProtocolError(code: .invalidArgs, message: "o plug-in '\(id)' devolveu um arquivo fora de plugins-out/\(id)")
        guard case .string(let p) = v, p.hasPrefix("/"), !p.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw bad }
        let root = config.paths.root.standardizedFileURL.path, real = SignedAppCheck.realPath(config.paths.root)
        guard let base = [root, real].first(where: { p.hasPrefix($0 + "/") }) else { throw bad }
        let rel = p.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard rel.count == 3, rel[0] == "plugins-out", rel[1] == id, !rel[2].isEmpty, !rel[2].hasPrefix(".") else { throw bad }
        var at = URL(fileURLWithPath: base)
        for (i, c) in rel.enumerated() {
            at.appendPathComponent(c)
            let t = try? FileManager.default.attributesOfItem(atPath: at.path)[.type] as? FileAttributeType   // lstat
            guard t == (i < 2 ? .typeDirectory : .typeRegular) else { throw bad }
        }
        o["path"] = .string(p)
        return .object(o)
    }
}
