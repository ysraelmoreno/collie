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

/// U5: `collie factory ratchet <check|update|raise> <name>`: the profile's ratchet measured once and compared with its baseline
/// file. The file is confined to the project (no `..`, not absolute, never through a symlink) and written atomically.
enum FactoryRatchet {
    enum Action: String, Sendable { case check, update, raise }
    struct Outcome: Sendable, Equatable { var output: String, passed: Bool, wrote: Bool }
    static let maxBaselineBytes = 1 << 20
    static let measureTimeout: Duration = .seconds(600)

    /// The baseline's URL, or why it is refused: relative, no `..`, its folder existing inside the root, not a link.
    static func target(root: URL, rel: String) throws(ProtocolError) -> URL {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !parts.contains(".."), !parts.contains(""), !FactoryDoctor.outsideRepo(rel)
        else { throw ProtocolError(code: .invalidArgs, message: "baseline '\(rel)' fora do projeto") }
        let url = root.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        let dir = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
        else { throw ProtocolError(code: .invalidArgs, message: "a pasta do baseline '\(rel)' não existe") }
        guard ProjectRoot.contains(dir, root: root) else { throw ProtocolError(code: .invalidArgs, message: "baseline '\(rel)' fora do projeto") }
        return url
    }

    /// The file's text; "" when absent (a first baseline). A link, a folder or a big file is refused.
    static func read(_ url: URL, name: String) throws(ProtocolError) -> String {
        switch WorkConfigFile.regular(url.path, name: name, max: maxBaselineBytes, tooLarge: { "\(name) passa de \($0) bytes" }) {
        case .absent: return ""
        case .loaded(let d): return String(decoding: d, as: UTF8.self)
        case .refused(let m): throw ProtocolError(code: .invalidArgs, message: m)
        }
    }

    /// Temporary file in the same folder, then `rename`: a reader sees the old file or the new one, never half.
    static func write(_ text: String, to url: URL) throws(ProtocolError) {
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG {
            throw ProtocolError(code: .invalidArgs, message: "\(url.lastPathComponent) não é um arquivo regular")
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8)) else {
            throw ProtocolError(code: .internal, message: "não consegui gravar \(tmp.lastPathComponent)")
        }
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno; unlink(tmp.path)
            throw ProtocolError(code: .internal, message: "rename do baseline falhou: \(e)")
        }
    }

    /// The decision on one measurement. `check`: 0 only when equal (improved exits 1 too, like scripts/ci/lint.sh: the lowered
    /// baseline must be committed); `update`: writes only an improvement; `raise`: writes with the reason logged in the file.
    static func apply(_ action: Action, name: String, root: URL, baselinePath rel: String, measured: String,
                      reason: String?, now: Date) throws(ProtocolError) -> Outcome {
        func bad(_ e: Ratchet.Refusal, _ what: String) -> ProtocolError {
            switch e {
            case .badLine(let n, let l): return ProtocolError(code: .invalidArgs, message: "\(what), linha \(n): '\(l)' não é '<chave> <n>'")
            case .duplicate(let k): return ProtocolError(code: .invalidArgs, message: "\(what): chave repetida '\(k)'")
            case .badReason: return ProtocolError(code: .invalidArgs, message: "--reason: texto de 1 a \(Ratchet.maxReason) caracteres, sem controle")
            }
        }
        let url = try target(root: root, rel: rel)
        let old = try read(url, name: rel)
        let base: Ratchet.Baseline, cur: Ratchet.Baseline
        do { base = try Ratchet.Baseline.parse(old) } catch { throw bad(error, rel) }
        do { cur = try Ratchet.Baseline.parse(measured) } catch { throw bad(error, "a medição de '\(name)'") }
        // the file's `#` lines (the raise log) stay on top, in order
        let header = old.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.map { "\($0)\n" }.joined()
        func list(_ cs: [Ratchet.Change]) -> String { cs.map { "  \($0.key): \($0.before) -> \($0.after)" }.joined(separator: "\n") }
        let verdict = Ratchet.compare(baseline: base, current: cur)

        switch action {
        case .check:
            switch verdict {
            case .same: return Outcome(output: "catraca \(name): igual ao baseline\n", passed: true, wrote: false)
            case .improved(let cs):
                return Outcome(output: "catraca \(name): melhorou. Rode `collie factory ratchet update \(name)` e commite \(rel):\n\(list(cs))\n", passed: false, wrote: false)
            case .worse(let cs):
                return Outcome(output: "catraca \(name): piorou (passou de \(rel)):\n\(list(cs))\n", passed: false, wrote: false)
            }
        case .update:
            guard let low = Ratchet.lowered(baseline: base, current: cur) else {
                guard case .worse(let cs) = verdict else { preconditionFailure() }
                return Outcome(output: "catraca \(name): piorou; update só abaixa. Subir: `collie factory ratchet raise \(name) --reason`:\n\(list(cs))\n", passed: false, wrote: false)
            }
            guard verdict != .same else { return Outcome(output: "catraca \(name): igual ao baseline; nada a gravar\n", passed: true, wrote: false) }
            try write(header + low.render(), to: url)
            return Outcome(output: "catraca \(name): baseline abaixado em \(rel)\n", passed: true, wrote: true)
        case .raise:
            let up: Ratchet.Raised
            do { up = try Ratchet.raise(baseline: base, to: cur, reason: reason ?? "", date: now) } catch { throw bad(error, "") }
            try write(header + up.log.map { "\($0)\n" }.joined() + up.baseline.render(), to: url)
            return Outcome(output: "catraca \(name): baseline gravado em \(rel)\n" + up.log.map { "  \($0)\n" }.joined(), passed: true, wrote: true)
        }
    }
}

extension CommandRouter {
    /// `factory.ratchet.<action>`: runs the ratchet's `measure` once (bash in the project, bounded like a loop check, no sandbox
    /// of its own) and applies `FactoryRatchet.apply`. `passed` false: the CLI exits 1.
    func factoryRatchet(_ t: TerminalRecord, _ action: FactoryRatchet.Action, name: String, reason: String?) async throws(ProtocolError) -> JSONValue {
        let root = ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId })
        let config: ProjectWorkConfig?
        switch WorkConfigFile.config(root: root) {
        case .failure(let e): throw e
        case .success(let c): config = c
        }
        guard let r = config?.factory?.ratchets.first(where: { $0.name == name }) else {
            throw ProtocolError(code: .notFound, message: "catraca '\(name)' não está em factory.static.ratchets de collie-work.json")
        }
        guard let rel = r.baseline else { throw ProtocolError(code: .invalidArgs, message: "catraca '\(name)' sem baseline no perfil") }
        if action == .raise {   // refused before anything runs
            do { _ = try Ratchet.raise(baseline: .init(), to: .init(), reason: reason ?? "", date: Date()) }
            catch { throw ProtocolError(code: .invalidArgs, message: "--reason: texto de 1 a \(Ratchet.maxReason) caracteres, sem controle") }
        }
        let env = RouterLoopHost.checkEnv(await loopUserEnv(), sandbox: nil)
        let res = try await RouterLoopHost.runCheck(r.measure, in: root, profile: nil, env: env, timeout: FactoryRatchet.measureTimeout)
        guard res.status == 0, !res.truncated else {
            throw ProtocolError(code: .invalidArgs, message: "measure de '\(name)' falhou (código \(res.status)\(res.truncated ? ", saída cortada" : "")): \(RerailText.clean(String(res.stderr.suffix(300)), max: 300))")
        }
        let o = try FactoryRatchet.apply(action, name: name, root: root, baselinePath: rel, measured: res.stdout, reason: reason, now: Date())
        return .object(["output": .string(o.output), "passed": .bool(o.passed), "wrote": .bool(o.wrote)])
    }
}
