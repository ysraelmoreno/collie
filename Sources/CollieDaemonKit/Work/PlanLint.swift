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
    /// The commands a check made only of these inspects files, never runs the code.
    static let inspectors: Set<String> = ["grep", "egrep", "fgrep", "rg", "test", "[", "[[", "ls"]

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
            var l = ["Plano \(dir.path): \(tasks.count) tarefa(s) em \(waves) onda(s) · pacote sha256 \(hash)"]
            if let gate { l.append("portão: \(RerailText.clean(gate, max: 300))") }
            l += findings.map { "\($0.file):\($0.line): [\($0.rule)] \($0.message)" }
            l.append(passed ? "Passou. Para aprovar este pacote: collie work plan apply \(dir.path) --approve \(hash)"
                            : "Recusado: \(findings.count) problema(s).")
            return l.joined(separator: "\n")
        }
    }

    static func lint(_ dir: URL) -> Plan {
        var f: [Finding] = []
        func add(_ file: String, _ line: Int, _ rule: String, _ m: String) { f.append(Finding(file: file, line: line, rule: rule, message: m)) }
        var hashed: [(name: String, data: Data)] = []
        func readText(_ name: String) -> String? {
            let url = dir.appendingPathComponent(name)
            guard let d = PrdStore.read(url) else { return nil }
            hashed.append((name, d))
            guard d.count <= fileMax else {
                add(name, 1, "cartao-grande", "arquivo com \(d.count) bytes; um cartão tem até \(cardMax) caracteres"); return nil
            }
            guard let s = String(data: d, encoding: .utf8) else { add(name, 1, "texto", "não é texto UTF-8"); return nil }
            return s
        }

        // waves.md
        var waves: [[(id: String, line: Int)]] = []
        var gate: String?
        if let text = readText("waves.md") {
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("## ") { waves.append([]); continue }
                if l.hasPrefix("gate:") { gate = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
                guard l.hasPrefix("- ") || l.hasPrefix("* ") else { continue }
                let id = String(l.dropFirst(2).prefix { !$0.isWhitespace && $0 != ":" }).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                guard !waves.isEmpty else { add("waves.md", i + 1, "onda", "tarefa '\(id)' fora de onda: ponha-a sob um título '## Onda N'"); continue }
                waves[waves.count - 1].append((id, i + 1))
            }
        } else if !hashed.contains(where: { $0.name == "waves.md" }) {
            add("waves.md", 1, "onda", "não há waves.md em \(dir.path): ele lista as tarefas por onda ('## Onda 1', '- <id>')")
        }
        waves.removeAll { $0.isEmpty }
        if waves.isEmpty && hashed.contains(where: { $0.name == "waves.md" }) { add("waves.md", 1, "onda", "nenhuma tarefa listada: '## Onda 1' e, embaixo, '- <id>' de cada tarefa") }

        // tasks/*.md
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tasks").path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
        if names.isEmpty { add("tasks", 1, "onda", "não há tasks/*.md em \(dir.path): um cartão por tarefa, tasks/<id>.md") }
        var cards: [String: (url: URL, text: String)] = [:]
        for n in names {
            let rel = "tasks/" + n
            if let t = readText(rel) { cards[String(n.dropLast(3))] = (dir.appendingPathComponent(rel), t) }
        }
        let allIds = Set(names.map { String($0.dropLast(3)) })

        var tasks: [Task] = [], listed: [String: Int] = [:]
        for (w, wave) in waves.enumerated() {
            for (id, line) in wave {
                if let first = listed[id] { add("waves.md", line, "onda", "a tarefa '\(id)' já está na linha \(first)"); continue }
                listed[id] = line
                if id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$"#, options: .regularExpression) == nil {
                    add("waves.md", line, "onda", "id '\(id)' inválido: letras, números, '.', '_' e '-', até 40"); continue
                }
                guard allIds.contains(id) else { add("waves.md", line, "onda", "a tarefa '\(id)' não tem cartão: crie tasks/\(id).md"); continue }
                guard let c = cards[id] else { continue }   // unreadable: already a finding
                tasks.append(parse(id, wave: w, url: c.url, text: c.text))
            }
        }
        for id in allIds.sorted() where listed[id] == nil {
            add("tasks/\(id).md", 1, "onda", "a tarefa '\(id)' não está em nenhuma onda do waves.md")
        }
        for i in tasks.indices where tasks[i].wave > 0 {
            tasks[i].waveNeeds = tasks.filter { $0.wave == tasks[i].wave - 1 }.map(\.id)
        }
        let ids = Set(tasks.map(\.id))
        for t in tasks { f += findings(t, known: ids.union(allIds)) }
        if let c = cycle(tasks) { add(c.file, c.line, "ciclo", "ciclo em needs: " + c.path.joined(separator: " → ")) }

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
            add(1, "cartao-grande", "cartão com \(t.text.count) caracteres; o limite é \(cardMax): corte o texto ou divida a tarefa")
        }
        let check = t.fields["check"], area = t.fields["area"]
        switch (check, area) {
        case (nil, nil):
            add(1, "sem-check", "tarefa sem --area e sem --check: o laço não tem como julgá-la; escreva 'check: <comando que roda o teste>' ou 'area: <área do collie-work.json>'")
        case (let c?, _?):
            add(c.line, "area-e-check", "'area:' e 'check:' não andam juntos: 'area:' monta o check a partir do collie-work.json; use um ou outro")
        case (let c?, nil):
            if let why = checkRefusal(c.value) { add(c.line, "check-inexecutavel", why) }
            else if let file = ownFileInspected(c.value, t) {
                add(c.line, "check-trivial", "o check só faz grep/test -f/ls no arquivo que a tarefa cria (\(file)): ele passa sem o código funcionar; rode o teste")
            }
        case (nil, let a?):
            if TaskScheduler.list(a.value).isEmpty { add(a.line, "check-inexecutavel", "'area:' vazia: nomeie as áreas do collie-work.json") }
        }
        if t.text.range(of: testCited, options: .regularExpression) == nil {
            add(1, "sem-teste", "tarefa sem teste citado: nomeie o teste que prova a tarefa (ex.: PrdStoreTests, test_login, login.test.ts)")
        }
        if let n = t.fields["needs"] {
            for x in t.list("needs") where x == t.id || !known.contains(x) {
                add(n.line, "needs", x == t.id ? "a tarefa não pode depender dela mesma" : "'\(x)' não é tarefa deste plano")
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
        if t.isEmpty { return "check vazio: escreva o comando que roda o teste da tarefa" }
        if t.range(of: #"\b(TODO|TBD|FIXME|XXX)\b|<[^<>\s]+>|\.\.\."#, options: .regularExpression) != nil {
            return "check com marcador por preencher («\(RerailText.clean(t, max: 200))»): escreva o comando de verdade"
        }
        let cmds = commands(t)
        if cmds.allSatisfy({ ["true", ":", "echo", "printf", "exit"].contains($0.first ?? "") }) {
            return "check que não verifica nada («\(RerailText.clean(t, max: 200))»): ele passa sem rodar teste"
        }
        return nil
    }

    /// The file a check made only of grep/test/ls inspects that is the task's own (in its `scope:`, or named in its
    /// card; with no scope, any); nil: the check runs something else, or inspects only other files.
    static func ownFileInspected(_ c: String, _ t: Task) -> String? {
        let cmds = commands(c)
        guard !cmds.isEmpty, cmds.allSatisfy({ inspectors.contains($0.first ?? "") }) else { return nil }
        var files: [String] = []
        for cmd in cmds {
            var args = cmd.dropFirst().filter { !$0.hasPrefix("-") && !["]", "]]", "!"].contains($0) }
            if ["grep", "egrep", "fgrep", "rg"].contains(cmd[0]) { args = Array(args.dropFirst()) }   // the pattern
            files += args.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }.filter { !$0.isEmpty }
        }
        let scope = t.list("scope")
        let body = t.text.components(separatedBy: "\n").enumerated().filter { $0.offset + 1 != t.fields["check"]?.line }.map(\.element).joined(separator: "\n")
        return files.first { f in scope.isEmpty || scope.contains { TaskScheduler.globsOverlap(f, $0) } || body.contains(f) }
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
