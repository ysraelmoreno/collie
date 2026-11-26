import Foundation

/// U3: `collie factory doctor`'s score (spec 2026-11-23-fabrica-para-usuarios-design.md, fabrica/u3-doctor.md).
/// Pure and deterministic: a `Snapshot` (what the reader gathered, files only, nothing run) gives one `Report`, layers in
/// the pyramid's order. One small rule per question. Strings in the report come from the repository: whoever shows them cleans them.
public enum FactoryDoctor {
    public enum Layer: String, Codable, CaseIterable, Sendable { case `static`, judge, verification, review, prose, guardrails }
    public enum Rating: String, Codable, Sendable { case fraco = "FRACO", ok = "OK", forte = "FORTE" }

    /// U4 fills it: per layer (its raw value), how many baits passed that layer should have caught. `errors`: per layer, why
    /// the results file could not vouch for it (an invalid `bait-results.json`); that layer loses 1 too.
    public struct BaitResults: Codable, Equatable, Sendable {
        public var escapedBaits: [String: Int]
        public var errors: [String: String]
        public init(escapedBaits: [String: Int] = [:], errors: [String: String] = [:]) { self.escapedBaits = escapedBaits; self.errors = errors }
    }

    public struct Snapshot: Sendable, Equatable {
        /// nil: no `collie-work.json` at the root.
        public var config: ProjectWorkConfig?
        /// Repository-relative path → text (already cut at 64 KB): the scripts the commands cite and the `check-*.sh` found.
        public var scripts: [String: String]
        /// Repository-relative paths, up to the reader's depth.
        public var paths: [String]
        /// Repository-relative path → text of CI files (`.github/workflows/*.yml`, `Makefile`).
        public var ci: [String: String]
        /// The root `.gitignore`'s text ("" when absent).
        public var gitignore: String
        public var baits: BaitResults?
        public init(config: ProjectWorkConfig? = nil, scripts: [String: String] = [:], paths: [String] = [], ci: [String: String] = [:],
                    gitignore: String = "", baits: BaitResults? = nil) {
            self.config = config; self.scripts = scripts; self.paths = paths; self.ci = ci; self.gitignore = gitignore; self.baits = baits
        }
    }

    public struct LayerScore: Codable, Equatable, Sendable {
        public var layer: Layer, score: Int, rating: Rating, evidence: [String], nextAction: [String]
        public init(layer: Layer, score: Int, evidence: [String], nextAction: [String]) {
            self.layer = layer; self.score = min(3, max(0, score)); self.rating = FactoryDoctor.rating(self.score)
            self.evidence = evidence; self.nextAction = nextAction
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var layers: [LayerScore]
        public init(layers: [LayerScore]) { self.layers = layers }
        /// Every layer at or above `min`.
        public func passes(min: Int) -> Bool { layers.allSatisfy { $0.score >= min } }
    }

    public static func rating(_ score: Int) -> Rating { score >= 3 ? .forte : score == 2 ? .ok : .fraco }

    public static func score(_ s: Snapshot) -> Report {
        let layers = [staticLayer(s), judge(s), verification(s), review(s), prose(s), guardrails(s)]
        return Report(layers: layers.map { escaped($0, s.baits) })
    }

    // MARK: static

    static let buildOnly = ["build", "swift build", "tsc --noEmit", "cargo check", "go build", "npm run build", "make"]

    public static func staticLayer(_ s: Snapshot) -> LayerScore {
        guard let c = s.config, let gate = c.gate else {
            return LayerScore(layer: .static, score: 0, evidence: [s.config == nil ? tr("sem collie-work.json", "no collie-work.json") : tr("collie-work.json: sem gate", "collie-work.json: no gate")],
                              nextAction: [tr("defina 'gate' em collie-work.json com o comando que roda os testes", "set 'gate' in collie-work.json to the command that runs the tests")])
        }
        var ev = ["collie-work.json: gate = \"\(gate)\""]
        guard let where_ = testRunnerSource(gate, s.scripts) else {
            let what = buildOnly.contains(gate.trimmingCharacters(in: .whitespaces)) ? tr("só compila", "only compiles") : tr("não roda testes", "does not run tests")
            ev.append(tr("o gate \(what): nenhum runner de teste (test, pytest, jest, vitest, go test, cargo test, swift test...) no comando nem nos scripts que ele cita", "the gate \(what): no test runner (test, pytest, jest, vitest, go test, cargo test, swift test...) in the command or in the scripts it cites"))
            return LayerScore(layer: .static, score: 1, evidence: ev, nextAction: [tr("ponha um runner de teste no gate (ex.: swift test, npm test, pytest)", "put a test runner in the gate (e.g. swift test, npm test, pytest)")])
        }
        ev.append(tr("o gate roda testes: \(where_)", "the gate runs tests: \(where_)"))
        var plus: [String] = [], next: [String] = []
        func extra(_ ok: Bool, _ yes: String, _ no: String) { if ok { plus.append(yes) } else { next.append(no) } }
        extra(c.precheck != nil, "precheck = \"\(c.precheck ?? "")\"", tr("defina 'precheck' (rápido, ex.: compilar os testes)", "set 'precheck' (fast, e.g. compile the tests)"))
        extra(c.smoke != nil, "smoke = \"\(c.smoke ?? "")\"", tr("defina 'smoke'", "set 'smoke'"))
        extra(!c.areas.isEmpty, tr("áreas: \(c.areas.keys.sorted().joined(separator: ", "))", "areas: \(c.areas.keys.sorted().joined(separator: ", "))"), tr("defina 'areas' com o check de cada parte do projeto", "set 'areas' with the check for each part of the project"))
        let baseline = s.paths.first { ($0.split(separator: "/").last ?? "").lowercased().contains("baseline") }
        let ratchets = c.factory?.ratchets.map(\.name) ?? []
        extra(!ratchets.isEmpty || baseline != nil,
              ratchets.isEmpty ? tr("arquivo de baseline: \(baseline ?? "")", "baseline file: \(baseline ?? "")") : tr("catracas: \(ratchets.joined(separator: ", "))", "ratchets: \(ratchets.joined(separator: ", "))"),
              tr("defina uma catraca (factory.static.ratchets)", "define a ratchet (factory.static.ratchets)"))
        let arch = c.factory?.architecture ?? []
        extra(!arch.isEmpty, tr("regras de arquitetura: \(arch.count)", "architecture rules: \(arch.count)"), tr("defina regras de arquitetura (factory.static.architecture)", "define architecture rules (factory.static.architecture)"))
        let ci = ciCiting(gate, s.ci)
        extra(ci != nil, tr("o CI roda o mesmo gate: \(ci ?? "")", "CI runs the same gate: \(ci ?? "")"), tr("faça o CI rodar o mesmo comando do gate", "make CI run the same gate command"))
        ev += plus.map { "+ \($0)" }
        return LayerScore(layer: .static, score: plus.count >= 2 ? 3 : 2, evidence: ev, nextAction: next)
    }

    /// Where the gate runs tests: the gate itself, or `<script>: <line>` of a script it cites. nil: nowhere.
    public static func testRunnerSource(_ command: String, _ scripts: [String: String]) -> String? {
        testRunnerSources(command, scripts).first
    }

    /// Every place the gate runs tests, in order (minor C, round 3: `viaPackageScript` looks at all of them, not the first).
    public static func testRunnerSources(_ command: String, _ scripts: [String: String]) -> [String] {
        func tests(_ l: String) -> Bool { runsTests(l) || viaPackageScript(l) }
        var out: [String] = tests(command) ? ["\"\(command)\""] : []
        for p in citedPaths(command) {
            guard let text = scripts[p] else { continue }
            // C2: a comment line (`# swift test` once) runs nothing
            out += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") && tests($0) }.map { "\(p): \($0)" }
        }
        return out
    }

    static let runners: Set<String> = ["pytest", "jest", "vitest", "rspec", "mocha", "unittest", "phpunit", "ctest"]

    /// Some simple command of `cmd` is a test runner: `test`, `test:x` or `test-x` as an argument (`npm test`, `npm run test:ci`,
    /// `yarn test:unit`, `go test`; never the shell's `test -f`, which is a first word), a known runner anywhere (`bundle exec
    /// rspec`, `python -m unittest`), or `make check`.
    public static func runsTests(_ cmd: String) -> Bool {
        simpleCommands(cmd).contains { words in
            words.dropFirst().contains { $0 == "test" || $0.hasPrefix("test:") || $0.hasPrefix("test-") }
                || words.contains { runners.contains(String($0.split(separator: "/").last ?? "")) }
                || (words.first == "make" && words.dropFirst().contains("check"))
        }
    }

    /// The CI file (`path: line`) that has the gate's command.
    public static func ciCiting(_ gate: String, _ ci: [String: String]) -> String? {
        let g = gate.trimmingCharacters(in: .whitespaces)
        for p in ci.keys.sorted() {
            if let l = ci[p]!.split(separator: "\n").first(where: { $0.contains(g) }) { return "\(p): \(l.trimmingCharacters(in: .whitespaces))" }
        }
        return nil
    }

    // MARK: judge

    public static func judge(_ s: Snapshot) -> LayerScore {
        guard let c = s.config else {
            return LayerScore(layer: .judge, score: 1, evidence: [tr("sem collie-work.json: o juiz só tem o --check de cada tarefa", "no collie-work.json: the judge only has each task's --check")],
                              nextAction: [tr("crie collie-work.json com gate versionado no repositório", "create collie-work.json with a gate versioned in the repository")])
        }
        var warn: [String] = [], ev: [String] = [], gateCited: Set<String> = []
        let cmds = [("gate", c.gate), ("precheck", c.precheck), ("smoke", c.smoke)].compactMap { k, v in v.map { (k, $0) } }
        // what the reader saw: listed paths, or a script it read (deeper than the listing goes)
        func present(_ p: String) -> Bool { s.paths.contains(p) || s.scripts[p] != nil }
        for (k, cmd) in cmds {
            let cited = citedPaths(cmd)
            for p in cited {
                if outsideRepo(p) { warn.append(tr("\(k) cita script fora do repositório: \(p)", "\(k) cites a script outside the repository: \(p)")) }
                else if ignored(p, s.gitignore) { warn.append(tr("\(k) cita script ignorado pelo git (.gitignore): \(p)", "\(k) cites a script ignored by git (.gitignore): \(p)")) }
                else if !present(p) { warn.append(tr("\(k) cita \(p), que não existe no repositório", "\(k) cites \(p), which does not exist in the repository")) }
                else { ev.append(tr("\(k) cita \(p), versionado: lido do commit base", "\(k) cites \(p), versioned: read from the base commit")); if k == "gate" { gateCited.insert(p) } }
            }
            // a file the command names that the reader saw (`package.json`, `Package.swift`): it controls the runner
            for w in simpleCommands(cmd).flatMap({ $0 }) where !cited.contains(w) {
                if present(w) && !ignored(w, s.gitignore) {
                    ev.append(tr("\(k) cita \(w), versionado: lido do commit base", "\(k) cites \(w), versioned: read from the base commit")); if k == "gate" { gateCited.insert(w) }
                } else if isRunnerConfig(w) && !present(w) {   // F6b (n2): pytest.ini absent warns like jest.config.js absent
                    warn.append(tr("\(k) cita \(w), que não existe no repositório", "\(k) cites \(w), which does not exist in the repository"))
                }
            }
        }
        for p in s.scripts.keys.sorted() where isTaskCheck(p) && onlyLooksForFiles(s.scripts[p]!) {
            warn.append(tr("\(p) só faz grep/test -f: passa sem o código funcionar", "\(p) only greps/tests -f: it passes without the code working"))
        }
        if !warn.isEmpty {
            return LayerScore(layer: .judge, score: 1, evidence: ev + warn.map { tr("aviso: \($0)", "warning: \($0)") },
                              nextAction: [tr("versione no repositório os scripts que o gate cita", "version the scripts the gate cites in the repository"), tr("faça os checks rodarem teste, não só procurar texto", "make the checks run tests, not just look for text")])
        }
        if cmds.isEmpty {
            return LayerScore(layer: .judge, score: 2, evidence: [tr("sem gate, precheck nem smoke: o juiz é só o --check de cada tarefa", "no gate, precheck or smoke: the judge is only each task's --check")],
                              nextAction: [tr("defina 'gate' em collie-work.json", "set 'gate' in collie-work.json")])
        }
        // N3 (round 2): only the gate's citations guard the judge (precheck and smoke do not judge the task)
        if gateCited.isEmpty {   // a bare gate (`npm test`): an agent can neutralize the runner through its config, which nothing guards
            return LayerScore(layer: .judge, score: 2,
                              evidence: ev + [tr("o gate não cita nenhum arquivo versionado: um agente pode neutralizar o runner pela config (ex.: o script test do package.json)", "the gate cites no versioned file: an agent can neutralize the runner through its config (e.g. the test script in package.json)")],
                              nextAction: [tr("faça o gate chamar um script versionado (ex.: scripts/gate.sh) ou citar os arquivos que controlam o runner", "make the gate call a versioned script (e.g. scripts/gate.sh) or cite the files that control the runner")])
        }
        // N4 (round 2): a gate script that hands over to `npm test` runs the package.json's script, which an agent can edit;
        // unless the gate's text cites package.json (then the judge guards it too, as rev-2 N1 suggests for the configs)
        if let src = c.gate.flatMap({ testRunnerSources($0, s.scripts).first(where: viaPackageScript) }), !gateCited.contains("package.json") {
            return LayerScore(layer: .judge, score: 2, evidence: ev + [tr("o runner do gate passa pelo script test do package.json: \(src)", "the gate runner goes through the test script in package.json: \(src)")],
                              nextAction: [tr("chame o runner direto no gate (ex.: npx --no-install jest), não npm/yarn/pnpm test", "call the runner directly in the gate (e.g. npx --no-install jest), not npm/yarn/pnpm test")])
        }
        return LayerScore(layer: .judge, score: 3, evidence: ev, nextAction: [])
    }

    /// F6b (n2): a pure config of a test runner (`jest.config.js`, `vitest.config.ts`, `vite.config.ts`, `vitest.workspace.ts`,
    /// `pytest.ini`, `tox.ini`; F7b: `jest.config.json`, `vitest.workspace.json`), never a manifest (`package.json`, `pyproject.toml`, `Package.swift`).
    public static func isRunnerConfig(_ w: String) -> Bool {
        w.range(of: #"^((jest|vitest|vite)\.config|vitest\.workspace)\.([cm]?[jt]s|json)$|^(pytest|tox)\.ini$"#, options: .regularExpression) != nil
    }

    /// `npm test`, `npm t`, `npm -s test`, `yarn run test`, `pnpm test:ci`, `bun run test`, `npm run-script test`...: the runner
    /// is whatever the package.json's script says. F7a (minor 2): `t` is npm's and pnpm's alias of `test` only (`npm run t`,
    /// `yarn t` run a script named `t`); `bun test` is bun's own runner, so bun counts only with `run`.
    public static func viaPackageScript(_ line: String) -> Bool {
        let flags = #"(\s+--?[\w-]+)*\s+"#
        let re = #"\b((npm|pnpm)"# + flags + #"((run(-script)?\s+)?test|t)|yarn"# + flags + #"(run\s+)?test|bun"# + flags + #"run\s+(test|t))\b"#
        return line.range(of: re, options: .regularExpression) != nil
    }

    /// Words of the command that look like a script path (`scripts/x.sh`, `./check.py`, `/abs/x`), `./` dropped, in order, once each.
    public static func citedPaths(_ cmd: String) -> [String] {
        var out: [String] = []
        for w in simpleCommands(cmd).flatMap({ $0 }) {
            let x = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let looks = x.contains("/") || [".sh", ".py", ".rb", ".js", ".ts", ".pl"].contains { x.hasSuffix($0) }
            guard looks, !x.hasPrefix("-"), !x.contains("://"), !x.contains("=") else { continue }
            let p = x.hasPrefix("./") ? String(x.dropFirst(2)) : x
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    public static func outsideRepo(_ p: String) -> Bool {
        p.hasPrefix("/") || p.hasPrefix("~") || p.hasPrefix("$") || p.split(separator: "/").contains("..")
    }

    /// The path matches a line of `.gitignore`: a plain glob on the path or on any of its components, a `dir/` prefix,
    /// `/x` anchored at the root. ponytail: no `!` negation nor `**` semantics; git check-ignore is exact if this misleads.
    public static func ignored(_ p: String, _ gitignore: String) -> Bool {
        let comps = p.split(separator: "/").map(String.init)
        for raw in gitignore.split(separator: "\n") {
            var pat = raw.trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty, !pat.hasPrefix("#"), !pat.hasPrefix("!") else { continue }
            if pat.hasSuffix("/") { pat.removeLast() }
            if pat.hasPrefix("/") || pat.dropLast().contains("/") {
                let a = pat.hasPrefix("/") ? String(pat.dropFirst()) : pat
                let n = a.split(separator: "/").count
                if comps.count >= n, fnmatch(a, comps.prefix(n).joined(separator: "/"), 0) == 0 { return true }
            } else if comps.contains(where: { fnmatch(pat, $0, 0) == 0 }) { return true }
        }
        return false
    }

    static func isTaskCheck(_ p: String) -> Bool {
        let name = p.split(separator: "/").last.map(String.init) ?? p
        return name.hasPrefix("check-") && name.hasSuffix(".sh")
    }

    static let inert: Set<String> = ["exit", "echo", "true", "{", "}"]

    /// Every line that does something is a `grep` or a `test -f`/`[ -f`: the check only looks for a file or a word. `exit`,
    /// `echo`, `true` and braces do nothing (`grep -q x a || exit 1`, a final `echo ok`).
    public static func onlyLooksForFiles(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("set ") && !$0.hasPrefix("cd ") }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { l in
            simpleCommands(l).allSatisfy { w in
                guard let f = w.first, !inert.contains(f) else { return true }
                return f == "grep" || ((f == "test" || f == "[") && w.dropFirst().first.map { ["-f", "-e", "-s"].contains($0) } == true)
            }
        }
    }

    /// The command split on `&&`, `||`, `;`, `|` and newlines, each part as its words. ponytail: no quoting rules; enough for heuristics.
    static func simpleCommands(_ cmd: String) -> [[String]] {
        var t = cmd
        for sep in ["&&", "||", ";", "|", "\n", "(", ")"] { t = t.replacingOccurrences(of: sep, with: "\u{1}") }
        return t.split(separator: "\u{1}").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }.filter { !$0.isEmpty }
    }

    // MARK: verification

    static let uiWords = ["ui", "web", "app", "front", "frontend", "mobile"]

    public static func verification(_ s: Snapshot) -> LayerScore {
        let scenarios = s.config?.factory?.scenarios ?? []
        let covered = Set(scenarios.map(\.area))
        let uiAreas = (s.config?.areas.keys.sorted() ?? []).filter { a in uiWords.contains(a) || a.split(separator: "-").contains { uiWords.contains(String($0)) } }
        let bare = uiAreas.filter { !covered.contains($0) }.map { tr("aviso: área de UI '\($0)' sem cenário", "warning: UI area '\($0)' has no scenario") }
        guard !scenarios.isEmpty else {
            return LayerScore(layer: .verification, score: 0, evidence: [tr("sem verificação em runtime ainda (factory.verification.scenarios vazio)", "no runtime verification yet (factory.verification.scenarios is empty)")] + bare,
                              nextAction: [tr("defina factory.verification.scenarios para as áreas que têm tela ou serviço", "define factory.verification.scenarios for the areas that have a screen or a service")])
        }
        let ev = [tr("cenários: ", "scenarios: ") + scenarios.map(\.area).joined(separator: ", ")] + bare
        return LayerScore(layer: .verification, score: bare.isEmpty ? 3 : 2, evidence: ev,
                          nextAction: bare.isEmpty ? [] : [tr("dê um cenário a cada área de UI", "give each UI area a scenario")])
    }

    // MARK: review

    public static func review(_ s: Snapshot) -> LayerScore {
        guard let f = s.config?.factory, !f.personas.isEmpty else {
            return LayerScore(layer: .review, score: 0, evidence: [tr("sem personas de revisão (factory.review.personas)", "no review personas (factory.review.personas)")],
                              nextAction: [tr("defina personas em factory.review.personas, com arquivo em docs/fabrica/personas/<nome>.md", "define personas in factory.review.personas, with a file at docs/fabrica/personas/<name>.md")])
        }
        var ev = [tr("personas: ", "personas: ") + f.personas.joined(separator: ", ")], next: [String] = [], score = 1
        let missing = f.personas.filter { personaFile($0, s.paths) == nil }
        if missing.isEmpty { score += 1; ev += f.personas.map { "persona \($0): \(personaFile($0, s.paths)!)" } }
        else { ev += missing.map { tr("aviso: persona '\($0)' sem arquivo em docs/fabrica/personas ou num caminho personas/", "warning: persona '\($0)' has no file in docs/fabrica/personas or under a personas/ path") }
               next.append(tr("crie docs/fabrica/personas/<nome>.md para cada persona", "create docs/fabrica/personas/<name>.md for each persona")) }
        ev.append("threshold: \(f.threshold.rawValue)")
        // ponytail: threshold always has a value (major by default), so only callOwner can raise the score
        if f.callOwner { score += 1; ev.append(tr("callOwner: o dono é chamado quando a revisão barra", "callOwner: the owner is called when the review blocks")) }
        else { next.append(tr("ligue factory.review.callOwner para o dono ser chamado quando a revisão barra", "turn on factory.review.callOwner so the owner is called when the review blocks")) }
        return LayerScore(layer: .review, score: score, evidence: ev, nextAction: next)
    }

    /// `docs/fabrica/personas/<p>.md` first, else any `.../personas/<p>(.md)`.
    public static func personaFile(_ p: String, _ paths: [String]) -> String? {
        let main = "docs/fabrica/personas/\(p).md"
        if paths.contains(main) { return main }
        return paths.first { path in
            let c = path.split(separator: "/").map(String.init)
            return c.count >= 2 && c[c.count - 2] == "personas" && (c.last == p || c.last == "\(p).md")
        }
    }

    // MARK: prose

    public static func prose(_ s: Snapshot) -> LayerScore {
        let traps = s.config?.factory?.traps ?? []
        guard !traps.isEmpty else {
            return LayerScore(layer: .prose, score: 1, evidence: [tr("nenhuma armadilha nomeada (factory.prose.traps): não há o que converter em check", "no named pitfall (factory.prose.traps): nothing to turn into a check")],
                              nextAction: [tr("liste em factory.prose.traps os ids das armadilhas da memória que valem um check", "list in factory.prose.traps the ids of the memory pitfalls worth a check")])
        }
        return LayerScore(layer: .prose, score: 2,
                          evidence: [tr("\(traps.count) armadilha(s) nomeada(s): ", "\(traps.count) named pitfall(s): ") + traps.joined(separator: ", "),
                                     tr("nota máxima 2: sem rodar nada não dá para saber se alguma armadilha virou check", "max score 2: without running anything there is no telling whether a pitfall became a check")],
                          nextAction: [tr("converta ao menos uma armadilha em check", "turn at least one pitfall into a check")])
    }

    // MARK: guardrails

    public static func guardrails(_ s: Snapshot) -> LayerScore {
        let f = s.config?.factory ?? FactoryProfile()
        var ev: [String] = [], next: [String] = []
        func item(_ ok: Bool, _ yes: String, _ no: String) { if ok { ev.append(yes) } else { next.append(no) } }
        item(f.budgetSeconds != nil, "budgetSeconds: \(f.budgetSeconds ?? 0)", tr("defina factory.guardrails.budgetSeconds", "set factory.guardrails.budgetSeconds"))
        item(f.maxTries != nil, "maxTries: \(f.maxTries ?? 0)", tr("defina factory.guardrails.maxTries", "set factory.guardrails.maxTries"))
        item(!f.destructive.isEmpty, tr("destructive: \(f.destructive.count) padrão(ões)", "destructive: \(f.destructive.count) pattern(s)"), tr("liste comandos destrutivos em factory.guardrails.destructive", "list destructive commands in factory.guardrails.destructive"))
        // ponytail: `manual` is the default too, so only `factory-paddock` reads as an explicit land
        if f.land != .manual { ev.append("land: \(f.land.rawValue)") }
        guard !ev.isEmpty else {
            return LayerScore(layer: .guardrails, score: 1, evidence: [tr("sem guardrails: valem os padrões do motor", "no guardrails: the engine defaults apply")], nextAction: next)
        }
        return LayerScore(layer: .guardrails, score: ev.count >= 3 ? 3 : 2, evidence: ev, nextAction: next)
    }

    // MARK: baits

    /// A bait that got past the layer meant to catch it takes 1 off that layer; so does an invalid results file, on the layers it hides.
    public static func escaped(_ l: LayerScore, _ baits: BaitResults?) -> LayerScore {
        if let m = baits?.errors[l.layer.rawValue] {
            return LayerScore(layer: l.layer, score: l.score - 1, evidence: l.evidence + [tr("erro: \(m)", "error: \(m)")],
                              nextAction: l.nextAction + [tr("corrija \(FactoryBait.resultsPath) (collie factory bait report mostra o erro)", "fix \(FactoryBait.resultsPath) (collie factory bait report shows the error)")])
        }
        guard let n = baits?.escapedBaits[l.layer.rawValue], n > 0 else { return l }
        return LayerScore(layer: l.layer, score: l.score - 1, evidence: l.evidence + [tr("\(n) isca(s) passaram por esta camada", "\(n) bait(s) got through this layer")],
                          nextAction: l.nextAction + [tr("reforce a camada contra as iscas que escaparam", "strengthen the layer against the baits that escaped")])
    }

    // MARK: text

    /// The table: one block per layer (score, rating, evidence, next action).
    public static func text(_ r: Report, min: Int) -> String {
        var lines: [String] = []
        for l in r.layers {
            lines.append("\(l.layer.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(l.score)/3 \(l.rating.rawValue)")
            lines += l.evidence.map { "    · \($0)" }
            lines += l.nextAction.map { "    → \($0)" }
        }
        let low = r.layers.filter { $0.score < min }.map(\.layer.rawValue)
        lines.append(low.isEmpty ? tr("toda camada tem nota >= \(min)", "every layer scores >= \(min)") : tr("abaixo de \(min): \(low.joined(separator: ", "))", "below \(min): \(low.joined(separator: ", "))"))
        lines.append(tr("Só leitura: nenhum comando do projeto foi executado.", "Read-only: no project command was run."))
        return lines.joined(separator: "\n")
    }
}
