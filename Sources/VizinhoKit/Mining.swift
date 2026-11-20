import Foundation

/// Finds conventions nearly every file of a group follows (group = folder + extension + type suffix) and proposes them
/// as fences. Proposals only: the owner decides which ones become `cercas.json`.
public enum Mining {
    static let minGroup = 10
    static let maxProposals = 50
    static let maxFiles = 5000
    static let minOutside = 10

    private struct Group { var dir: String; var ext: String; var suffix: String?; var paths: [String] }

    public static func propose(project: URL, budget: TimeInterval = 3) -> [Fence] {
        let deadline = Date().addingTimeInterval(budget)
        let all = Vizinho.walk(project, limit: maxFiles, deadline: deadline)
        let stems = Vizinho.stems(of: all)

        // names that exist in the project (folders and file stems): a module is "ours" when one of them matches
        var names = Set(stems.keys)
        for p in all { for part in p.split(separator: "/").dropLast() { names.insert(String(part)) } }

        // imports of every file, until the deadline; a file not reached is left out of every group
        var imports: [String: Set<String>] = [:]
        var global: [String: Int] = [:]
        var perDir: [String: [String: Int]] = [:]
        var scanned: [String] = []
        for p in all {
            if Date() > deadline { break }
            scanned.append(p)
            guard let f = Vizinho.parse(p), Vizinho.importExts.contains(f.ext),
                  let text = Vizinho.read(project.appendingPathComponent(p)) else { continue }
            let set = Vizinho.imports(text, ext: f.ext)
            imports[p] = set
            for m in set { global[m, default: 0] += 1; perDir[f.dir, default: [:]][m, default: 0] += 1 }
        }

        var groups: [String: Group] = [:]
        for p in scanned {
            guard let f = Vizinho.parse(p), !f.ext.isEmpty else { continue }
            if let s = Vizinho.typeSuffix(f.stem) {
                groups["\(f.dir)\0\(f.ext)\0\(s)", default: Group(dir: f.dir, ext: f.ext, suffix: s, paths: [])].paths.append(p)
            }
            groups["\(f.dir)\0\(f.ext)\0", default: Group(dir: f.dir, ext: f.ext, suffix: nil, paths: [])].paths.append(p)
        }
        // the "whole folder" group is dropped when one suffix group already covers the same files
        let sizes = Dictionary(groups.values.filter { $0.suffix != nil }.map { ("\($0.dir)\0\($0.ext)\0\($0.paths.count)", 1) },
                               uniquingKeysWith: { a, _ in a })

        var found: [(size: Int, fence: Fence)] = []
        for g in groups.values where g.paths.count >= minGroup {
            if g.suffix == nil, sizes["\(g.dir)\0\(g.ext)\0\(g.paths.count)"] != nil { continue }
            let n = g.paths.count
            let paths = g.paths.sorted()
            func add(_ kind: Fence.Kind, _ module: String?, _ evidence: String, _ baseline: [String]) {
                found.append((n, Fence(kind: kind, dir: g.dir, suffix: g.suffix, ext: g.ext, module: module,
                                       evidence: evidence, baseline: baseline)))
            }

            let paired = Set(paths.filter { p in Vizinho.parse(p).map { Vizinho.pairedTest($0.stem, stems) != nil } ?? false })
            if paired.count * 100 >= n * Vizinho.importPct {
                add(.requireTest, nil, "\(paired.count) de \(n) têm teste par", paths.filter { !paired.contains($0) })
            }

            guard Vizinho.importExts.contains(g.ext) else { continue }
            var counts: [String: Int] = [:]
            for p in paths { for m in imports[p] ?? [] { counts[m, default: 0] += 1 } }
            for (m, c) in counts where c * 100 >= n * Vizinho.importPct {
                add(.requireImport, m, "\(c) de \(n) importam \(m)", paths.filter { !(imports[$0]?.contains(m) ?? false) })
            }
            for (m, total) in global where counts[m] == nil && names.contains(m)
                && total - (perDir[g.dir]?[m] ?? 0) >= minOutside {
                add(.forbidImport, m, "0 de \(n) importam \(m)", [])
            }
        }
        found.sort { $0.size != $1.size ? $0.size > $1.size : $0.fence.id < $1.fence.id }
        return found.prefix(maxProposals).map(\.fence)
    }
}
