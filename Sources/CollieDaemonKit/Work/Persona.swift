import Foundation
import CollieCore

/// R5: one review persona (docs/fabrica/personas/<name>.md). `body` is what the reviewer receives, verbatim.
/// Pure: the texts come from the caller, who reads them from the attempt's BASE commit, never from the worktree,
/// so the agent being judged cannot change who judges it in the same attempt.
struct Persona: Sendable, Equatable {
    var name: String
    var model: String?
    /// Globs over repo-relative paths: `**` crosses `/`, `*` and `?` do not.
    var paths: [String]
    var body: String
}

enum PersonaError: Error, Equatable, CustomStringConvertible {
    case malformed(file: String, reason: String)
    case unknown(name: String)

    var description: String {
        switch self {
        case let .malformed(file, reason): "persona \(file): \(reason)"
        case let .unknown(name): tr("persona '\(name)' não está no catálogo", "persona '\(name)' is not in the catalog")
        }
    }
}

enum PersonaCatalog {
    /// `files`: file name → text. Refuses the whole catalog on the first malformed file (a half catalog would judge less
    /// than the owner wrote). Result sorted by name, so the order never depends on the dictionary.
    static func parse(files: [String: String]) throws -> [Persona] {
        var seen = Set<String>()
        return try files.keys.sorted().map { file in
            let persona = try parse(file: file, text: files[file] ?? "")
            guard seen.insert(persona.name).inserted else {
                throw PersonaError.malformed(file: file, reason: tr("nome '\(persona.name)' repetido", "name '\(persona.name)' repeated"))
            }
            return persona
        }.sorted { $0.name < $1.name }
    }

    static func parse(file: String, text: String) throws -> Persona {
        func bad(_ reason: String) -> PersonaError { .malformed(file: file, reason: reason) }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { throw bad(tr("falta o front-matter (--- na 1ª linha)", "missing front matter (--- on line 1)")) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw bad(tr("front-matter sem o --- de fechamento", "front matter without the closing ---"))
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw bad(tr("linha sem 'chave: valor': \(line)", "line without 'key: value': \(line)")) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard ["name", "model", "paths"].contains(key) else { throw bad(tr("chave desconhecida '\(key)'", "unknown key '\(key)'")) }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"], !name.isEmpty else { throw bad(tr("falta 'name'", "missing 'name'")) }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { throw bad(tr("'name' inválido: \(name)", "invalid 'name': \(name)")) }
        guard let rawPaths = fields["paths"] else { throw bad(tr("falta 'paths'", "missing 'paths'")) }
        guard let paths = try? JSONDecoder().decode([String].self, from: Data(rawPaths.utf8)), !paths.isEmpty else {
            throw bad(tr("'paths' deve ser um array JSON de globs não vazio", "'paths' must be a non-empty JSON array of globs"))
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw bad(tr("corpo vazio", "empty body")) }
        let model = fields["model"].flatMap { $0.isEmpty ? nil : $0 }
        return Persona(name: name, model: model, paths: paths, body: body)
    }
}

/// R5: which personas review a diff. Rules (F2): `correcao` always; `simplicidade` when the diff passes 150 lines;
/// `motor-concorrencia` also when the added code uses async/await/Task; `seguranca` also when the diff touches
/// `docs/fabrica/personas/**` or a spec of the work's tasks (F2 X4: what judges the next attempts); every other persona
/// (and motor, seguranca) by its globs.
struct PersonaRouter: Sendable {
    static let always = "correcao"
    static let bigDiff = "simplicidade"
    static let concurrency = "motor-concorrencia"
    static let security = "seguranca"
    static let personasGlob = "docs/fabrica/personas/**"
    static let bigDiffLines = 150
    /// Most specific first: `max` keeps the head of this list. Personas outside it come after, by name.
    static let specificity = ["correcao", "seguranca", "motor-concorrencia", "testes", "simplicidade"]

    var catalog: [Persona]

    /// `diffText`: the diff itself, only read for the async/await/Task rule. `requested` (the task's explicit list)
    /// wins over the rules but must name catalog personas; `correcao` is never cut, by either path.
    /// `specs`: the repo-relative spec paths of the work's tasks. A1 `only` (`factory.review.personas`): the "auto"
    /// choice keeps only these names (an explicit `requested` wins over it); `correcao` still stays, and so does `seguranca`
    /// when the X4 rule calls it (B1).
    func select(changedPaths: [String], diffLines: Int, diffText: String = "", requested: [String]? = nil,
                max: Int = 4, specs: [String] = [], only: [String]? = nil) throws -> [Persona] {
        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var names: Set<String>
        if let requested {
            if let unknown = requested.first(where: { byName[$0] == nil }) { throw PersonaError.unknown(name: unknown) }
            names = Set(requested)
        } else {
            // B1: X4 (what judges the next attempts) keeps `seguranca` past `only`, as `correcao` is kept
            let x4 = Self.matches([Self.personasGlob], any: changedPaths) || changedPaths.contains { specs.contains($0) }
            names = Set(catalog.filter { persona in
                switch persona.name {
                case Self.always: true
                case Self.bigDiff: diffLines > Self.bigDiffLines
                case Self.concurrency: Self.usesConcurrency(diffText) || Self.matches(persona.paths, any: changedPaths)
                case Self.security: x4 || Self.matches(persona.paths, any: changedPaths)
                default: Self.matches(persona.paths, any: changedPaths)
                }
            }.map(\.name))
            if let only, !only.isEmpty { names.formIntersection(only) }
            if x4, byName[Self.security] != nil { names.insert(Self.security) }
        }
        if byName[Self.always] != nil { names.insert(Self.always) }
        let ordered = names.sorted { Self.rank($0) == Self.rank($1) ? $0 < $1 : Self.rank($0) < Self.rank($1) }
        return ordered.prefix(Swift.max(max, 1)).compactMap { byName[$0] }
    }

    static func rank(_ name: String) -> Int { specificity.firstIndex(of: name) ?? specificity.count }

    static func matches(_ globs: [String], any paths: [String]) -> Bool {
        globs.contains { glob in paths.contains { matches(glob: glob, path: $0) } }
    }

    static func matches(glob: String, path: String) -> Bool {
        var pattern = "^"
        var chars = Array(glob)[...]
        while let c = chars.popFirst() {
            switch c {
            case "*" where chars.first == "*":
                chars.removeFirst()
                pattern += ".*"
            case "*": pattern += "[^/]*"
            case "?": pattern += "[^/]"
            default: pattern += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return path.range(of: pattern + "$", options: .regularExpression) != nil
    }

    /// Added lines (`+`, not the `+++` header) that use Swift concurrency.
    static func usesConcurrency(_ diff: String) -> Bool {
        diff.split(separator: "\n").contains { line in
            line.hasPrefix("+") && !line.hasPrefix("+++")
                && line.range(of: #"\b(async|await)\b|\bTask(Group)?\b"#, options: .regularExpression) != nil
        }
    }
}
