import Foundation

/// U1: the factory profile, the `factory` key of `collie-work.json` (spec 2026-11-23-fabrica-para-usuarios-design.md).
/// Pure and strict, stricter than `ProjectWorkConfig`: an unknown field at any level of `factory` is an error with its path,
/// never a warning. The old fields (gate, precheck, smoke, areas) stay at the top of the file; the profile does not repeat them.
public struct FactoryProfile: Sendable, Equatable {
    public static let maxArchitecture = 50, maxRatchets = 50, maxScenarios = 100, maxPersonas = 20
    public static let maxDestructive = 50, maxDestructiveText = 200, maxTraps = 200, maxBaseline = 200
    public static let budgetRange = 60...86400, triesRange = 1...10

    public struct Ratchet: Sendable, Equatable {
        public var name: String, measure: String, baseline: String?
        public init(name: String, measure: String, baseline: String? = nil) { self.name = name; self.measure = measure; self.baseline = baseline }
    }
    public struct Scenario: Sendable, Equatable {
        public var area: String, command: String
        public init(area: String, command: String) { self.area = area; self.command = command }
    }
    public enum Threshold: String, Sendable, Equatable, CaseIterable { case blocker, major }
    public enum Land: String, Sendable, Equatable, CaseIterable { case manual, factoryPaddock = "factory-paddock" }

    public var version = 1
    // static
    public var architecture: [String] = [], ratchets: [Ratchet] = []
    // verification
    public var scenarios: [Scenario] = []
    // review
    public var personas: [String] = [], threshold: Threshold = .major, callOwner = false
    // guardrails: nil = the engine's default
    public var budgetSeconds: Int?, maxTries: Int?
    public var destructive: [String] = [], land: Land = .manual
    // prose
    public var traps: [String] = []

    public init() {}

    public enum ProfileError: Error, Sendable, Equatable {
        case unknownField(String)
        case missingField(String)
        case wrongType(path: String, expected: String)
        case unsupportedVersion(String)
        /// A command broke the same rules as the top-level commands; the key inside is the path.
        case badCommand(ProjectWorkConfig.ConfigError)
        case badName(path: String, name: String)
        case duplicate(path: String, value: String)
        case tooMany(path: String, count: Int, limit: Int)
        case badBaseline(path: String)
        case badChoice(path: String, value: String, allowed: [String])
        case outOfRange(path: String, value: Int, range: ClosedRange<Int>)
        case badText(path: String)
        case badTrap(path: String, value: String)

        /// One line, in Portuguese, with the path. Values come from the file: the renderer cleans them.
        public var message: String {
            switch self {
            case .unknownField(let p): "campo desconhecido '\(p)' no perfil de fábrica"
            case .missingField(let p): "falta o campo obrigatório '\(p)' no perfil de fábrica"
            case .wrongType(let p, let e): "'\(p)' precisa ser \(e)"
            case .unsupportedVersion(let v): "factory.version é \(v); só a version 1 é aceita"
            case .badCommand(let e): e.message
            case .badName(let p, let n): "nome inválido '\(n)' em '\(p)': use a-z, 0-9 e '-', de 1 a \(ProjectWorkConfig.maxAreaName) caracteres"
            case .duplicate(let p, let v): "'\(v)' aparece repetido em '\(p)'"
            case .tooMany(let p, let n, let l): "'\(p)' tem \(n) itens; o limite é \(l)"
            case .badBaseline(let p): "'\(p)' precisa ser caminho relativo ao repositório (sem '..', '.', parte vazia, '.git', '.collie' ou 'collie-work.json', sem '/' inicial, sem controle, até \(maxBaseline) caracteres)"
            case .badChoice(let p, let v, let a): "'\(p)' é '\(v)'; use \(a.map { "'\($0)'" }.joined(separator: " ou "))"
            case .outOfRange(let p, let v, let r): "'\(p)' é \(v); precisa ser inteiro de \(r.lowerBound) a \(r.upperBound)"
            case .badText(let p): "'\(p)' precisa ser texto não vazio de até \(maxDestructiveText) caracteres, sem controle"
            case .badTrap(let p, let v): "id de armadilha inválido '\(v)' em '\(p)': use 8 caracteres hexadecimais minúsculos"
            }
        }
    }

    /// Strict parse of the already decoded value of `factory`.
    public static func parse(_ factory: Any) -> Result<FactoryProfile, ProfileError> {
        do { return .success(try read(factory)) } catch let e as ProfileError { return .failure(e) } catch { return .failure(.wrongType(path: "factory", expected: "objeto")) }
    }

    private static func read(_ factory: Any) throws -> FactoryProfile {
        var p = FactoryProfile()
        let f = try object(factory, "factory", known: ["version", "static", "verification", "review", "guardrails", "prose"])
        guard let v = f["version"] else { throw ProfileError.missingField("factory.version") }
        guard let n = v as? NSNumber, !isBool(n) else { throw ProfileError.wrongType(path: "factory.version", expected: "número") }
        guard n.doubleValue == 1 else { throw ProfileError.unsupportedVersion(n.stringValue) }

        if let s = f["static"] {
            let s = try object(s, "factory.static", known: ["architecture", "ratchets"])
            if let a = s["architecture"] {
                p.architecture = try list(a, "factory.static.architecture", limit: maxArchitecture).enumerated().map { i, c in
                    try command(c, "factory.static.architecture[\(i)]")
                }
            }
            if let r = s["ratchets"] {
                let path = "factory.static.ratchets"
                var seen: Set<String> = []
                for (i, item) in try list(r, path, limit: maxRatchets).enumerated() {
                    let ip = "\(path)[\(i)]"
                    let o = try object(item, ip, known: ["name", "measure", "baseline"])
                    let name = try areaName(try required(o, "name", ip), "\(ip).name")
                    guard seen.insert(name).inserted else { throw ProfileError.duplicate(path: "\(path)[].name", value: name) }
                    let measure = try command(try required(o, "measure", ip), "\(ip).measure")
                    p.ratchets.append(Ratchet(name: name, measure: measure, baseline: try o["baseline"].map { try baseline($0, "\(ip).baseline") }))
                }
            }
        }
        if let v = f["verification"] {
            let v = try object(v, "factory.verification", known: ["scenarios"])
            if let s = v["scenarios"] {
                for (i, item) in try list(s, "factory.verification.scenarios", limit: maxScenarios).enumerated() {
                    let ip = "factory.verification.scenarios[\(i)]"
                    let o = try object(item, ip, known: ["area", "command"])
                    p.scenarios.append(Scenario(area: try areaName(try required(o, "area", ip), "\(ip).area"),
                                                command: try command(try required(o, "command", ip), "\(ip).command")))
                }
            }
        }
        if let r = f["review"] {
            let r = try object(r, "factory.review", known: ["personas", "threshold", "callOwner"])
            if let ps = r["personas"] {
                let path = "factory.review.personas"
                for (i, x) in try list(ps, path, limit: maxPersonas).enumerated() {
                    let n = try areaName(x, "\(path)[\(i)]")
                    guard !p.personas.contains(n) else { throw ProfileError.duplicate(path: path, value: n) }
                    p.personas.append(n)
                }
            }
            if let t = r["threshold"] { p.threshold = try choice(t, "factory.review.threshold") }
            if let c = r["callOwner"] {
                guard let b = c as? NSNumber, isBool(b) else { throw ProfileError.wrongType(path: "factory.review.callOwner", expected: "booleano") }
                p.callOwner = b.boolValue
            }
        }
        if let g = f["guardrails"] {
            let g = try object(g, "factory.guardrails", known: ["budgetSeconds", "maxTries", "destructive", "land"])
            if let b = g["budgetSeconds"] { p.budgetSeconds = try integer(b, "factory.guardrails.budgetSeconds", budgetRange) }
            if let t = g["maxTries"] { p.maxTries = try integer(t, "factory.guardrails.maxTries", triesRange) }
            if let d = g["destructive"] {
                p.destructive = try list(d, "factory.guardrails.destructive", limit: maxDestructive).enumerated().map { i, x in
                    let ip = "factory.guardrails.destructive[\(i)]"
                    guard let s = x as? String else { throw ProfileError.wrongType(path: ip, expected: "texto") }
                    // ponytail: empty refused too, an empty pattern would match every command
                    guard !s.isEmpty, s.count <= maxDestructiveText, !hasControl(s) else { throw ProfileError.badText(path: ip) }
                    return s
                }
            }
            if let l = g["land"] { p.land = try choice(l, "factory.guardrails.land") }
        }
        if let pr = f["prose"] {
            let pr = try object(pr, "factory.prose", known: ["traps"])
            if let t = pr["traps"] {
                let path = "factory.prose.traps"
                for (i, x) in try list(t, path, limit: maxTraps).enumerated() {
                    guard let s = x as? String else { throw ProfileError.wrongType(path: "\(path)[\(i)]", expected: "texto") }
                    guard s.unicodeScalars.count == 8, s.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
                    else { throw ProfileError.badTrap(path: "\(path)[\(i)]", value: s) }
                    guard !p.traps.contains(s) else { throw ProfileError.duplicate(path: path, value: s) }
                    p.traps.append(s)
                }
            }
        }
        return p
    }

    private static func object(_ v: Any, _ path: String, known: Set<String>) throws -> [String: Any] {
        guard let o = v as? [String: Any] else { throw ProfileError.wrongType(path: path, expected: "objeto") }
        if let k = o.keys.filter({ !known.contains($0) }).sorted().first { throw ProfileError.unknownField("\(path).\(k)") }
        return o
    }

    private static func list(_ v: Any, _ path: String, limit: Int) throws -> [Any] {
        guard let a = v as? [Any] else { throw ProfileError.wrongType(path: path, expected: "lista") }
        guard a.count <= limit else { throw ProfileError.tooMany(path: path, count: a.count, limit: limit) }
        return a
    }

    private static func required(_ o: [String: Any], _ key: String, _ path: String) throws -> Any {
        guard let v = o[key] else { throw ProfileError.missingField("\(path).\(key)") }
        return v
    }

    private static func command(_ v: Any, _ path: String) throws -> String {
        do { return try ProjectWorkConfig.command(v, key: path) }
        catch let e as ProjectWorkConfig.ConfigError { throw ProfileError.badCommand(e) }
        catch { throw ProfileError.wrongType(path: path, expected: "texto") }
    }

    private static func areaName(_ v: Any, _ path: String) throws -> String {
        guard let s = v as? String else { throw ProfileError.wrongType(path: path, expected: "texto") }
        guard ProjectWorkConfig.validAreaName(s) else { throw ProfileError.badName(path: path, name: s) }
        return s
    }

    private static func baseline(_ v: Any, _ path: String) throws -> String {
        guard let s = v as? String else { throw ProfileError.wrongType(path: path, expected: "texto") }
        guard confinedPath(s) else { throw ProfileError.badBaseline(path: path) }
        return s
    }

    /// A repository-relative path: not empty, at most `maxBaseline` characters, no leading '/', no control, and no component
    /// that is empty, `.`, `..`, `.git` or ends in `.git` (a nested repo's config runs `core.fsmonitor` outside the sandbox),
    /// `.collie` or `collie-work.json` (the daemon writes there unsandboxed). Case-insensitive: the default macOS volume is.
    /// U4's bait catalog and `FactoryRatchet.target` use the same rule.
    public static func confinedPath(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxBaseline, !s.hasPrefix("/"), !hasControl(s) else { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { c in
            let l = c.lowercased()
            return !l.isEmpty && l != "." && l != ".." && !l.hasSuffix(".git") && l != ".collie" && l != "collie-work.json"
        }
    }

    private static func choice<T: RawRepresentable & CaseIterable>(_ v: Any, _ path: String) throws -> T where T.RawValue == String {
        guard let s = v as? String else { throw ProfileError.wrongType(path: path, expected: "texto") }
        guard let c = T(rawValue: s) else { throw ProfileError.badChoice(path: path, value: s, allowed: T.allCases.map(\.rawValue)) }
        return c
    }

    private static func integer(_ v: Any, _ path: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let n = v as? NSNumber, !isBool(n), let i = Int(exactly: n.doubleValue) else { throw ProfileError.wrongType(path: path, expected: "número inteiro") }
        guard range.contains(i) else { throw ProfileError.outOfRange(path: path, value: i, range: range) }
        return i
    }

    private static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}
