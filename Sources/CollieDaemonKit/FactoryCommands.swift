import Foundation
import CollieCore
import CollieProtocol

/// U3: what `factory doctor` reads of a project. Files only, under `WorkConfigFile`'s rules (regular file, never through a
/// symlink, bounded, no `..`, inside the root once resolved); nothing is ever run.
enum FactoryDoctorReader {
    static let maxScripts = 20, maxScriptBytes = 64 * 1024, maxDepth = 4, maxPaths = 5000
    static let skippedDirs: Set<String> = [".git", ".build", "node_modules", ".collie", "DerivedData", ".swiftpm", "Pods"]

    /// The snapshot, or why `collie-work.json` is not used (the same refusals as `work.config`).
    static func snapshot(root: URL) -> Result<FactoryDoctor.Snapshot, ProtocolError> {
        let config: ProjectWorkConfig?
        switch WorkConfigFile.config(root: root) {
        case .failure(let e): return .failure(e)
        case .success(let c): config = c
        }
        let paths = listPaths(root)
        var s = FactoryDoctor.Snapshot(config: config, paths: paths, gitignore: text(root, ".gitignore") ?? "")
        let cmds = [config?.gate, config?.precheck, config?.smoke].compactMap { $0 } + (config?.areas.keys.sorted().compactMap { config?.areas[$0] } ?? [])
        var wanted = cmds.flatMap(FactoryDoctor.citedPaths).filter { !FactoryDoctor.outsideRepo($0) }
        wanted += paths.filter { ($0.split(separator: "/").last ?? "").hasPrefix("check-") && $0.hasSuffix(".sh") }
        var seen: Set<String> = []
        for p in wanted where seen.insert(p).inserted && s.scripts.count < maxScripts {
            if let t = text(root, p) { s.scripts[p] = t }
        }
        for p in paths where isCI(p) && s.ci.count < maxScripts {
            if let t = text(root, p) { s.ci[p] = t }
        }
        return .success(s)
    }

    static func isCI(_ p: String) -> Bool {
        p == "Makefile" || (p.hasPrefix(".github/workflows/") && p.split(separator: "/").count == 3 && (p.hasSuffix(".yml") || p.hasSuffix(".yaml")))
    }

    /// `rel`'s text, cut at 64 KB; nil when it is not a regular file inside the root (a link, a folder, `..`, absent).
    static func text(_ root: URL, _ rel: String) -> String? {
        guard !rel.isEmpty, !FactoryDoctor.outsideRepo(rel) else { return nil }
        let path = root.appendingPathComponent(rel).path
        // a symlinked folder on the way would lead out of the project: the resolved path must stay under the root
        guard ProjectRoot.contains(path, root: root) else { return nil }
        guard case .loaded(let d) = WorkConfigFile.regular(path, name: rel, max: maxScriptBytes, tooLarge: nil) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Repository-relative paths up to `maxDepth`, sorted; symlinks are listed but never followed, build folders skipped.
    static func listPaths(_ root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }   // relative paths; links not followed
        var out: [String] = []
        while let rel = e.nextObject() as? String, out.count < maxPaths {
            let name = (rel as NSString).lastPathComponent
            if skippedDirs.contains(name) { e.skipDescendants(); continue }
            if e.level >= maxDepth { e.skipDescendants() }
            out.append(rel)
        }
        return out.sorted()
    }
}

extension CommandRouter {
    /// `factory.doctor`: the terminal's project's factory, layer by layer (read only; nothing run). `passed` false when
    /// some layer is below `min` (default 1): the CLI exits 1, like any other failed check.
    func factoryDoctor(_ t: TerminalRecord, min: Int) throws(ProtocolError) -> JSONValue {
        let root = ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId })
        let snap: FactoryDoctor.Snapshot
        switch FactoryDoctorReader.snapshot(root: root) {
        case .failure(let e): throw e
        case .success(let s): snap = s
        }
        var r = FactoryDoctor.score(snap)
        for i in r.layers.indices {   // repository text: one line each, nothing hidden
            r.layers[i].evidence = r.layers[i].evidence.map { RerailText.clean($0, max: 300) }
            r.layers[i].nextAction = r.layers[i].nextAction.map { RerailText.clean($0, max: 300) }
        }
        let report = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(r))) ?? .null
        return .object(["output": .string(FactoryDoctor.text(r, min: min)), "report": report,
                        "passed": .bool(r.passes(min: min)), "min": .number(Double(min))])
    }
}
