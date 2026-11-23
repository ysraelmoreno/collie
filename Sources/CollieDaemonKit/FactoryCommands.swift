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
        // U4: escaped baits lower their layer. A link or a big file is refused; an invalid file only marks the layers it hides
        // (minor nit: it no longer takes the whole report down)
        switch data(root, FactoryBait.resultsPath) {
        case .failure(let e): return .failure(e)
        case .success(nil): break
        case .success(let d?):
            switch BaitResults.parse(d) {
            case .success(let r): s.baits = r.doctorInput
            case .failure(let e):
                let m = "\(FactoryBait.resultsPath): \(e.message)"
                // N4 (round 2): the runs that parse alone still count their escapes; the layers of the invalid ones lose 1 by error
                s.baits = FactoryDoctor.BaitResults(escapedBaits: BaitResults.validRuns(d).escaped(),
                                                    errors: Dictionary(uniqueKeysWithValues: BaitResults.failingLayers(d).map { ($0.rawValue, m) }))
            }
        }
        return .success(s)
    }

    static let maxBaitBytes = 1 << 20

    /// U4: `rel` as a regular file inside the root (no link, no `..`, at most 1 MB); nil when absent.
    static func data(_ root: URL, _ rel: String) -> Result<Data?, ProtocolError> {
        let path = root.appendingPathComponent(rel).path
        guard !FactoryDoctor.outsideRepo(rel), ProjectRoot.contains(path, root: root) else { return .failure(ProtocolError(code: .invalidArgs, message: "\(rel) fora do projeto")) }
        switch WorkConfigFile.regular(path, name: rel, max: maxBaitBytes, tooLarge: { "\(rel) passa de \($0) bytes" }) {
        case .absent: return .success(nil)
        case .loaded(let d): return .success(d)
        case .refused(let m): return .failure(ProtocolError(code: .invalidArgs, message: m))
        }
    }

    /// U4: `.collie/factory/bait-results.json`, strict; nil when absent.
    static func baitResults(root: URL) -> Result<BaitResults?, ProtocolError> {
        let rel = FactoryBait.resultsPath
        switch data(root, rel) {
        case .failure(let e): return .failure(e)
        case .success(nil): return .success(nil)
        case .success(let d?):
            switch BaitResults.parse(d) {
            case .failure(let e): return .failure(ProtocolError(code: .invalidArgs, message: "\(rel): \(e.message)"))
            case .success(let r): return .success(r)
            }
        }
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

extension CommandRouter {
    /// `factory.bait.list` / `factory.bait.report` (U4): the project's catalog and its results file, read only; nothing run.
    func factoryBait(_ t: TerminalRecord, report: Bool) throws(ProtocolError) -> JSONValue {
        let root = ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId })
        func lines(_ x: String) -> String { x.split(separator: "\n").map { RerailText.clean(String($0), max: 400) + "\n" }.joined() }   // repository text
        func value<T: Encodable>(_ v: T) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))) ?? .null }
        if report {
            let r: BaitResults
            switch FactoryDoctorReader.baitResults(root: root) {
            case .failure(let e): throw e
            case .success(let x): r = x ?? BaitResults()
            }
            let rep: [String: JSONValue] = ["byLayer": value(r.captureRateByLayer()), "byPersona": value(r.captureRateByPersona()),
                                            "escaped": value(r.runs.filter { !$0.caught }), "costSeconds": .number(Double(r.totalCost)),
                                            "runs": .number(Double(r.runs.count))]
            return .object(["output": .string(lines(r.report())), "report": .object(rep)])
        }
        let rel = FactoryBait.catalogPath
        let d: Data
        switch FactoryDoctorReader.data(root, rel) {
        case .failure(let e): throw e
        case .success(nil): throw ProtocolError(code: .notFound, message: "sem catálogo de iscas: \(rel) não existe no projeto")
        case .success(let x?): d = x
        }
        switch FactoryBait.parseCatalog(d) {
        case .failure(let e): throw ProtocolError(code: .invalidArgs, message: "\(rel): \(e.message)")
        case .success(let c): return .object(["output": .string(lines(FactoryBait.text(c))), "catalog": value(c)])
        }
    }
}

/// U5: `collie factory ratchet <check|update|raise> <name>`: the profile's ratchet measured once and compared with its baseline
/// file, read confined to the project (no `..`, not absolute, never through a symlink). F6a: the daemon never writes it: for
/// `update`/`raise` it hands `root`, `rel` and `newBaseline` to the CLI, which writes in the agent's process (`BaselineWriter`), so
/// the agent's own sandbox decides (rounds 1 to 3 kept finding places the daemon wrote that the sandbox would deny).
enum FactoryRatchet {
    enum Action: String, Sendable { case check, update, raise }
    /// `newBaseline`: the whole file the CLI writes at `path` (nil: nothing to write); the daemon answers `wrote: false`.
    struct Outcome: Sendable, Equatable {
        var output: String, passed: Bool, newBaseline: String? = nil, root: String, rel: String
    }
    static let maxBaselineBytes = 1 << 20, maxLogLines = 100
    static let measureTimeout: Duration = .seconds(600)

    /// The baseline's path checked by `FactoryProfile.confinedPath` alone (the parser's rule, one function, N6): relative, no
    /// `..`, `.`, empty part, `~`/`$` start, `.git`/`*.git`, `.collie` nor `collie-work.json`. Its folder is opened by `openDir`.
    static func target(root: URL, rel: String) throws(ProtocolError) -> URL {
        guard FactoryProfile.confinedPath(rel)
        else { throw ProtocolError(code: .invalidArgs, message: "baseline '\(rel)' fora do projeto ou em lugar proibido (.git, .collie, collie-work.json)") }
        return root.appendingPathComponent(rel)
    }

    /// N1 (round 2): extra defense for the read and the path handed back (the CLI's write is the agent sandbox's call): never
    /// a project root at the home or above it, nor a baseline where the strict profile denies a terminal's write
    /// (`SandboxGrantStore.mayWrite`). B (round 3): `mayWrite` gets the resolved path, compared without case.
    static func place(root: URL, rel: String, home: URL, collie: URL) throws(ProtocolError) {
        let r = URL(fileURLWithPath: SignedAppCheck.realPath(root))
        let h = URL(fileURLWithPath: SignedAppCheck.realPath(home)).pathComponents.map { $0.lowercased() }
        guard !h.starts(with: r.pathComponents.map { $0.lowercased() }) else {
            throw ProtocolError(code: .invalidArgs, message: "a raiz do projeto é a pasta pessoal ou fica acima dela: a catraca não usa baseline aí")
        }
        let path = SignedAppCheck.realPath(r.appendingPathComponent(rel))
        guard SandboxGrantStore.mayWrite(path, root: r.path, grants: [], home: home, collie: collie, app: nil, closed: []) else {
            throw ProtocolError(code: .invalidArgs, message: "baseline '\(rel)' cai num caminho que o sandbox nunca deixa gravar (rc do shell, segredos, launchd, config)")
        }
    }

    /// The baseline's folder as a fd (`ConfinedDir`, shared with the CLI's writer): no link followed on the way, the root
    /// itself included (A round 3). The caller closes it.
    static func openDir(root: URL, rel: String) throws(ProtocolError) -> Int32 {
        do { return try ConfinedDir.openDir(root: root.path, rel: rel) } catch { throw ProtocolError(code: .invalidArgs, message: error.message) }
    }

    /// The file `name` in `dir`'s text; "" when absent (a first baseline). A link, a folder, a FIFO or a big file is refused.
    static func read(dir: Int32, _ name: String, rel: String) throws(ProtocolError) -> String {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return "" }
            throw ProtocolError(code: .invalidArgs, message: "\(rel) não é um arquivo regular")
        }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ProtocolError(code: .invalidArgs, message: "\(rel) não é um arquivo regular") }
        guard st.st_size <= maxBaselineBytes else { throw ProtocolError(code: .invalidArgs, message: "\(rel) passa de \(maxBaselineBytes) bytes") }
        let d: Data
        do { d = try h.read(upToCount: maxBaselineBytes + 1) ?? Data() }   // N5: an I/O error is not an empty baseline
        catch { throw ProtocolError(code: .internal, message: "não consegui ler \(rel): \(error.localizedDescription)") }
        guard d.count <= maxBaselineBytes else { throw ProtocolError(code: .invalidArgs, message: "\(rel) passa de \(maxBaselineBytes) bytes") }
        return String(decoding: d, as: UTF8.self)
    }

    /// BLOCKER 1: `measure` is text an agent can write, so with terminal sandboxes on (`sandboxHome`) it runs under the calling
    /// terminal's own profile and sandbox env (HOME the sandbox's), as the loop's check does; no profile (a free terminal, or
    /// its file gone): refused, nothing run. No `sandboxHome` (tests, a daemon without sandbox): unsandboxed, as before.
    /// `run` is `RouterLoopHost.runCheck` (a test passes its own: `sandbox-exec` does not nest inside an agent).
    static func measure(_ command: String, in root: URL, sandboxHome: URL?, terminal: UUID, sandboxed: Bool, collieRoot: URL, shell: String,
                        user: [String: String],
                        run: (String, URL, URL?, [String: String]) async throws(ProtocolError) -> ProcessResult) async throws(ProtocolError) -> ProcessResult {
        guard let home = sandboxHome else { return try await run(command, root, nil, RouterLoopHost.checkEnv(user, sandbox: nil)) }
        let profile = SandboxLaunch.profileFile(terminal, root: collieRoot)
        guard sandboxed, FileManager.default.fileExists(atPath: profile.path) else {
            throw ProtocolError(code: .unavailable, message: "o measure só roda no sandbox do terminal, e este terminal não tem perfil de sandbox; nada foi executado")
        }
        return try await run(command, root, profile, RouterLoopHost.checkEnv(user, sandbox: (terminal, collieRoot, shell, home)))
    }

    /// The decision on one measurement. `check`: 0 only when equal (improved exits 1 too, like scripts/ci/lint.sh: the lowered
    /// baseline must be committed); `update`: hands over only an improvement; `raise`: hands over with the reason logged.
    /// Nothing is written here (F6a): `newBaseline`, `root` (the resolved root) and `rel` go to the CLI, which checks them again (F7a).
    static func apply(_ action: Action, name: String, root: URL, baselinePath rel: String, measured: String,
                      reason: String?, now: Date, home: URL, collie: URL) throws(ProtocolError) -> Outcome {
        func bad(_ e: Ratchet.Refusal, _ what: String) -> ProtocolError {
            switch e {
            case .badLine(let n, let l): return ProtocolError(code: .invalidArgs, message: "\(what), linha \(n): '\(l)' não é '<chave> <n>'")
            case .duplicate(let k): return ProtocolError(code: .invalidArgs, message: "\(what): chave repetida '\(k)'")
            case .badReason: return ProtocolError(code: .invalidArgs, message: "--reason: texto de 1 a \(Ratchet.maxReason) caracteres, sem controle")
            }
        }
        let file = try target(root: root, rel: rel).lastPathComponent
        // nit 6 (round 4): the root opened ONCE; `place` checks the path of that fd and the folder is walked from it
        let rootFd: Int32
        do { rootFd = try ConfinedDir.openRoot(SignedAppCheck.realPath(root)) } catch { throw ProtocolError(code: .invalidArgs, message: error.message) }
        defer { close(rootFd) }
        guard let realRoot = ConfinedDir.path(of: rootFd) else { throw ProtocolError(code: .internal, message: "não consegui ler o caminho da raiz do projeto") }
        let real = URL(fileURLWithPath: realRoot), path = real.path
        try place(root: real, rel: rel, home: home, collie: collie)
        let dir: Int32
        do { dir = try ConfinedDir.openDir(rootFd, rel: rel) } catch { throw ProtocolError(code: .invalidArgs, message: error.message) }
        defer { close(dir) }
        let old = try read(dir: dir, file, rel: rel)
        let base: Ratchet.Baseline, cur: Ratchet.Baseline
        do { base = try Ratchet.Baseline.parse(old) } catch { throw bad(error, rel) }
        do { cur = try Ratchet.Baseline.parse(measured) } catch { throw bad(error, "a medição de '\(name)'") }
        // the file's `#` lines (the raise log) stay on top, in order
        // nit 4 (round 4): a `#` line with a control character (the parser skips comments unchecked) is dropped
        let header = old.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }
        }.map(String.init)
        // nit: the log keeps its last `maxLogLines` lines, so it never grows past what `read` takes (1 MB)
        func log(_ ls: [String]) -> String { ls.suffix(maxLogLines).map { "\($0)\n" }.joined() }
        func list(_ cs: [Ratchet.Change]) -> String { cs.map { "  \($0.key): \($0.before) -> \($0.after)" }.joined(separator: "\n") }
        let verdict = Ratchet.compare(baseline: base, current: cur)
        // minor 6: a measure that exits 0 with no output would zero the baseline; refused in update, flagged in check
        let empty = cur.counts.isEmpty && !base.counts.isEmpty
        let emptyNote = "a medição de '\(name)' veio vazia (0 chaves) e \(rel) não está vazio: o measure pode ter quebrado"

        switch action {
        case .check:
            switch verdict {
            case .same: return Outcome(output: "catraca \(name): igual ao baseline\n", passed: true, root: path, rel: rel)
            case .improved(let cs):
                if empty { return Outcome(output: "catraca \(name): \(emptyNote)\n", passed: false, root: path, rel: rel) }
                return Outcome(output: "catraca \(name): melhorou. Rode `collie factory ratchet update \(name)` e commite \(rel):\n\(list(cs))\n", passed: false, root: path, rel: rel)
            case .worse(let cs):
                return Outcome(output: "catraca \(name): piorou (passou de \(rel)):\n\(list(cs))\n", passed: false, root: path, rel: rel)
            }
        case .update:
            guard !empty else { throw ProtocolError(code: .invalidArgs, message: "\(emptyNote); nada gravado") }
            guard let low = Ratchet.lowered(baseline: base, current: cur) else {
                guard case .worse(let cs) = verdict else { preconditionFailure() }
                return Outcome(output: "catraca \(name): piorou; update só abaixa. Subir: `collie factory ratchet raise \(name) --reason`:\n\(list(cs))\n", passed: false, root: path, rel: rel)
            }
            guard verdict != .same else { return Outcome(output: "catraca \(name): igual ao baseline; nada a gravar\n", passed: true, root: path, rel: rel) }
            return Outcome(output: "catraca \(name): baseline abaixado em \(rel)\n", passed: true, newBaseline: log(header) + low.render(), root: path, rel: rel)
        case .raise:
            let up: Ratchet.Raised
            do { up = try Ratchet.raise(baseline: base, to: cur, reason: reason ?? "", date: now) } catch { throw bad(error, "") }
            return Outcome(output: "catraca \(name): baseline gravado em \(rel)\n" + up.log.map { "  \($0)\n" }.joined(), passed: true,
                           newBaseline: log(header + up.log) + up.baseline.render(), root: path, rel: rel)
        }
    }
}

extension CommandRouter {
    /// `factory.ratchet.<action>`: runs the ratchet's `measure` once (bash in the project, bounded and sandboxed like a loop
    /// check: `FactoryRatchet.measure`) and applies `FactoryRatchet.apply`. `passed` false: the CLI exits 1. F6a: writes
    /// nothing; `newBaseline` (or null), `root` and `rel` go back, and the CLI writes them in the agent's process.
    func factoryRatchet(_ t: TerminalRecord, _ action: FactoryRatchet.Action, name: String, reason: String?) async throws(ProtocolError) -> JSONValue {
        // nit E (round 3): the root as the rest of the daemon computes it (the terminal's project root, the sandbox's home)
        let root = URL(fileURLWithPath: t.projectRoot ?? ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId }, home: sandboxHomeDir).path)
        let work: ProjectWorkConfig?
        switch WorkConfigFile.config(root: root) {
        case .failure(let e): throw e
        case .success(let c): work = c
        }
        guard let r = work?.factory?.ratchets.first(where: { $0.name == name }) else {
            throw ProtocolError(code: .notFound, message: "catraca '\(name)' não está em factory.static.ratchets de collie-work.json")
        }
        guard let rel = r.baseline else { throw ProtocolError(code: .invalidArgs, message: "catraca '\(name)' sem baseline no perfil") }
        if action == .raise {   // refused before anything runs
            do { _ = try Ratchet.raise(baseline: .init(), to: .init(), reason: reason ?? "", date: Date()) }
            catch { throw ProtocolError(code: .invalidArgs, message: "--reason: texto de 1 a \(Ratchet.maxReason) caracteres, sem controle") }
        }
        _ = try FactoryRatchet.target(root: root, rel: rel)   // refused before anything runs (N1)
        try FactoryRatchet.place(root: root, rel: rel, home: sandboxHomeDir, collie: config.paths.root)
        let res = try await FactoryRatchet.measure(r.measure, in: root, sandboxHome: config.sandboxHome, terminal: t.id, sandboxed: sandboxed(t),
                                                   collieRoot: config.paths.root, shell: config.shell, user: await loopUserEnv()) {
            (c, d, p, e) async throws(ProtocolError) in try await RouterLoopHost.runCheck(c, in: d, profile: p, env: e, timeout: FactoryRatchet.measureTimeout)
        }
        guard res.status == 0, !res.truncated else {
            throw ProtocolError(code: .invalidArgs, message: "measure de '\(name)' falhou (código \(res.status)\(res.truncated ? ", saída cortada" : "")): \(RerailText.clean(String(res.stderr.suffix(300)), max: 300))")
        }
        let o = try FactoryRatchet.apply(action, name: name, root: root, baselinePath: rel, measured: res.stdout, reason: reason, now: Date(),
                                        home: sandboxHomeDir, collie: config.paths.root)
        return .object(["output": .string(o.output), "passed": .bool(o.passed), "wrote": .bool(false), "root": .string(o.root), "rel": .string(o.rel),
                        "newBaseline": o.newBaseline.map(JSONValue.string) ?? .null])
    }
}

/// F7a (round 4, major 1): the CLI's half of `collie factory ratchet`, pure enough to test without a process. The daemon's
/// `root` and `rel` are NOT trusted: `rel` passes `FactoryProfile.confinedPath` again, `root` must be the project root this
/// process computes from its own cwd (`ProjectRoot`'s rule), and the writer walks the folder by fd without following links.
/// `update`/`raise` with `--terminal` are refused: this process does not run inside the other terminal's sandbox, so it
/// would write where that sandbox may deny (`check` only reads and stays allowed).
public enum RatchetCLI {
    public static func refusal(_ command: String, _ args: [String: JSONValue]) -> String? {
        guard command == "factory.ratchet.update" || command == "factory.ratchet.raise", args["terminal"] != nil else { return nil }
        return "\(command.dropFirst("factory.ratchet.".count)) com --terminal recusado: o baseline é gravado por este processo, fora do sandbox daquele terminal. Rode o comando de dentro do próprio terminal (sem --terminal); `check` com --terminal segue valendo"
    }

    /// The daemon's answer -> what to print (`.null`: nothing) and the exit code. `newBaseline` is written (then `wrote: true`)
    /// only for `update`/`raise`, after the checks above; a writer's error goes to `err` and exits 1 with nothing printed.
    public static func handleRatchet(_ result: JSONValue, command: String, args: [String: JSONValue], cwd: String,
                                     home: URL = URL(fileURLWithPath: NSHomeDirectory()), err: (String) -> Void,
                                     write: (String, String, String) throws -> Void = { try BaselineWriter.write($0, root: $1, rel: $2) }) -> (JSONValue, Int32) {
        guard case .object(var o) = result else { return (result, 0) }
        if command != "factory.ratchet.check", case .string(let text)? = o["newBaseline"] {
            if let e = refusal(command, args) { err(e); return (.null, 1) }
            guard case .string(let root)? = o["root"], case .string(let rel)? = o["rel"], FactoryProfile.confinedPath(rel) else {
                err("baseline não gravado: o daemon devolveu um caminho fora do projeto ou proibido"); return (.null, 1)
            }
            let mine = ProjectRoot.resolve(cwd: cwd, paddock: nil, home: home).path
            guard SignedAppCheck.realPath(URL(fileURLWithPath: root)) == mine else {
                err("baseline não gravado: a raiz do daemon (\(root)) não é a raiz do projeto desta pasta (\(mine))"); return (.null, 1)
            }
            do { try write(text, mine, rel) } catch {
                err("baseline não gravado em \(rel): \((error as? BaselineWriter.Failure)?.message ?? "\(error)")"); return (.null, 1)
            }
            o["wrote"] = .bool(true)
        }
        return (.object(o), o["passed"] == .bool(false) ? 1 : 0)
    }
}
