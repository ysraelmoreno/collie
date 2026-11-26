import Foundation

/// U4: the bait catalog (`docs/fabrica/iscas/catalogo.json`) and the results file (`.collie/factory/bait-results.json`)
/// (spec 2026-11-23-fabrica-para-usuarios-design.md, fabrica/u4-isca.md). Pure and strict like the U1 profile: an unknown
/// field is an error with its path. Running a bait is the `factory-bait` skill's job (a disposable copy); nothing here runs.
public enum FactoryBait {
    public static let catalogPath = "docs/fabrica/iscas/catalogo.json"
    public static let resultsPath = ".collie/factory/bait-results.json"
    public static let maxBaits = 100, maxRuns = 5000, maxText = 300
    /// A week: a run's `costSeconds` above it is refused, so no sum of runs can trap (MAJOR 1).
    public static let maxCost = 86400 * 7

    /// What the bait should trigger: the reviewer's veto, the task's check failing, or a guardrail (tamper, destructive).
    public enum Expect: String, Codable, Sendable, CaseIterable { case veto, checkFail = "check-fail", `guard` }

    public struct Bait: Codable, Sendable, Equatable {
        public var id: String, stack: String, layer: FactoryDoctor.Layer, description: String, patch: String, expect: Expect
        public init(id: String, stack: String, layer: FactoryDoctor.Layer, description: String, patch: String, expect: Expect) {
            self.id = id; self.stack = stack; self.layer = layer; self.description = description; self.patch = patch; self.expect = expect
        }
    }

    public struct Catalog: Codable, Sendable, Equatable {
        public var version = 1
        public var baits: [Bait]
        public init(baits: [Bait]) { self.baits = baits }
    }

    public enum BaitError: Error, Sendable, Equatable {
        case badJSON(String)
        case unknownField(String)
        case missingField(String)
        case wrongType(path: String, expected: String)
        case unsupportedVersion(String)
        case badName(path: String, name: String)
        case duplicate(path: String, value: String)
        case tooMany(path: String, count: Int, limit: Int)
        case badPath(path: String)
        case badChoice(path: String, value: String, allowed: [String])
        case badText(path: String)
        case outOfRange(path: String, value: Int)
        case caughtWithoutLayer(path: String)
        case escapedWithoutLayer(path: String)

        /// One line, in Portuguese, with the path. Values come from the file: whoever shows them cleans them.
        public var message: String {
            switch self {
            case .badJSON(let f): tr("\(f) não é JSON válido", "\(f) is not valid JSON")
            case .unknownField(let p): tr("campo desconhecido '\(p)'", "unknown field '\(p)'")
            case .missingField(let p): tr("falta o campo obrigatório '\(p)'", "required field '\(p)' is missing")
            case .wrongType(let p, let e): tr("'\(p)' precisa ser \(e)", "'\(p)' must be \(e)")
            case .unsupportedVersion(let v): tr("version é \(v); só a version 1 é aceita", "version is \(v); only version 1 is accepted")
            case .badName(let p, let n): tr("nome inválido '\(n)' em '\(p)': use a-z, 0-9 e '-', de 1 a \(ProjectWorkConfig.maxAreaName) caracteres", "invalid name '\(n)' in '\(p)': use a-z, 0-9 and '-', 1 to \(ProjectWorkConfig.maxAreaName) characters")
            case .duplicate(let p, let v): tr("'\(v)' aparece repetido em '\(p)'", "'\(v)' appears twice in '\(p)'")
            case .tooMany(let p, let n, let l): tr("'\(p)' tem \(n) itens; o limite é \(l)", "'\(p)' has \(n) items; the limit is \(l)")
            case .badPath(let p): tr("'\(p)' precisa ser caminho relativo ao repositório (sem '..', sem '/' inicial, sem controle, até \(FactoryProfile.maxBaseline) caracteres)", "'\(p)' must be a path relative to the repository (no '..', no leading '/', no control characters, up to \(FactoryProfile.maxBaseline) characters)")
            case .badChoice(let p, let v, let a): tr("'\(p)' é '\(v)'; use \(a.map { "'\($0)'" }.joined(separator: " ou "))", "'\(p)' is '\(v)'; use \(a.map { "'\($0)'" }.joined(separator: " or "))")
            case .badText(let p): tr("'\(p)' precisa ser texto não vazio de até \(maxText) caracteres, sem controle", "'\(p)' must be non-empty text of up to \(maxText) characters, no control characters")
            case .outOfRange(let p, let v): tr("'\(p)' é \(v); precisa ser inteiro de 0 a \(maxCost)", "'\(p)' is \(v); must be an integer from 0 to \(maxCost)")
            case .caughtWithoutLayer(let p): tr("'\(p)': caught true precisa de layer (a camada que pegou)", "'\(p)': caught true needs a layer (the layer that caught it)")
            case .escapedWithoutLayer(let p): tr("'\(p)': caught false precisa de layer (a camada que devia ter pegado)", "'\(p)': caught false needs a layer (the layer that should have caught it)")
            }
        }
    }

    // MARK: catalog

    public static func parseCatalog(_ data: Data) -> Result<Catalog, BaitError> {
        run {
            let root = try object(try json(data, "catalogo.json"), "", known: ["version", "baits"])
            try version(root)
            var baits: [Bait] = []
            for (i, item) in try list(try required(root, "baits", ""), "baits", limit: maxBaits).enumerated() {
                let p = "baits[\(i)]"
                let o = try object(item, p, known: ["id", "stack", "layer", "description", "patch", "expect"])
                let id = try name(try required(o, "id", p), "\(p).id")
                guard !baits.contains(where: { $0.id == id }) else { throw BaitError.duplicate(path: "baits[].id", value: id) }
                let stack = try name(try required(o, "stack", p), "\(p).stack")   // "any" is a valid name too
                let patch = try string(try required(o, "patch", p), "\(p).patch")
                guard FactoryProfile.confinedPath(patch) else { throw BaitError.badPath(path: "\(p).patch") }
                baits.append(Bait(id: id, stack: stack, layer: try choice(try required(o, "layer", p), "\(p).layer"),
                                  description: try text(try required(o, "description", p), "\(p).description"),
                                  patch: patch, expect: try choice(try required(o, "expect", p), "\(p).expect")))
            }
            return Catalog(baits: baits)
        }
    }

    /// The `list` table: one line per bait.
    public static func text(_ c: Catalog) -> String {
        c.baits.map { "\($0.id)\t\($0.stack)\t\($0.layer.rawValue)\t\($0.expect.rawValue)\t\($0.description)\n" }.joined()
    }

    // MARK: helpers

    private static func run<T>(_ body: () throws -> T) -> Result<T, BaitError> {
        do { return .success(try body()) } catch let e as BaitError { return .failure(e) } catch { return .failure(.badJSON("arquivo")) }
    }
    static func json(_ d: Data, _ file: String) throws -> Any {
        guard let v = try? JSONSerialization.jsonObject(with: d) else { throw BaitError.badJSON(file) }
        return v
    }
    static func version(_ root: [String: Any]) throws {
        guard let v = root["version"] else { throw BaitError.missingField("version") }
        guard let n = v as? NSNumber, !isBool(n) else { throw BaitError.wrongType(path: "version", expected: tr("número", "a number")) }
        guard n.doubleValue == 1 else { throw BaitError.unsupportedVersion(n.stringValue) }
    }
    static func object(_ v: Any, _ path: String, known: Set<String>) throws -> [String: Any] {
        guard let o = v as? [String: Any] else { throw BaitError.wrongType(path: path.isEmpty ? tr("raiz", "root") : path, expected: tr("objeto", "an object")) }
        if let k = o.keys.filter({ !known.contains($0) }).sorted().first { throw BaitError.unknownField(path.isEmpty ? k : "\(path).\(k)") }
        return o
    }
    static func list(_ v: Any, _ path: String, limit: Int) throws -> [Any] {
        guard let a = v as? [Any] else { throw BaitError.wrongType(path: path, expected: tr("lista", "a list")) }
        guard a.count <= limit else { throw BaitError.tooMany(path: path, count: a.count, limit: limit) }
        return a
    }
    static func required(_ o: [String: Any], _ key: String, _ path: String) throws -> Any {
        guard let v = o[key] else { throw BaitError.missingField(path.isEmpty ? key : "\(path).\(key)") }
        return v
    }
    static func string(_ v: Any, _ path: String) throws -> String {
        guard let s = v as? String else { throw BaitError.wrongType(path: path, expected: tr("texto", "text")) }
        return s
    }
    static func name(_ v: Any, _ path: String) throws -> String {
        let s = try string(v, path)
        guard ProjectWorkConfig.validAreaName(s) else { throw BaitError.badName(path: path, name: s) }
        return s
    }
    static func text(_ v: Any, _ path: String) throws -> String {
        let s = try string(v, path)
        guard !s.isEmpty, s.count <= maxText, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw BaitError.badText(path: path) }
        return s
    }
    static func choice<T: RawRepresentable & CaseIterable>(_ v: Any, _ path: String) throws -> T where T.RawValue == String {
        let s = try string(v, path)
        guard let c = T(rawValue: s) else { throw BaitError.badChoice(path: path, value: s, allowed: T.allCases.map(\.rawValue)) }
        return c
    }
    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

/// U4: what the bait runs gave, one entry per run. `layer`: the layer that caught it; on an escaped run (`caught` false), the
/// layer that should have (the catalog's), so `escaped()` needs no catalog. `persona`: the reviewer persona that caught it.
public struct BaitResults: Codable, Sendable, Equatable {
    public struct Run: Codable, Sendable, Equatable {
        public var bait: String, date: String, caught: Bool, layer: FactoryDoctor.Layer?, persona: String?, costSeconds: Int
        public init(bait: String, date: String, caught: Bool, layer: FactoryDoctor.Layer?, persona: String? = nil, costSeconds: Int) {
            self.bait = bait; self.date = date; self.caught = caught; self.layer = layer; self.persona = persona; self.costSeconds = costSeconds
        }
    }
    public struct Rate: Codable, Sendable, Equatable {
        public var caught: Int, total: Int
        public init(caught: Int, total: Int) { self.caught = caught; self.total = total }
        public var text: String { "\(caught)/\(total) (\(total == 0 ? 0 : caught * 100 / total)%)" }
    }

    public var version = 1
    public var runs: [Run]
    public init(runs: [Run] = []) { self.runs = runs }

    public static func parse(_ data: Data) -> Result<BaitResults, FactoryBait.BaitError> {
        typealias F = FactoryBait
        do {
            let root = try F.object(try F.json(data, "bait-results.json"), "", known: ["version", "runs"])
            try F.version(root)
            var out = BaitResults()
            for (i, item) in try F.list(try F.required(root, "runs", ""), "runs", limit: F.maxRuns).enumerated() {
                let p = "runs[\(i)]"
                let o = try F.object(item, p, known: ["bait", "date", "caught", "layer", "persona", "costSeconds"])
                guard let c = try F.required(o, "caught", p) as? NSNumber, F.isBool(c) else { throw F.BaitError.wrongType(path: "\(p).caught", expected: tr("booleano", "a boolean")) }
                let layer: FactoryDoctor.Layer? = try o["layer"].flatMap { $0 is NSNull ? nil : $0 }.map { try F.choice($0, "\(p).layer") }
                let persona = try o["persona"].flatMap { $0 is NSNull ? nil : $0 }.map { try F.name($0, "\(p).persona") }
                guard let n = try F.required(o, "costSeconds", p) as? NSNumber, !F.isBool(n), let cost = Int(exactly: n.doubleValue)
                else { throw F.BaitError.wrongType(path: "\(p).costSeconds", expected: tr("número inteiro", "an integer")) }
                guard cost >= 0, cost <= F.maxCost else { throw F.BaitError.outOfRange(path: "\(p).costSeconds", value: cost) }
                if layer == nil { throw c.boolValue ? F.BaitError.caughtWithoutLayer(path: p) : F.BaitError.escapedWithoutLayer(path: p) }
                out.runs.append(Run(bait: try F.name(try F.required(o, "bait", p), "\(p).bait"), date: try F.text(try F.required(o, "date", p), "\(p).date"),
                                    caught: c.boolValue, layer: layer, persona: persona, costSeconds: cost))
            }
            return .success(out)
        } catch let e as F.BaitError { return .failure(e) } catch { return .failure(.badJSON("bait-results.json")) }
    }

    /// The layers an invalid file hides from the doctor: each run that fails parsed alone names its layer; nothing nameable
    /// (bad JSON, a bad root, a bad layer, too many runs): every layer, since none of them can be credited.
    public static func failingLayers(_ data: Data) -> [FactoryDoctor.Layer] {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let runs = root["runs"] as? [Any] else { return FactoryDoctor.Layer.allCases }
        func fails(_ rs: [Any]) -> Bool {
            root["runs"] = rs
            guard let d = try? JSONSerialization.data(withJSONObject: root) else { return true }
            if case .failure = parse(d) { return true }
            return false
        }
        guard !fails([]) else { return FactoryDoctor.Layer.allCases }
        var out: [FactoryDoctor.Layer] = []
        for run in runs where fails([run]) {
            guard let l = ((run as? [String: Any])?["layer"] as? String).flatMap(FactoryDoctor.Layer.init(rawValue:)) else { return FactoryDoctor.Layer.allCases }
            if !out.contains(l) { out.append(l) }
        }
        return out.isEmpty ? FactoryDoctor.Layer.allCases : FactoryDoctor.Layer.allCases.filter(out.contains)
    }

    /// N4 (round 2): the runs of an invalid file that parse alone (the same isolated parse as `failingLayers`); none when the
    /// root itself is bad.
    public static func validRuns(_ data: Data) -> BaitResults {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let runs = root["runs"] as? [Any] else { return BaitResults() }
        var out = BaitResults()
        for run in runs {
            root["runs"] = [run]
            if let d = try? JSONSerialization.data(withJSONObject: root), case .success(let r) = parse(d) { out.runs += r.runs }
        }
        return out
    }

    /// Every run's cost, saturating at `Int.max`: never traps, even on runs built in code past `maxCost`.
    public var totalCost: Int {
        runs.reduce(0) { s, r in let (v, o) = s.addingReportingOverflow(r.costSeconds); return o ? Int.max : v }
    }

    /// Sorted keys, pretty, a final newline: the same runs always give the same bytes.
    public func render() -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self) + "\n"
    }

    /// Per layer: runs that layer caught over runs that named it (caught by it or escaped past it).
    public func captureRateByLayer() -> [String: Rate] {
        var out: [String: Rate] = [:]
        for r in runs { guard let l = r.layer?.rawValue else { continue }
            out[l, default: Rate(caught: 0, total: 0)].total += 1
            if r.caught { out[l]!.caught += 1 }
        }
        return out
    }

    /// Per persona: runs it caught over the runs of the `review` layer (the only layer a persona works in).
    public func captureRateByPersona() -> [String: Rate] {
        var out: [String: Rate] = [:]
        let total = runs.filter { $0.layer == .review }.count
        for r in runs where r.caught && r.layer == .review { if let p = r.persona { out[p, default: Rate(caught: 0, total: total)].caught += 1 } }
        return out
    }

    /// Per layer: escaped runs, what the doctor (U3) takes.
    public func escaped() -> [String: Int] {
        runs.filter { !$0.caught }.reduce(into: [:]) { m, r in if let l = r.layer?.rawValue { m[l, default: 0] += 1 } }
    }

    public var doctorInput: FactoryDoctor.BaitResults { FactoryDoctor.BaitResults(escapedBaits: escaped()) }

    /// The `report` text: rate per layer and per persona, the baits that got past, total cost.
    public func report() -> String {
        func rows(_ m: [String: Rate]) -> [String] { m.keys.sorted().map { "  \($0): \(m[$0]!.text)" } }
        var lines = [tr("execuções: \(runs.count), custo: \(totalCost) s", "runs: \(runs.count), cost: \(totalCost) s"), tr("por camada:", "by layer:")] + rows(captureRateByLayer())
        lines += [tr("por persona:", "by persona:")] + rows(captureRateByPersona())
        let gone = runs.filter { !$0.caught }
        lines.append(gone.isEmpty ? tr("nenhuma isca passou", "no bait got through") : tr("iscas que passaram:", "baits that got through:"))
        lines += gone.map { "  \($0.bait) (\($0.date), \(tr("camada", "layer")) \($0.layer?.rawValue ?? "?"))" }
        return lines.joined(separator: "\n") + "\n"
    }
}
