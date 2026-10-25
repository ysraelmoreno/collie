import Foundation
import CollieProtocol

/// An external plug-in's `collie-plugin.json` (spec: docs/superpowers/specs/2026-10-25-external-plugins-design.md).
/// Phase 1 accepts web-UI plug-ins only: `apiVersion` 1, a `ui`, commands that run in the page, no helper, no
/// permissions. Unknown keys are ignored (a newer manifest still loads); every known one is validated: the id and the
/// version name folders, the `ui` path is served by the app.
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Param: Codable, Sendable, Equatable {
        public var name: String
        public var type: String            // string | int | flag | rest
        public var required: Bool
        public var positional: Bool
        public var help: String
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name); type = try c.decode(String.self, forKey: .type)
            required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
            positional = try c.decodeIfPresent(Bool.self, forKey: .positional) ?? false
            help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
        }
    }
    public struct Command: Codable, Sendable, Equatable {
        public var name: String
        public var summary: String
        public var runs: String            // ui (phase 1) | helper (phase 2)
        public var params: [Param]
        public var timeout: Double         // seconds, 1-300
        /// The result's `path` is a file made for the caller (plan 2O hand-over).
        public var outputFile: Bool
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name); summary = try c.decode(String.self, forKey: .summary)
            runs = try c.decode(String.self, forKey: .runs)
            params = try c.decodeIfPresent([Param].self, forKey: .params) ?? []
            timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 30
            outputFile = try c.decodeIfPresent(Bool.self, forKey: .outputFile) ?? false
        }
    }

    public var apiVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var license: String
    public var placements: [PanelPlacement]
    public var defaultPlacement: PanelPlacement
    public var ui: String
    public var helper: String?             // phase 2; refused now
    public var commands: [Command]
    public var events: [String]
    public var stateKeys: [String]
    public var permissions: [String: JSONValue]?   // phase 3; only absent/empty accepted now

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        placements = try c.decodeIfPresent([PanelPlacement].self, forKey: .placements) ?? [.canvas]
        defaultPlacement = try c.decodeIfPresent(PanelPlacement.self, forKey: .defaultPlacement) ?? placements.first ?? .canvas
        ui = try c.decode(String.self, forKey: .ui)
        helper = try c.decodeIfPresent(String.self, forKey: .helper)
        commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        stateKeys = try c.decodeIfPresent([String].self, forKey: .stateKeys) ?? []
        permissions = try c.decodeIfPresent([String: JSONValue].self, forKey: .permissions)
    }

    public static let fileName = "collie-plugin.json"
    static let newer = "precisa de um Collie mais novo (helpers/permissões chegam na fase 2/3)"

    /// Decodes and validates a manifest (pure: no file access).
    public static func decode(_ data: Data) throws(ProtocolError) -> PluginManifest {
        struct Version: Decodable { var apiVersion: Int }
        guard let v = try? JSONDecoder().decode(Version.self, from: data) else { throw bad("manifesto inválido: falta apiVersion (número)") }
        guard v.apiVersion == 1 else {
            throw bad(v.apiVersion > 1 ? "precisa de um Collie mais novo (apiVersion \(v.apiVersion))" : "apiVersion inválida: \(v.apiVersion)")
        }
        let m: PluginManifest
        do { m = try JSONDecoder().decode(PluginManifest.self, from: data) } catch { throw bad("manifesto inválido: \(Self.describe(error))") }
        try m.validate()
        return m
    }

    /// Reads `<folder>/collie-plugin.json` (a regular file, ≤ 256 KiB), validates it and checks that `ui` is a regular
    /// file inside the folder (no link on the way).
    public static func load(folder: URL) throws(ProtocolError) -> PluginManifest {
        let f = folder.appendingPathComponent(fileName)
        guard regularFile(f), let size = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int, size <= 256 * 1024,
              let data = try? Data(contentsOf: f) else {
            throw bad("\(fileName) ausente, ilegível, não é um arquivo comum ou maior que 256 KiB")
        }
        let m = try decode(data)
        var at = folder   // every component lstat'ed: a link anywhere on the way is refused
        for part in m.ui.split(separator: "/") {
            at.appendPathComponent(String(part))
            guard let t = try? FileManager.default.attributesOfItem(atPath: at.path)[.type] as? FileAttributeType,
                  t == .typeDirectory || t == .typeRegular else { throw bad("ui '\(m.ui)' não existe no plug-in (ou é um link)") }
        }
        guard regularFile(at) else { throw bad("ui '\(m.ui)' não é um arquivo") }
        return m
    }

    /// The registry form: commands named `<id>.<name>`, run in the app's page (`ui.host`).
    public func pluginSpec() -> PluginSpec {
        let kinds: [String: ParamSpec.Kind] = ["string": .string, "int": .int, "flag": .flag, "rest": .rest]
        return PluginSpec(id: id, title: name, placements: placements, defaultPlacement: defaultPlacement,
            commands: commands.map { c in
                CommandSpec(name: "\(id).\(c.name)", summary: c.summary,
                            params: c.params.map { ParamSpec($0.name, kinds[$0.type] ?? .string, positional: $0.positional, required: $0.required, help: $0.help) },
                            timeoutSeconds: c.timeout)
            },
            events: events, runsInDaemon: false, source: .external(version: version))
    }

    /// An id and a version that are safe as folder names (what `validate` accepts), for entries read back from disk.
    public static func safeFolderNames(id: String, version: String) -> Bool {
        match(id, "[a-z][a-z0-9-]{1,31}") && match(version, "[0-9][0-9A-Za-z.+-]{0,31}")
    }

    func validate() throws(ProtocolError) {
        if helper != nil || commands.contains(where: { $0.runs == "helper" }) { throw Self.bad(Self.newer) }
        for (k, v) in permissions ?? [:] {   // empty network list and project "none" mean nothing asked
            switch (k, v) {
            case ("network", .array([])), ("project", .string("none")): continue
            default: throw Self.bad(Self.newer)
            }
        }
        guard Self.match(id, "[a-z][a-z0-9-]{1,31}") else { throw Self.bad("id '\(id)' inválido: use a-z, 0-9 e '-', 2 a 32, começando com letra") }
        guard !Commands.reservedPluginIds.contains(id) else { throw Self.bad("id '\(id)' é reservado pelo Collie") }
        try Self.text(name, "name", 1...64)
        guard Self.match(version, "[0-9][0-9A-Za-z.+-]{0,31}") else { throw Self.bad("version '\(version)' inválida (ex.: 0.1.0)") }
        try Self.text(author, "author", 0...128); try Self.text(license, "license", 0...64)
        guard !placements.isEmpty, !placements.contains(.headless) else { throw Self.bad("placements: um ou mais de canvas, dock.left, dock.right, dock.bottom") }
        guard placements.contains(defaultPlacement) else { throw Self.bad("defaultPlacement precisa estar em placements") }
        guard Self.safeUIPath(ui) else { throw Self.bad("ui '\(ui)' inválido: um .html dentro de ui/, sem '..'") }
        guard commands.count <= 64 else { throw Self.bad("no máximo 64 comandos") }
        var seen: Set<String> = []
        for c in commands {
            guard Self.match(c.name, "[a-z][a-z0-9-]{0,31}"), seen.insert(c.name).inserted else {
                throw Self.bad("nome de comando '\(c.name)' inválido ou repetido: a-z, 0-9 e '-', até 32, começando com letra")
            }
            guard c.runs == "ui" else { throw Self.bad("comando '\(c.name)': runs deve ser \"ui\"") }
            try Self.text(c.summary, "summary de '\(c.name)'", 1...2000)
            guard (1...300).contains(c.timeout) else { throw Self.bad("comando '\(c.name)': timeout entre 1 e 300 segundos") }
            var names: Set<String> = []
            for (i, p) in c.params.enumerated() {
                guard Self.match(p.name, "[a-z][a-z0-9-]{0,31}"), p.name != "panel", names.insert(p.name).inserted else {
                    throw Self.bad("comando '\(c.name)': parâmetro '\(p.name)' inválido, repetido ou reservado")
                }
                guard ["string", "int", "flag", "rest"].contains(p.type) else { throw Self.bad("parâmetro '\(p.name)': type string|int|flag|rest") }
                // ArgvParser: a rest word list is positional and takes every word left, so it comes last
                if p.type == "rest", !p.positional || c.params[(i + 1)...].contains(where: \.positional) {
                    throw Self.bad("parâmetro '\(p.name)': rest precisa ser o último posicional")
                }
                if p.type == "flag", p.positional || p.required { throw Self.bad("parâmetro '\(p.name)': flag não é posicional nem obrigatória") }
                try Self.text(p.help, "help de '\(p.name)'", 0...500)
            }
        }
        guard events.count <= 64, events.allSatisfy({ Self.match($0, "\(id)\\.[a-z][a-z0-9.-]{0,63}") }), Set(events).count == events.count else {
            throw Self.bad("events: até 64, cada um '\(id).<nome>'")
        }
        guard stateKeys.count <= 64, stateKeys.allSatisfy({ Self.match($0, "[A-Za-z][A-Za-z0-9_-]{0,63}") }) else {
            throw Self.bad("stateKeys: até 64 nomes (letras, dígitos, _ e -)")
        }
    }

    /// `ui/<name>.html`, every component a plain name (no empty, `.`, `..` or hidden-dot tricks), ≤ 512 bytes.
    static func safeUIPath(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return p.utf8.count <= 512 && parts.count >= 2 && parts[0] == "ui" && p.hasSuffix(".html")
            && parts.allSatisfy { match(String($0), "[A-Za-z0-9_][A-Za-z0-9._-]{0,127}") }
    }
    static func match(_ s: String, _ pattern: String) -> Bool { (try? Regex(pattern).wholeMatch(in: s)) != nil }
    static func text(_ s: String, _ what: String, _ len: ClosedRange<Int>) throws(ProtocolError) {
        guard len.contains(s.count), !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw bad("\(what): \(len.lowerBound) a \(len.upperBound) caracteres, sem caracteres de controle")
        }
    }
    static func regularFile(_ u: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.type] as? FileAttributeType) == .typeRegular   // lstat: a link is not
    }
    static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
    /// A decoding error without the JSON text: the key path and what was wrong.
    static func describe(_ e: Error) -> String {
        guard let e = e as? DecodingError else { return "JSON inválido" }
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c): return "falta '\((c.codingPath + [k]).map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "."))'"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "tipo errado em '\(path(c))'"
        case .dataCorrupted(let c): return c.codingPath.isEmpty ? "JSON inválido" : "valor inválido em '\(path(c))'"
        @unknown default: return "JSON inválido"
        }
    }
}

/// One installed external plug-in, as `<root>/plugins/installed.json` keeps it. `error`: why it doesn't load now
/// (recomputed at every load; never a filesystem path).
public struct InstalledPlugin: Codable, Sendable, Equatable {
    public var id: String
    public var version: String
    /// The installed tree's hash (the daemon's `PluginStore.treeHash`), pinned at install, checked at every load.
    public var sha256: String
    public var enabled: Bool
    public var installedAt: Date
    public var error: String?
    public init(id: String, version: String, sha256: String, enabled: Bool, installedAt: Date, error: String? = nil) {
        self.id = id; self.version = version; self.sha256 = sha256; self.enabled = enabled; self.installedAt = installedAt; self.error = error
    }
}
