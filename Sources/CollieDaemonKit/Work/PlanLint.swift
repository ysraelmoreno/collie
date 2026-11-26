import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// F5, `collie work plan lint <dir>`: a plan package (`waves.md` and `tasks/*.md`; the format is in
/// `docs/fabrica/modelos/plano/`) read and refused, with file and line, wherever a task would let the loop pass without
/// the code working. Pure: it reads the folder and runs nothing. `work plan apply` and `work run` (a work with a PRD)
/// call it too.
///
/// `waves.md`: `## <wave>` headings, each with `- <task id>` items; an optional `gate: <command>` line. A task of a wave
/// needs every task of the wave before it. `tasks/<id>.md`: a `# <title>` and `key: value` lines (`check`, `area`,
/// `accept`, `accept-timeout`, `needs`, `scope`, `evidence`, `agent`, `model`; outside code fences), the rest free text.
enum PlanLint {
    static let cardMax = 1500
    /// A file past this is not read (a card has at most `cardMax` characters).
    static let fileMax = 64 * 1024
    static let keys: Set<String> = ["check", "area", "accept", "accept-timeout", "needs", "scope", "evidence", "agent", "model"]
    /// The commands that only inspect files, never run the code (C4a: a heuristic, see `trivialCheck`).
    static let inspectors: Set<String> = ["grep", "egrep", "fgrep", "rg", "test", "[", "[[", "ls",
                                          "cat", "find", "stat", "head", "tail", "wc", "diff", "sed", "awk", "cmp", "file", "md5", "shasum"]
    /// The commands that always pass and check nothing.
    static let trivial: Set<String> = ["true", ":", "echo", "printf", "exit"]

    struct Finding: Codable, Equatable, Sendable { var file: String; var line: Int; var rule: String; var message: String }
    struct Field: Equatable, Sendable { var value: String; var line: Int }

    struct Task: Equatable, Sendable {
        var id: String; var title: String
        /// Relative to the package: `tasks/<id>.md`.
        var file: String
        var url: URL; var wave: Int; var text: String
        var fields: [String: Field]
        /// The tasks of the wave before (filled by `lint`).
        var waveNeeds: [String] = []
        func list(_ k: String) -> [String] { fields[k].map { TaskScheduler.list($0.value) } ?? [] }
        /// What the task needs: its wave's, then its own `needs:`, each once.
        var needs: [String] { var seen = Set<String>(); return (waveNeeds + list("needs")).filter { seen.insert($0).inserted } }
    }

    struct Plan: Sendable {
        var dir: URL; var tasks: [Task]; var waves: Int; var gate: String?
        /// sha256 of the package (`waves.md` and every `tasks/*.md`, by name): what the owner approves.
        var hash: String
        var findings: [Finding]
        var passed: Bool { findings.isEmpty }

        var text: String {
            var l = [tr("Plano \(dir.path): \(tasks.count) tarefa(s) em \(waves) onda(s) · pacote sha256 \(hash)", "Plan \(dir.path): \(tasks.count) task(s) in \(waves) wave(s) · package sha256 \(hash)")]
            if let gate { l.append(tr("portão: \(RerailText.clean(gate, max: 300))", "gate: \(RerailText.clean(gate, max: 300))")) }
            l += findings.map { "\($0.file):\($0.line): [\($0.rule)] \($0.message)" }
            l.append(passed ? tr("Passou. Para aprovar este pacote: collie work plan apply \(dir.path) --approve \(hash)", "Passed. To approve this package: collie work plan apply \(dir.path) --approve \(hash)")
                            : tr("Recusado: \(findings.count) problema(s).", "Refused: \(findings.count) problem(s)."))
            return l.joined(separator: "\n")
        }
    }

    /// C4a: `root`, the project the package must lie in (`plan apply`, `work plan lint` of an agent); nil: the package's
    /// own folder. `tasks`, `waves.md` and each card are `lstat`ed before any read: a link, a special file or a path out
    /// of `root` is a `plan-unsafe-path` finding and is never read.
    static func lint(_ dir: URL, root: URL? = nil) -> Plan {
        var f: [Finding] = []
        func add(_ file: String, _ line: Int, _ rule: String, _ m: String) { f.append(Finding(file: file, line: line, rule: rule, message: m)) }
        var hashed: [(name: String, data: Data)] = []
        let fence = root ?? dir
        /// true: `name` may not be read (the finding added): a link, a special file, out of `fence`. A missing one, or a
        /// card that is a folder (`readText` says it is unreadable), is false.
        func unsafe(_ name: String, folder: Bool = false) -> Bool {
            let path = dir.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            let why: String
            if kind == S_IFLNK { why = tr("\(name) é um link: o pacote não segue links (leria fora do projeto)", "\(name) is a link: the package does not follow links (it would read outside the project)") }
            else if kind != (folder ? S_IFDIR : S_IFREG) && !(kind == S_IFDIR && !folder) { why = tr("\(name) não é \(folder ? "uma pasta" : "um arquivo comum")", "\(name) is not \(folder ? "a folder" : "a regular file")") }
            else if !ProjectRoot.contains(path, root: fence) { why = tr("\(name) está fora do projeto \(fence.path)", "\(name) is outside the project \(fence.path)") }
            else { return false }
            add(name, 1, "plan-unsafe-path", why)
            return true
        }
        if !ProjectRoot.contains(dir.path, root: fence) { add(".", 1, "plan-unsafe-path", tr("o pacote \(dir.path) está fora do projeto \(fence.path)", "the package \(dir.path) is outside the project \(fence.path)")) }
        func readText(_ name: String) -> String? {
            let url = dir.appendingPathComponent(name)
            guard let d = PrdStore.read(url) else {
                // C4a: a card that does not open (unreadable, a folder) is said, never dropped in silence
                if FileManager.default.fileExists(atPath: url.path) { add(name, 1, "task-unreadable", tr("não consegui ler \(name)", "could not read \(name)")) }
                return nil
            }
            hashed.append((name, d))
            guard d.count <= fileMax else {
                add(name, 1, "cartao-grande", tr("arquivo com \(d.count) bytes; um cartão tem até \(cardMax) caracteres", "file with \(d.count) bytes; a card has up to \(cardMax) characters")); return nil
            }
            guard let s = String(data: d, encoding: .utf8) else { add(name, 1, "texto", tr("não é texto UTF-8", "not UTF-8 text")); return nil }
            return s
        }

        // waves.md
        var waves: [[(id: String, line: Int)]] = []
        var gate: String?
        let wavesUnsafe = unsafe("waves.md")
        if !wavesUnsafe, let text = readText("waves.md") {
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("## ") { waves.append([]); continue }
                if l.hasPrefix("gate:") { gate = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
                guard l.hasPrefix("- ") || l.hasPrefix("* ") else { continue }
                let id = String(l.dropFirst(2).prefix { !$0.isWhitespace && $0 != ":" }).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                guard !waves.isEmpty else { add("waves.md", i + 1, "onda", tr("tarefa '\(id)' fora de onda: ponha-a sob um título '## Onda N'", "task '\(id)' is outside a wave: put it under a '## Onda N' heading")); continue }
                waves[waves.count - 1].append((id, i + 1))
            }
        } else if !wavesUnsafe, !FileManager.default.fileExists(atPath: dir.appendingPathComponent("waves.md").path) {
            add("waves.md", 1, "onda", tr("não há waves.md em \(dir.path): ele lista as tarefas por onda ('## Onda 1', '- <id>')", "there is no waves.md in \(dir.path): it lists the tasks by wave ('## Onda 1', '- <id>')"))
        }
        waves.removeAll { $0.isEmpty }
        if waves.isEmpty && hashed.contains(where: { $0.name == "waves.md" }) { add("waves.md", 1, "onda", tr("nenhuma tarefa listada: '## Onda 1' e, embaixo, '- <id>' de cada tarefa", "no task listed: '## Onda 1' and, below it, '- <id>' for each task")) }

        // tasks/*.md
        let tasksUnsafe = unsafe("tasks", folder: true)
        let names = tasksUnsafe ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tasks").path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
        if names.isEmpty && !tasksUnsafe { add("tasks", 1, "onda", tr("não há tasks/*.md em \(dir.path): um cartão por tarefa, tasks/<id>.md", "there is no tasks/*.md in \(dir.path): one card per task, tasks/<id>.md")) }
        var cards: [String: (url: URL, text: String)] = [:]
        for n in names {
            let rel = "tasks/" + n
            if !unsafe(rel), let t = readText(rel) { cards[String(n.dropLast(3))] = (dir.appendingPathComponent(rel), t) }
        }
        let allIds = Set(names.map { String($0.dropLast(3)) })

        var tasks: [Task] = [], listed: [String: Int] = [:]
        for (w, wave) in waves.enumerated() {
            for (id, line) in wave {
                if let first = listed[id] { add("waves.md", line, "onda", tr("a tarefa '\(id)' já está na linha \(first)", "task '\(id)' is already on line \(first)")); continue }
                listed[id] = line
                if id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$"#, options: .regularExpression) == nil {
                    add("waves.md", line, "onda", tr("id '\(id)' inválido: letras, números, '.', '_' e '-', até 40", "id '\(id)' invalid: letters, digits, '.', '_' and '-', up to 40")); continue
                }
                guard allIds.contains(id) else { add("waves.md", line, "onda", tr("a tarefa '\(id)' não tem cartão: crie tasks/\(id).md", "task '\(id)' has no card: create tasks/\(id).md")); continue }
                guard let c = cards[id] else { continue }   // unsafe or unreadable: already a finding
                tasks.append(parse(id, wave: w, url: c.url, text: c.text))
            }
        }
        for id in allIds.sorted() where listed[id] == nil {
            add("tasks/\(id).md", 1, "onda", tr("a tarefa '\(id)' não está em nenhuma onda do waves.md", "task '\(id)' is not in any wave of waves.md"))
        }
        for i in tasks.indices where tasks[i].wave > 0 {
            tasks[i].waveNeeds = tasks.filter { $0.wave == tasks[i].wave - 1 }.map(\.id)
        }
        let ids = Set(tasks.map(\.id))
        for t in tasks { f += findings(t, known: ids.union(allIds)) }
        if let c = cycle(tasks) { add(c.file, c.line, "ciclo", tr("ciclo em needs: ", "cycle in needs: ") + c.path.joined(separator: " → ")) }

        var h = SHA256()
        for (name, d) in hashed.sorted(by: { $0.name < $1.name }) {
            h.update(data: Data("\(name)\n\(d.count)\n".utf8)); h.update(data: d); h.update(data: Data("\n".utf8))
        }
        return Plan(dir: dir, tasks: tasks, waves: waves.count, gate: gate,
                    hash: h.finalize().map { String(format: "%02x", $0) }.joined(), findings: f)
    }

    static func parse(_ id: String, wave: Int, url: URL, text: String) -> Task {
        var fields: [String: Field] = [:], title: String?, fence = false
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { fence.toggle(); continue }
            if fence { continue }
            if title == nil, l.hasPrefix("# ") { title = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces); continue }
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = String(l[..<c])
            guard keys.contains(k), fields[k] == nil else { continue }
            fields[k] = Field(value: String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces), line: i + 1)
        }
        return Task(id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? id, file: "tasks/\(id).md", url: url, wave: wave, text: text, fields: fields)
    }

    /// Every refusal of one task but a cycle (`cycle` sees them all).
    static func findings(_ t: Task, known: Set<String>) -> [Finding] {
        var f: [Finding] = []
        func add(_ line: Int, _ rule: String, _ m: String) { f.append(Finding(file: t.file, line: line, rule: rule, message: m)) }
        if t.text.count > cardMax {
            add(1, "cartao-grande", tr("cartão com \(t.text.count) caracteres; o limite é \(cardMax): corte o texto ou divida a tarefa", "card with \(t.text.count) characters; the limit is \(cardMax): cut the text or split the task"))
        }
        let check = t.fields["check"], area = t.fields["area"]
        switch (check, area) {
        case (nil, nil):
            add(1, "sem-check", tr("tarefa sem --area e sem --check: o laço não tem como julgá-la; escreva 'check: <comando que roda o teste>' ou 'area: <área do collie-work.json>'", "task with no --area and no --check: the loop cannot judge it; write 'check: <command that runs the test>' or 'area: <area from collie-work.json>'"))
        case (let c?, _?):
            add(c.line, "area-e-check", tr("'area:' e 'check:' não andam juntos: 'area:' monta o check a partir do collie-work.json; use um ou outro", "'area:' and 'check:' do not go together: 'area:' builds the check from collie-work.json; use one or the other"))
        case (let c?, nil):
            if let why = checkRefusal(c.value) { add(c.line, "check-inexecutavel", why) }
            else if let why = trivialCheck(c.value, scope: t.list("scope"), body: t.text.components(separatedBy: "\n").enumerated()
                .filter { $0.offset + 1 != c.line }.map(\.element).joined(separator: "\n")) { add(c.line, "check-trivial", why) }
        case (nil, let a?):
            if TaskScheduler.list(a.value).isEmpty { add(a.line, "check-inexecutavel", tr("'area:' vazia: nomeie as áreas do collie-work.json", "'area:' is empty: name the areas of collie-work.json")) }
        }
        if t.text.range(of: testCited, options: .regularExpression) == nil {
            add(1, "sem-teste", tr("tarefa sem teste citado: nomeie o teste que prova a tarefa (ex.: PrdStoreTests, test_login, login.test.ts)", "task with no test cited: name the test that proves the task (e.g. PrdStoreTests, test_login, login.test.ts)"))
        }
        if let n = t.fields["needs"] {
            for x in t.list("needs") where x == t.id || !known.contains(x) {
                add(n.line, "needs", x == t.id ? tr("a tarefa não pode depender dela mesma", "a task cannot depend on itself") : tr("'\(x)' não é tarefa deste plano", "'\(x)' is not a task of this plan"))
            }
        }
        return f
    }

    /// A name of a test: `FooTests`, `FooSpec`, `test_foo`, `foo_test`, `foo.test.ts`, a path under `tests/`.
    static let testCited = #"[A-Za-z0-9](Tests?|Spec)\b|\btest_[A-Za-z0-9_]+|\b[A-Za-z0-9]+_test\b|\.(test|spec)\.[A-Za-z]+\b|(^|[\s/`'"(])([Tt]ests?|spec)/"#

    /// Why a check runs nothing worth judging; nil: it runs something. Empty, a placeholder left in it, or only
    /// commands that always pass.
    static func checkRefusal(_ c: String) -> String? {
        let t = c.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return tr("check vazio: escreva o comando que roda o teste da tarefa", "empty check: write the command that runs the task's test") }
        // C4a: `<x>` and `...` only as a whole word (`<comando>`): `grep "<div>"` and `diff <(a) <(b)` are commands
        let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
        if t.range(of: #"\b(TODO|TBD|FIXME|XXX)\b"#, options: .regularExpression) != nil
            || words.contains(where: { $0 == "..." || $0.range(of: #"^<[^<>\s()]+>$"#, options: .regularExpression) != nil }) {
            return tr("check com marcador por preencher («\(RerailText.clean(t, max: 200))»): escreva o comando de verdade", "check with an unfilled placeholder («\(RerailText.clean(t, max: 200))»): write the real command")
        }
        let cmds = commands(t)
        if cmds.allSatisfy({ trivial.contains($0.first ?? "") }) {
            return tr("check que não verifica nada («\(RerailText.clean(t, max: 200))»): ele passa sem rodar teste", "check that verifies nothing («\(RerailText.clean(t, max: 200))»): it passes without running a test")
        }
        return nil
    }

    /// C4a: why a check passes without running the code; nil: some piece of it runs something (a build, a test, a
    /// script, a project command). Cut at `&&`, `||`, `;`, `|`: one that `swallows` its failure is always green; one whose
    /// every piece is an inspector (`inspectors`), always passes (`trivial`) or is a `cd` judges no code. The
    /// message names the task's own file it inspects (in `scope`, or named in `body`; `./` dropped) when there is one.
    // ponytail: a heuristic on the words, no shell parsing: `bash -c 'grep x f'` or a script that only greps passes.
    // The linter refuses the plain shapes; the review and the gate stay the real judges.
    static func trivialCheck(_ c: String, scope: [String], body: String) -> String? {
        let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if swallows(t) {
            return tr("o check engole a falha (termina em «|| true», «|| echo», «; exit 0», «| true»…): ele fica verde sempre; rode o teste sem isso", "the check swallows the failure (it ends in «|| true», «|| echo», «; exit 0», «| true»…): it is always green; run the test without that")
        }
        // C5b: `diff <(swift run a) golden` runs code in its substitution
        let inner = t.matches(of: /[<>$]\(\s*([^\s()]+)/).map { String($0.1) }
        if inner.contains(where: { !inspectors.contains($0) && !trivial.contains($0) }) { return nil }
        // C5b: a `cd` is neutral: `cd x && grep -q y f` only inspects
        let cmds = commands(t).map { Array($0.drop { $0 == "!" }) }.filter { !$0.isEmpty && $0[0] != "cd" }
        guard !cmds.isEmpty, cmds.allSatisfy({ inspectors.contains($0[0]) || trivial.contains($0[0]) }) else { return nil }
        func norm(_ p: String) -> String { var s = p[...]; while s.hasPrefix("./") { s = s.dropFirst(2) }; return String(s) }
        var files: [String] = []
        for cmd in cmds where inspectors.contains(cmd[0]) {
            var args = cmd.dropFirst().filter { !$0.hasPrefix("-") && !["]", "]]", "!"].contains($0) }
            if ["grep", "egrep", "fgrep", "rg", "sed", "awk"].contains(cmd[0]) { args = Array(args.dropFirst()) }   // the pattern
            files += args.map { norm($0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))) }.filter { !$0.isEmpty }
        }
        let scope = scope.map(norm)
        let own = files.first { f in scope.contains { TaskScheduler.globsOverlap(f, $0) } || body.contains(f) }
        return own.map { tr("o check só inspeciona o arquivo que a tarefa cria (\($0)): ele passa sem o código funcionar; rode o teste", "the check only inspects the file the task creates (\($0)): it passes without the code working; run the test") }
            ?? tr("o check só inspeciona arquivos (grep, test, cat, diff…) e não roda código: ele passa sem o código funcionar; rode o teste ou o script do projeto", "the check only inspects files (grep, test, cat, diff…) and runs no code: it passes without the code working; run the test or the project's script")
    }

    /// C5b: the check ends in a command that always passes (`true`, `:`, `echo`, `printf`, `exit 0`) after `||`, `;`, `|`
    /// or a newline: whatever ran before it, the check is green. Only the LAST top-level piece counts (`swift build;
    /// echo ---; swift test` is a check); a `( … )` group ending the check is judged by its own last piece
    /// (`swift test || (echo falhou; exit 1)` fails). Comments (`# …`) dropped first.
    // ponytail: no quoting rules, like `commands`.
    static func swallows(_ s: String) -> Bool {
        func last(_ s: String) -> (sep: String?, piece: String) {
            let c = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
            var depth = 0, i = 0, cut = 0, sep: String?
            while i < c.count {
                let two = i + 1 < c.count ? String(c[i...i + 1]) : ""
                if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1 }
                else if depth == 0, two == "&&" || two == "||" { sep = two; i += 2; cut = i; continue }
                else if depth == 0, c[i] == ";" || c[i] == "|" || c[i] == "\n" { sep = String(c[i]); cut = i + 1 }
                i += 1
            }
            let piece = String(c[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // a trailing `;` or newline closes the piece before it
            if piece.isEmpty, cut > 0, sep == ";" || sep == "\n" { return last(String(c[..<(cut - 1)])) }
            if piece.hasPrefix("("), piece.hasSuffix(")") {
                let g = last(String(piece.dropFirst().dropLast()))
                return (g.sep ?? sep, g.piece)
            }
            return (sep, piece)
        }
        let (sep, piece) = last(s.replacingOccurrences(of: #"(?m)(^|\s)#.*$"#, with: "", options: .regularExpression))
        guard let sep, ["||", ";", "|", "\n"].contains(sep), let w = commands(piece).first, let cmd = w.first else { return false }
        return cmd == "exit" ? w.dropFirst().elementsEqual(["0"]) : ["true", ":", "echo", "printf"].contains(cmd)
    }

    /// A shell line cut at `&&`, `||`, `;`, `|` and newlines, each piece its words, leading `VAR=value`s dropped.
    /// ponytail: no quoting rules; a `;` inside quotes splits too (a check is a short command line).
    static func commands(_ s: String) -> [[String]] {
        s.replacingOccurrences(of: #"&&|\|\||;|\||\n"#, with: "\u{0}", options: .regularExpression)
            .split(separator: "\u{0}").map { piece in
                Array(piece.split(whereSeparator: \.isWhitespace).map(String.init)
                    .drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil })
            }.filter { !$0.isEmpty }
    }

    /// The first cycle of `needs` (the waves' and the cards'), at the `needs:` line of a task on it.
    static func cycle(_ tasks: [Task]) -> (file: String, line: Int, path: [String])? {
        let by = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var clear: Set<String> = []
        func walk(_ n: String, _ path: [String]) -> [String]? {
            if let i = path.firstIndex(of: n) { return Array(path[i...]) + [n] }
            if clear.contains(n) { return nil }
            for m in by[n]?.needs ?? [] where m != n {   // needing itself is `findings`' refusal
                if let c = walk(m, path + [n]) { return c } }
            clear.insert(n)
            return nil
        }
        for t in tasks {
            guard let c = walk(t.id, []) else { continue }
            // the waves only point back: some task on the cycle has its own `needs:`
            let at = c.compactMap { by[$0] }.first { $0.fields["needs"] != nil } ?? by[c[0]]
            return (at?.file ?? "waves.md", at?.fields["needs"]?.line ?? 1, c)
        }
        return nil
    }

    /// The JSON of `work plan lint --json`.
    static func json(_ p: Plan) -> JSONValue {
        .object(["passed": .bool(p.passed), "hash": .string(p.hash), "dir": .string(p.dir.path), "waves": .number(Double(p.waves)),
                 "gate": p.gate.map { .string($0) } ?? .null,
                 "findings": .array(p.findings.map { .object(["file": .string($0.file), "line": .number(Double($0.line)),
                                                              "rule": .string($0.rule), "message": .string($0.message)]) }),
                 "tasks": .array(p.tasks.map { .object(["id": .string($0.id), "title": .string($0.title), "wave": .number(Double($0.wave + 1)),
                                                        "needs": .array($0.needs.map { .string($0) })]) }),
                 "output": .string(p.text)])
    }
}
