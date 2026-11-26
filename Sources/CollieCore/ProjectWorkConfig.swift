import Foundation

/// M13.1: a project's `collie-work.json` (onda13.md): what the loop knows of the project without the engine knowing it.
/// Pure: parses bytes, never reads a file and never runs a command. Strict, unlike `WorkArchive`: a wrong type, a
/// `version` other than 1 or a command out of bounds is an error; only an unknown top-level key is let through, as a
/// warning. The file is repository content (an agent may write it): whoever shows a value cleans it.
public struct ProjectWorkConfig: Sendable, Equatable {
    public static let maxBytes = 16 * 1024, maxCommand = 1000, maxAreas = 50, maxAreaName = 40
    public static let fileName = "collie-work.json"

    public var gate: String?, precheck: String?, smoke: String?, full: String?
    /// Area name (`a-z0-9-`, 1...40) → its command.
    public var areas: [String: String]
    /// U1: the `factory` key, read strictly by `FactoryProfile`; nil when the file has none.
    public var factory: FactoryProfile?
    /// F1: the `fields` key (a summoned agent in its own worktree); nil when the file has none.
    public var fields: FieldsConfig?

    public struct FieldsConfig: Sendable, Equatable {
        /// `summon` without a flag uses a field.
        public var `default`: Bool
        /// Live fields per paddock.
        public var max: Int
        public static let maxRange = 1...8
        public init(default: Bool = false, max: Int = 4) { self.default = `default`; self.max = max }
    }

    public init(gate: String? = nil, precheck: String? = nil, smoke: String? = nil, full: String? = nil, areas: [String: String] = [:]) {
        self.gate = gate; self.precheck = precheck; self.smoke = smoke; self.full = full; self.areas = areas
    }

    public enum ConfigError: Error, Sendable, Equatable {
        case tooLarge(Int), notJSON, notObject
        case wrongType(key: String, expected: String)
        /// The `version` as the file wrote it.
        case unsupportedVersion(String)
        case commandTooLong(key: String, length: Int)
        case controlCharacter(key: String)
        case emptyCommand(key: String)
        /// A command of an area or of `smoke` is chained with `&&`: `;`, `||`, `#` or a lone `&` would change what the chain means.
        case notChainable(key: String, token: String)
        case badAreaName(String)
        case tooManyAreas(Int)
        case unknownArea(String, available: [String])
        case noAreas
        /// U1: the `factory` key is there and wrong.
        indirect case invalidFactory(FactoryProfile.ProfileError)
        /// F1: `fields.max` out of `FieldsConfig.maxRange`.
        case fieldsMax(Int)

        /// One line, in words. Names and keys come from the file: the renderer cleans them.
        public var message: String {
            switch self {
            case .tooLarge(let n): tr("collie-work.json tem \(n) bytes; o limite é 16 KB", "collie-work.json is \(n) bytes; the limit is 16 KB")
            case .notJSON: tr("collie-work.json não é JSON válido", "collie-work.json is not valid JSON")
            case .notObject: tr("collie-work.json precisa ser um objeto JSON ({ ... })", "collie-work.json must be a JSON object ({ ... })")
            case .wrongType(let k, let e): tr("'\(k)' em collie-work.json precisa ser \(e)", "'\(k)' in collie-work.json must be \(e)")
            case .unsupportedVersion(let v): tr("collie-work.json tem version \(v); só a version 1 é aceita", "collie-work.json has version \(v); only version 1 is accepted")
            case .commandTooLong(let k, let n): tr("o comando '\(k)' tem \(n) caracteres; o limite é \(maxCommand)", "the command '\(k)' has \(n) characters; the limit is \(maxCommand)")
            case .controlCharacter(let k): tr("o comando '\(k)' tem caractere de controle (quebra de linha, tab, NUL...)", "the command '\(k)' has a control character (line break, tab, NUL...)")
            case .emptyCommand(let k): tr("o comando '\(k)' está vazio", "the command '\(k)' is empty")
            case .notChainable(let k, let t): tr("o comando '\(k)' tem '\(t)', que muda o sentido do check montado (área && smoke); ponha isso num script do projeto e chame o script", "the command '\(k)' has '\(t)', which changes the meaning of the assembled check (area && smoke); put that in a project script and call the script")
            case .badAreaName(let n): tr("nome de área inválido '\(n)': use a-z, 0-9 e '-', de 1 a \(maxAreaName) caracteres", "invalid area name '\(n)': use a-z, 0-9 and '-', 1 to \(maxAreaName) characters")
            case .tooManyAreas(let n): tr("collie-work.json tem \(n) áreas; o limite é \(maxAreas)", "collie-work.json has \(n) areas; the limit is \(maxAreas)")
            case .unknownArea(let n, let all):
                tr("área '\(n)' não existe em collie-work.json; ", "area '\(n)' does not exist in collie-work.json; ") + (all.isEmpty ? tr("o arquivo não define nenhuma área", "the file defines no areas") : tr("existem: \(all.joined(separator: ", "))", "available: \(all.joined(separator: ", "))"))
            case .noAreas: tr("nenhuma área pedida", "no area requested")
            case .invalidFactory(let e): e.message
            case .fieldsMax(let n): tr("'fields.max' em collie-work.json é \(n); use de \(FieldsConfig.maxRange.lowerBound) a \(FieldsConfig.maxRange.upperBound)", "'fields.max' in collie-work.json is \(n); use \(FieldsConfig.maxRange.lowerBound) to \(FieldsConfig.maxRange.upperBound)")
            }
        }
    }

    private static let commandKeys = ["gate", "precheck", "smoke", "full"]

    /// Strict parse of the file's bytes. Warnings: one per unknown top-level key, sorted.
    public static func parse(_ data: Data) -> Result<(config: ProjectWorkConfig, warnings: [String]), ConfigError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge(data.count)) }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let o = any as? [String: Any] else { return .failure(.notObject) }
        var c = ProjectWorkConfig(), warnings: [String] = []
        do {
            if let v = o["version"] {
                guard let n = v as? NSNumber, !isBool(n) else { throw ConfigError.wrongType(key: "version", expected: tr("número", "a number")) }
                guard n.doubleValue == 1 else { throw ConfigError.unsupportedVersion(n.stringValue) }
            }
            for k in commandKeys {
                guard let v = o[k] else { continue }
                let cmd = try command(v, key: k)
                switch k {
                case "gate": c.gate = cmd
                case "precheck": c.precheck = cmd
                case "smoke": try Self.requireChainable(cmd, key: k); c.smoke = cmd
                default: c.full = cmd
                }
            }
            if let v = o["areas"] {
                guard let a = v as? [String: Any] else { throw ConfigError.wrongType(key: "areas", expected: tr("objeto", "an object")) }
                guard a.count <= maxAreas else { throw ConfigError.tooManyAreas(a.count) }
                for name in a.keys.sorted() {
                    guard validAreaName(name) else { throw ConfigError.badAreaName(name) }
                    let cmd = try command(a[name] as Any, key: "areas.\(name)")
                    try Self.requireChainable(cmd, key: "areas.\(name)")
                    c.areas[name] = cmd
                }
            }
            if let f = o["factory"] {
                switch FactoryProfile.parse(f) {
                case .success(let p): c.factory = p
                case .failure(let e): throw ConfigError.invalidFactory(e)
                }
            }
            if let v = o["fields"] {
                guard let f = v as? [String: Any] else { throw ConfigError.wrongType(key: "fields", expected: tr("objeto", "an object")) }
                var fc = FieldsConfig()
                if let d = f["default"] {
                    guard let n = d as? NSNumber, isBool(n) else { throw ConfigError.wrongType(key: "fields.default", expected: tr("true ou false", "true or false")) }
                    fc.default = n.boolValue
                }
                if let m = f["max"] {
                    guard let n = m as? NSNumber, !isBool(n), n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e9
                    else { throw ConfigError.wrongType(key: "fields.max", expected: tr("número inteiro", "an integer")) }
                    guard FieldsConfig.maxRange.contains(n.intValue) else { throw ConfigError.fieldsMax(n.intValue) }
                    fc.max = n.intValue
                }
                c.fields = fc
                warnings += f.keys.filter { $0 != "default" && $0 != "max" }.sorted().map { tr("chave desconhecida ignorada: fields.\($0)", "unknown key ignored: fields.\($0)") }
            }
        } catch let e as ConfigError { return .failure(e) }
        catch { return .failure(.notJSON) }
        let known = Set(commandKeys + ["version", "areas", "factory", "fields"])
        warnings = o.keys.filter { !known.contains($0) }.sorted().map { tr("chave desconhecida ignorada: \($0)", "unknown key ignored: \($0)") } + warnings
        return .success((c, warnings))
    }

    /// `;`, `||`, `#` or a lone `&` in a command that is joined with `&&` would let a failure pass or hide the rest of the chain.
    static func requireChainable(_ cmd: String, key: String) throws(ConfigError) {
        let chars = Array(cmd)
        for (i, ch) in chars.enumerated() {
            let token: String? = switch ch {
            case ";": ";"
            case "#": "#"
            case "|": (i + 1 < chars.count && chars[i + 1] == "|") || (i > 0 && chars[i - 1] == "|") ? "||" : nil
            case "&": (i + 1 < chars.count && chars[i + 1] == "&") || (i > 0 && chars[i - 1] == "&") ? nil : "&"
            default: nil
            }
            if let token { throw .notChainable(key: key, token: token) }
        }
    }

    /// `<area 1> && <area 2> && <smoke>`, areas in the order asked (a repeated one once); no `smoke`: nothing added.
    public func composeCheck(areas names: [String]) -> Result<String, ConfigError> {
        guard !names.isEmpty else { return .failure(.noAreas) }
        var seen: Set<String> = [], parts: [String] = []
        for n in names where seen.insert(n).inserted {
            guard let cmd = areas[n] else { return .failure(.unknownArea(n, available: areas.keys.sorted())) }
            parts.append(cmd)
        }
        if let smoke { parts.append(smoke) }
        return .success(parts.joined(separator: " && "))
    }

    public static func validAreaName(_ n: String) -> Bool {
        (1...maxAreaName).contains(n.unicodeScalars.count)
            && n.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func command(_ v: Any, key: String) throws(ConfigError) -> String {
        guard let s = v as? String else { throw .wrongType(key: key, expected: tr("texto", "text")) }
        guard s.count <= maxCommand else { throw .commandTooLong(key: key, length: s.count) }
        // control (newline, tab, NUL, DEL, C1) and format characters (bidi overrides, zero-width): what runs is what shows
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
        else { throw .controlCharacter(key: key) }
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyCommand(key: key) }
        return s
    }

    /// JSONSerialization gives `true` as an NSNumber too.
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}
