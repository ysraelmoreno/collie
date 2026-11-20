import Foundation
import CryptoKit

/// A convention the project owner approved: files in `dir` with `ext` (and type `suffix`, nil = all) must follow it.
public struct Fence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case forbidImport = "forbid-import", requireImport = "require-import", requireTest = "require-test"
    }

    public var id: String
    public var kind: Kind
    public var dir: String
    public var suffix: String?
    public var ext: String
    public var module: String?
    public var evidence: String
    /// Files that already break the fence and are tolerated. Only ever shrinks.
    public var baseline: [String]

    public init(kind: Kind, dir: String, suffix: String?, ext: String, module: String?, evidence: String, baseline: [String] = []) {
        self.id = "\(kind.rawValue):\(dir):\(suffix ?? ""):\(module ?? "")"
        self.kind = kind; self.dir = dir; self.suffix = suffix; self.ext = ext
        self.module = module; self.evidence = evidence; self.baseline = baseline
    }

    private enum CodingKeys: String, CodingKey { case id, kind, dir, suffix, ext, module, evidence, baseline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let dir = try c.decode(String.self, forKey: .dir)
        let suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        let module = try c.decodeIfPresent(String.self, forKey: .module)
        self.kind = kind; self.dir = dir; self.suffix = suffix; self.module = module
        ext = try c.decode(String.self, forKey: .ext)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        baseline = try c.decodeIfPresent([String].self, forKey: .baseline) ?? []
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(kind.rawValue):\(dir):\(suffix ?? ""):\(module ?? "")"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(dir, forKey: .dir)
        try c.encode(suffix, forKey: .suffix)   // explicit null: the owner copies the whole object
        try c.encode(ext, forKey: .ext)
        try c.encodeIfPresent(module, forKey: .module)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(baseline, forKey: .baseline)
    }

    /// `*Panel.swift` (or `*.swift` when every file of the folder counts).
    var pattern: String { "*" + (suffix ?? "") + (ext.isEmpty ? "" : "." + ext) }

    func matches(dir d: String, ext e: String, stem: String) -> Bool {
        d == dir && e == ext && (suffix == nil || Vizinho.typeSuffix(stem) == suffix)
    }
}

public struct Violation: Equatable, Sendable {
    public let file: String
    public let fence: Fence
}

public enum Fences {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// A missing or invalid file is "no fences", never an error.
    public static func load(_ url: URL) -> [Fence] {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode([Fence].self, from: d) else { return [] }
        return f
    }

    static func write(_ fences: [Fence], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(fences).write(to: url, options: .atomic)
    }

    /// Every fence that `files` (relative to `project`) breaks. Files in a fence's baseline are tolerated; deleted or unreadable
    /// files are skipped. With `fencesFile`, a baseline file that no longer breaks its fence is dropped from the baseline there
    /// (the ratchet: the only write the plug-in does to that file, and it can only shrink the baseline).
    public static func check(project: URL, files: [String], fences: [Fence], fencesFile: URL? = nil) -> [Violation] {
        let stems = Stems(project)
        var out: [Violation] = []
        var fixed: [String: Set<String>] = [:]
        var seen = Set<String>()
        for file in files where seen.insert(file).inserted {
            guard let p = Vizinho.parse(file), let text = Vizinho.read(project.appendingPathComponent(file)) else { continue }
            for f in fences where f.matches(dir: p.dir, ext: p.ext, stem: p.stem) {
                let broken = isBroken(f, text: text, ext: p.ext, stem: p.stem, stems: stems)
                if f.baseline.contains(file) {
                    if !broken { fixed[f.id, default: []].insert(file) }
                } else if broken {
                    out.append(Violation(file: file, fence: f))
                }
            }
        }
        if let url = fencesFile, !fixed.isEmpty { ratchet(url, fixed) }
        return out
    }

    /// Re-reads the file (the owner may have edited it) and removes only the given baseline entries.
    private static func ratchet(_ url: URL, _ fixed: [String: Set<String>]) {
        var current = load(url)
        var changed = false
        for i in current.indices {
            guard let gone = fixed[current[i].id] else { continue }
            let kept = current[i].baseline.filter { !gone.contains($0) }
            if kept.count != current[i].baseline.count { current[i].baseline = kept; changed = true }
        }
        if changed { try? write(current, to: url) }
    }

    static func isBroken(_ f: Fence, text: String, ext: String, stem: String, stems: Stems) -> Bool {
        switch f.kind {
        case .forbidImport:
            guard let m = f.module else { return false }
            return Vizinho.imports(text, ext: ext).contains(m)
        case .requireImport:
            guard let m = f.module else { return false }
            return !Vizinho.imports(text, ext: ext).contains(m)
        case .requireTest:
            return Vizinho.pairedTest(stem, stems.map) == nil
        }
    }

    /// A sibling that follows the fence (not the file itself, not in the baseline): the example the agent should copy.
    static func model(for v: Violation, project: URL, stems: Stems) -> String? {
        guard let p = Vizinho.parse(v.file) else { return nil }
        let dir = p.dir.isEmpty ? project : project.appendingPathComponent(p.dir, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for n in names.prefix(Vizinho.maxSiblings) where !n.hasPrefix(".") {
            let rel = p.dir.isEmpty ? n : p.dir + "/" + n
            guard rel != v.file, !v.fence.baseline.contains(rel), let q = Vizinho.parse(rel),
                  v.fence.matches(dir: q.dir, ext: q.ext, stem: q.stem),
                  let text = Vizinho.read(project.appendingPathComponent(rel)) else { continue }
            if !isBroken(v.fence, text: text, ext: q.ext, stem: q.stem, stems: stems) { return rel }
        }
        return nil
    }

    /// Text for the agent: at most 5 breaks, 1800 characters.
    static func blockText(_ violations: [Violation], project: URL) -> String {
        let stems = Stems(project)
        var out = "Cerca quebrada (aprovada pelo dono do projeto):"
        for v in violations.prefix(5) {
            let f = v.fence
            let m = f.module ?? ""
            let ratio = counts(f.evidence).map { "\($0.0) de \($0.1)" }
            let ex = model(for: v, project: project, stems: stems).map { " Modelo: \($0)" } ?? ""
            switch f.kind {
            case .forbidImport:
                out += "\n- \(v.file) importa \(m); \(ratio ?? f.evidence) arquivos \(f.pattern) desta pasta importam."
                out += "\n  Causa raiz: o que você precisa de \(m) deve chegar pelo que os irmãos usam.\(ex)"
            case .requireImport:
                out += "\n- \(v.file) não importa \(m); \(ratio ?? f.evidence) arquivos \(f.pattern) desta pasta importam."
                out += "\n  Causa raiz: este arquivo foge da forma dos irmãos; importe \(m) como eles.\(ex)"
            case .requireTest:
                out += "\n- \(v.file) não tem teste par; \(ratio ?? f.evidence) arquivos \(f.pattern) desta pasta têm."
                out += "\n  Causa raiz: falta o teste que os irmãos têm; crie-o antes de encerrar.\(ex)"
            }
        }
        return String(out.prefix(1800))
    }

    /// `"0 de 11 importam X"` → (0, 11).
    private static func counts(_ evidence: String) -> (Int, Int)? {
        let w = evidence.split(separator: " ")
        guard w.count >= 3, w[1] == "de", let n = Int(w[0]), let m = Int(w[2]) else { return nil }
        return (n, m)
    }

    // MARK: data folder

    /// 16 hex of SHA-256 of the real path of the repository root. A worktree (`.git` is a file with
    /// `gitdir: …/.git/worktrees/<n>`) maps to the main repository, so every checkout shares the fences. No `.git`: the project.
    public static func key(project: URL) -> String {
        let real = project.resolvingSymlinksInPath().standardizedFileURL
        // the project or the nearest parent with a `.git` (a terminal may sit in a subfolder); bounded by the path's depth
        var root = real
        var parts = real.pathComponents
        while parts.count > 1 {
            let dir = URL(fileURLWithPath: NSString.path(withComponents: parts), isDirectory: true)
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                root = isDir.boolValue ? dir : (mainRoot(gitFile: git, dir: dir) ?? dir)
                break
            }
            parts.removeLast()
        }
        let digest = SHA256.hash(data: Data(root.resolvingSymlinksInPath().path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func mainRoot(gitFile: URL, dir: URL) -> URL? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        if !path.hasPrefix("/") { path = dir.appendingPathComponent(path).standardizedFileURL.path }
        guard let r = path.range(of: "/.git/worktrees/") else { return nil }
        return URL(fileURLWithPath: String(path[..<r.lowerBound]), isDirectory: true)
    }
}

/// The project's `stem → path` map, built on first use (one walk, shared by every `require-test` fence).
final class Stems {
    private let project: URL
    init(_ project: URL) { self.project = project }
    lazy var map: [String: String] = Vizinho.projectFiles(project)
}
