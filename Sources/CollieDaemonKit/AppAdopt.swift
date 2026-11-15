import Foundation
import CollieCore
import CollieProtocol

/// `collie app adopt` (spec 2026-11-15, phase 1): a v2 manifest for a local tool that already runs a loopback web
/// service, so it becomes an app do cercado like any other (approval, pin, service, SSE, `confirm`). Pure: no file or
/// network access here; the command (`app.adopt`) finds the commands and writes the file.
enum AppAdopt {
    struct Input {
        var id, name, url: String
        var start, cwd, health, ui, eventStream, eventDiff: String?
        var cmds: [PluginManifest.Command]
        /// `--notify`: events type a notice into the agents; off by default (consult mode: the agent asks when it wants).
        var notify = false
    }
    static let openAPICap = 40

    /// `events=GET:/api/document,clear_analytics=POST:/api/clear/analytics`: `_` in a name becomes `-` (command names are
    /// a-z, 0-9 and '-'); POST, PUT and DELETE ask for a confirmation on each call.
    static func parseCmds(_ flag: String) throws(ProtocolError) -> [PluginManifest.Command] {
        var out: [PluginManifest.Command] = []
        for item in flag.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            let bad = ProtocolError(code: .invalidArgs, message: "--cmd '\(item)': name=METHOD:/path (METHOD GET|POST|PUT|DELETE, name a-z, 0-9, '-', '_')")
            guard let eq = item.firstIndex(of: "="), let colon = item[eq...].firstIndex(of: ":") else { throw bad }
            let name = item[..<eq].replacingOccurrences(of: "_", with: "-")
            let method = String(item[item.index(after: eq)..<colon]), path = String(item[item.index(after: colon)...])
            guard (try? Regex("[a-z][a-z0-9-]{0,31}").wholeMatch(in: name)) != nil, ["GET", "POST", "PUT", "DELETE"].contains(method),
                  path.hasPrefix("/") else { throw bad }
            out.append(try command(name: name, summary: "\(method) \(path)", method: method, path: path, params: []))
        }
        return out
    }

    /// `--pick analyticsEvents,analyticsEventCount`: `result.pick` of every GET command (a write's reply stays whole).
    static func applyPick(_ flag: String, to cmds: inout [PluginManifest.Command]) throws(ProtocolError) {
        let keys = flag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !keys.isEmpty, keys.count <= 32, keys.allSatisfy({ $0.count <= 64 }) else {
            throw ProtocolError(code: .invalidArgs, message: "--pick: 1 to 32 comma-separated keys of the JSON reply (each ≤ 64 chars)")
        }
        guard cmds.contains(where: { $0.http?.method == "GET" }) else {
            throw ProtocolError(code: .invalidArgs, message: "--pick shapes the reply of a GET command of --cmd; there is none")
        }
        for i in cmds.indices where cmds[i].http?.method == "GET" { cmds[i].result = .init(pick: keys) }
    }

    /// The `commands` of a `collie.json` (the manifest's own format); the manifest built from them validates them.
    static func commands(fromCollieJSON data: Data) throws(ProtocolError) -> [PluginManifest.Command] {
        struct File: Decodable { var commands: [PluginManifest.Command] }
        do { return try JSONDecoder().decode(File.self, from: data).commands } catch {
            throw ProtocolError(code: .invalidArgs, message: "collie.json: {\"commands\": [...]} in the manifest's format (\(error is DecodingError ? "bad shape" : "not JSON"))")
        }
    }

    /// One command per operation of an OpenAPI / Swagger document's `paths` (at most `openAPICap`): named by its
    /// `operationId` (or method and path), its query parameters as string params; writes ask for a confirmation. What
    /// it doesn't understand it skips.
    // ponytail: a templated path (`/items/{id}`) is skipped: an http command's path is fixed (params go in the query or body)
    static func commands(fromOpenAPI data: Data) -> [PluginManifest.Command] {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let paths = doc["paths"] as? [String: Any] else { return [] }
        var out: [PluginManifest.Command] = [], names: Set<String> = []
        for path in paths.keys.sorted() where safePath(path) {
            guard let ops = paths[path] as? [String: Any] else { continue }
            for method in ["get", "post", "put", "patch", "delete"] {
                guard out.count < openAPICap, let op = ops[method] as? [String: Any] else { continue }
                let name = (op["operationId"] as? String).flatMap(slug) ?? slug("\(method) \(path)")
                guard let name, names.insert(name).inserted else { continue }
                let params = ((op["parameters"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
                    .filter { $0["in"] as? String == "query" }.compactMap { ($0["name"] as? String).flatMap(slug) }.filter { $0 != "panel" }
                let summary = String(((op["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(method.uppercased()) \(path)")
                    .filter { !$0.isNewline }.prefix(120))
                if let c = try? command(name: name, summary: summary, method: method.uppercased(), path: path, params: Array(Set(params)).sorted()) { out.append(c) }
            }
        }
        return out
    }

    /// The manifest file: pretty, keys sorted (the same input, the same bytes), validated by `PluginManifest.decode`.
    static func manifest(_ i: Input) throws(ProtocolError) -> Data {
        guard let origin = PluginManifest.loopbackOrigin(i.url) else {
            throw ProtocolError(code: .invalidArgs, message: "--url '\(i.url)': a loopback base (http://127.0.0.1:<port>, http://[::1]:<port> or http://localhost:<port>), no path")
        }
        let ui = i.ui ?? "/"
        var service: [String: Any] = ["base": origin]
        for (k, v) in [("start", i.start), ("cwd", i.cwd), ("health", i.health)] { if let v { service[k] = v } }
        var m: [String: Any] = [
            "apiVersion": 2, "id": i.id, "name": i.name, "version": "0.1.0", "license": "private",
            "placements": ["canvas", "dock.right"], "defaultPlacement": "dock.right",
            "ui": ui.hasPrefix("http://") || ui.hasPrefix("https://") ? ui : origin + (ui.hasPrefix("/") ? ui : "/" + ui),
            "service": service, "notify": i.notify, "events": i.eventStream == nil ? [String]() : ["\(i.id).event"],
        ]
        if let e = i.eventStream { m["eventStream"] = e }
        if let k = i.eventDiff { m["eventDiff"] = k }
        guard let cmds = try? JSONEncoder().encode(i.cmds), let list = try? JSONSerialization.jsonObject(with: cmds) else {
            throw ProtocolError(code: .internal, message: "commands")
        }
        m["commands"] = list
        guard let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw ProtocolError(code: .internal, message: "manifest")
        }
        _ = try PluginManifest.decode(data)
        return data
    }

    /// `PluginManifest.Command` has no memberwise init outside its module: built from its JSON form.
    private static func command(name: String, summary: String, method: String, path: String, params: [String]) throws(ProtocolError) -> PluginManifest.Command {
        let o: [String: Any] = ["name": name, "summary": summary, "runs": "http", "http": ["method": method, "path": path],
                                "confirm": method != "GET", "timeout": method == "GET" ? 30 : 15,
                                "params": params.map { ["name": $0, "type": "string", "help": "query parameter \($0)"] }]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let c = try? JSONDecoder().decode(PluginManifest.Command.self, from: d) else {
            throw ProtocolError(code: .internal, message: "command \(name)")
        }
        return c
    }

    /// `getDocument` / `post /api/clear` → `get-document` / `post-api-clear`: a-z, 0-9 and '-', starting with a letter, ≤ 32.
    static func slug(_ s: String) -> String? {
        var out = "", dash = false
        for ch in s {
            if ch.isUppercase, !out.isEmpty, !dash { out.append("-") }
            if let a = ch.lowercased().first, a.isASCII, a.isLetter || a.isNumber { out.append(a); dash = false }
            else if !out.isEmpty, !dash { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        let r = String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return r.first?.isLetter == true ? r : nil
    }

    /// What `PluginManifest` accepts as an http path: plain segments, no `..`, `?`, `#` or template.
    static func safePath(_ p: String) -> Bool {
        p.utf8.count <= 512 && (try? Regex("/([A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*/?)?").wholeMatch(in: p)) != nil
            && !p.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}
