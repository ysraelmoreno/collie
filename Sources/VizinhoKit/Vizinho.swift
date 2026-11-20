import Foundation

/// Guidance for a freshly written file, inferred from its sibling files (same folder, extension and "type" suffix).
/// Foundation only: no Collie module, no LLM, no configuration.
public enum Vizinho {
    static let minSiblings = 3
    static let maxSiblings = 200
    static let maxFileBytes = 256 * 1024
    static let maxGuideChars = 1200
    static let maxRespondFiles = 3
    static let maxRespondChars = 2000
    static let ignoredDirs: Set<String> = [".git", ".build", "node_modules", "build", "dist", "DerivedData"]
    static let maxWalk = 50_000

    // MARK: API

    public static func guide(project: URL, file: String) -> String? {
        let parts = file.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !file.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains("."),
              !parts.dropLast().contains(where: ignoredDirs.contains) else { return nil }
        let name = parts[parts.count - 1]
        let dirRel = parts.dropLast().joined(separator: "/")
        let dir = dirRel.isEmpty ? project : project.appendingPathComponent(dirRel, isDirectory: true)
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = typeSuffix(stem)
        guard let mine = read(project.appendingPathComponent(file)) else { return nil }

        // ponytail: siblings sorted by name, first 200 win; no recency or similarity ranking.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var siblings: [(path: String, stem: String, text: String)] = []
        var total = 0
        for n in names where n != name && !n.hasPrefix(".") && (n as NSString).pathExtension == ext {
            let s = ext.isEmpty ? n : String(n.dropLast(ext.count + 1))
            guard suffix == nil || typeSuffix(s) == suffix else { continue }
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            total += 1
            if total > maxSiblings { break }
            if let t = read(url) { siblings.append((dirRel.isEmpty ? n : dirRel + "/" + n, s, t)) }
        }
        let m = siblings.count
        guard m >= minSiblings else { return nil }

        var lines: [String] = []
        let sets = siblings.map { imports($0.text, ext: ext) }
        let mineSet = imports(mine, ext: ext)
        do {
            var counts: [String: Int] = [:]
            for s in sets { for i in s { counts[i, default: 0] += 1 } }
            let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            for (i, c) in ranked where c * 5 >= m * 4 && !mineSet.contains(i) {
                lines.append("- \(c) de \(m) importam \(i); este não importa")
            }
            if m >= 5 {
                for i in mineSet.sorted() where counts[i] == nil {
                    lines.append("- 0 de \(m) importam \(i); este importa")
                }
            }
        }

        // paired test file, anywhere in the project
        let stems = projectFiles(project)
        func pair(_ s: String) -> String? {
            for c in [s + "Tests", s + "Test", s + ".test", s + "_test"] { if let p = stems[c] { return p } }
            return nil
        }
        let paired = siblings.compactMap { pair($0.stem) }
        if paired.count * 5 >= m * 4, pair(stem) == nil, let ex = paired.first {
            lines.append("- \(paired.count) de \(m) têm teste (ex.: \(ex)); este não tem")
        }
        guard !lines.isEmpty else { return nil }

        let pattern = "*" + (suffix ?? "") + (ext.isEmpty ? "" : "." + ext)
        var out = "\(file): \(m) arquivos \(pattern) nesta pasta seguem a mesma forma.\n"
        out += "Modelo: \(model(siblings.map { ($0.path, $0.text) }, sets: sets, majority: m))\n"
        out += lines.joined(separator: "\n")
        return String(out.prefix(maxGuideChars))
    }

    /// `{event, project, files}` in, `{"guide": …}` or `{}` out. Never throws: bad input is `{}`.
    public static func respond(eventJSON: Data) -> Data {
        let empty = Data("{}".utf8)
        guard let o = try? JSONSerialization.jsonObject(with: eventJSON) as? [String: Any],
              o["event"] as? String == "edit", let project = o["project"] as? String,
              let files = o["files"] as? [String] else { return empty }
        let root = URL(fileURLWithPath: project, isDirectory: true)
        let text = files.prefix(maxRespondFiles).compactMap { guide(project: root, file: $0) }
            .joined(separator: "\n\n")
        guard !text.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["guide": String(text.prefix(maxRespondChars))])
        else { return empty }
        return data
    }

    // MARK: pieces

    /// Last CamelCase word (`FooPanel` → `Panel`) or dotted suffix (`foo.test` → `.test`); nil when neither.
    static func typeSuffix(_ stem: String) -> String? {
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex, stem.index(after: dot) != stem.endIndex {
            return String(stem[dot...])
        }
        var start = stem.startIndex
        for i in stem.indices where i != stem.startIndex && stem[i].isUppercase && !stem[stem.index(before: i)].isUppercase {
            start = i
        }
        guard start != stem.startIndex, stem[start...].allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(stem[start...])
    }

    static func read(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: maxFileBytes) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// One pass over the project: file stem → relative path of the first (sorted) file with it.
    static func projectFiles(_ project: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let en = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return out }
        let base = project.standardizedFileURL.path + "/"
        var seen = 0
        var found: [(String, String)] = []
        for case let url as URL in en {
            seen += 1
            if seen > maxWalk { break }
            if ignoredDirs.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let n = url.deletingPathExtension().lastPathComponent
            found.append((n, String(p.dropFirst(base.count))))
        }
        for (n, p) in found.sorted(by: { $0.1 < $1.1 }) where out[n] == nil { out[n] = p }
        return out
    }

    /// The sibling with every import the majority (>50%) has; ties go to the median size. Never "closest by name".
    static func model(_ files: [(String, String)], sets: [Set<String>], majority m: Int) -> String {
        var counts: [String: Int] = [:]
        for s in sets { for i in s { counts[i, default: 0] += 1 } }
        let common = Set(counts.filter { $0.value * 2 > m }.keys)
        var cands = files.indices.filter { common.isSubset(of: sets[$0]) }
        if cands.isEmpty { cands = Array(files.indices) }
        cands.sort { (files[$0].1.utf8.count, files[$0].0) < (files[$1].1.utf8.count, files[$1].0) }
        return files[cands[cands.count / 2]].0
    }

    // MARK: imports (line based; ponytail: no multi-line string or comment awareness)

    static func imports(_ text: String, ext: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch ext {
            case "swift": if let m = swiftImport(line) { out.insert(m) }
            case "ts", "tsx", "js", "jsx", "mjs", "cjs": if let m = jsImport(line) { out.insert(m) }
            case "py": out.formUnion(pyImports(line))
            case "kt", "java": if let m = jvmImport(line) { out.insert(m) }
            default: return []
            }
        }
        return out
    }

    private static func swiftImport(_ line: String) -> String? {
        var t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let skip: Set<String> = ["public", "internal", "package", "private", "fileprivate"]
        while let f = t.first, f.hasPrefix("@") || skip.contains(f) { t.removeFirst() }
        guard t.first == "import", t.count > 1 else { return nil }
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
        let i = kinds.contains(t[1]) && t.count > 2 ? 2 : 1
        let mod = t[i].split(separator: ".").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        return mod?.isEmpty == false ? mod : nil
    }

    private static func jsImport(_ line: String) -> String? {
        guard line.hasPrefix("import") || line.hasPrefix("} from") || line.contains("require(") else { return nil }
        guard let q = line.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "`" }) else { return nil }
        let rest = line[line.index(after: q)...]
        guard let e = rest.firstIndex(of: line[q]) else { return nil }
        let s = String(rest[..<e])
        return s.isEmpty ? nil : s
    }

    private static func pyImports(_ line: String) -> [String] {
        if line.hasPrefix("from ") {
            let m = line.dropFirst(5).split(separator: " ").first.map(String.init)
            return m.map { [$0] } ?? []
        }
        guard line.hasPrefix("import ") else { return [] }
        return line.dropFirst(7).split(separator: ",").compactMap {
            $0.split(separator: " ").first.map(String.init)
        }
    }

    private static func jvmImport(_ line: String) -> String? {
        guard line.hasPrefix("import ") else { return nil }
        var t = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("static ") { t = String(t.dropFirst(7)) }
        let m = t.split(whereSeparator: { $0 == ";" || $0 == " " }).first.map(String.init)
        return m?.isEmpty == false ? m : nil
    }
}
