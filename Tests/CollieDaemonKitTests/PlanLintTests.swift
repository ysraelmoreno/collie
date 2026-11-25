import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A plan package written to a temporary folder: `waves.md` and `tasks/<id>.md`.
struct PlanFixture {
    let dir = URL(fileURLWithPath: "/tmp/collie-plan-\(UUID().uuidString.prefix(8))")
    init(waves: String, tasks: [String: String]) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try Data(waves.utf8).write(to: dir.appendingPathComponent("waves.md"))
        for (id, text) in tasks { try Data(text.utf8).write(to: dir.appendingPathComponent("tasks/\(id).md")) }
    }
    func write(_ rel: String, _ text: String) throws { try Data(text.utf8).write(to: dir.appendingPathComponent(rel)) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    static let waves = "# Ondas\ngate: scripts/ci/lint.sh\n\n## Onda 1\n- login\n- api\n\n## Onda 2\n- tela\n"
    static func card(_ title: String, check: String = "swift test --filter LoginTests", extra: String = "") -> String {
        "# \(title)\n\ncheck: \(check)\n\(extra)\nO que fazer: \(title). Prova: LoginTests.\n"
    }
    static var good: [String: String] {
        ["login": card("Login"), "api": card("API", check: "swift test --filter ApiTests"),
         "tela": card("Tela", check: "swift test --filter TelaTests", extra: "accept: curl -fsS localhost:8080/health\nneeds: login")]
    }
}

/// F5, `work plan lint`: each refusal with its file and line; a good package passes, with its hash.
@Suite struct PlanLintTests {
    private func rules(_ p: PlanLint.Plan) -> [String] { p.findings.map { "\($0.file):\($0.line):\($0.rule)" } }

    @Test func aGoodPackagePasses() throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        #expect(p.passed, "\(p.text)")
        #expect(p.tasks.map(\.id) == ["login", "api", "tela"] && p.waves == 2 && p.gate == "scripts/ci/lint.sh")
        #expect(p.tasks[2].needs == ["login", "api"] && p.tasks[0].needs.isEmpty)
        #expect(p.hash.count == 64 && p.text.contains("--approve \(p.hash)"))
        // the hash is the package's: the same files, the same hash; one byte more, another
        #expect(PlanLint.lint(f.dir).hash == p.hash)
        try f.write("tasks/api.md", PlanFixture.card("API", check: "swift test --filter ApiTests") + " ")
        #expect(PlanLint.lint(f.dir).hash != p.hash)
    }

    @Test func theModelPackagePasses() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fabrica/modelos/plano")
        let p = PlanLint.lint(dir)
        #expect(p.passed, "\(p.text)")
        #expect(p.tasks.map(\.id) == ["login-email", "tela-login"] && p.tasks[1].needs == ["login-email"])
    }

    @Test func aTaskWithNoAreaNorCheckIsRefused() throws {
        var t = PlanFixture.good; t["api"] = "# API\n\nSem check. Prova: ApiTests.\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:sem-check"])
    }

    @Test func aCheckThatRunsNothingIsRefusedAtItsLine() throws {
        for c in ["true", "echo ok && true", "TODO", "swift test --filter <Nome>", "..."] {
            var t = PlanFixture.good; t["api"] = PlanFixture.card("API", check: c)
            let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
            #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:3:check-inexecutavel"], "\(c)")
        }
    }

    @Test func aCheckThatOnlyInspectsTheTasksOwnFileIsRefused() throws {
        var t = PlanFixture.good
        t["api"] = PlanFixture.card("API", check: "test -f Sources/Api.swift && grep -q route Sources/Api.swift", extra: "scope: Sources/Api.swift")
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        #expect(rules(p) == ["tasks/api.md:3:check-trivial"])
        #expect(p.findings[0].message.contains("Sources/Api.swift"))
        // C4a: a grep of another file runs no code either: refused too (once it named the task's file only)
        try f.write("tasks/api.md", PlanFixture.card("API", check: "grep -q route docs/rotas.md", extra: "scope: Sources/**"))
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:3:check-trivial"])
        // a check that runs the test alongside is fine
        try f.write("tasks/api.md", PlanFixture.card("API", check: "test -f Sources/Api.swift && swift test --filter ApiTests", extra: "scope: Sources/**"))
        #expect(PlanLint.lint(f.dir).passed)
    }

    /// C4a: the check cut at `&&`, `||`, `;`, `|`: one that swallows its failure, or whose every piece only inspects
    /// files or always passes, is `check-trivial`; one piece that runs code makes it a check.
    @Test func aCheckThatAlwaysPassesOrRunsNoCodeIsTrivial() throws {
        for c in ["grep -q rota Sources/Api.swift || true", "swift test --filter ApiTests || true", "swift test --filter ApiTests; true",
                  "swift test --filter ApiTests || :", "grep -q rota Sources/Api.swift && echo ok", "cat Sources/Api.swift | wc -l",
                  "find Sources -name Api.swift", "diff a.txt b.txt", "! grep -q FIXO Sources/Api.swift", "stat Sources/Api.swift && head -1 x",
                  "test -f ./Sources/Api.swift"] {
            var t = PlanFixture.good; t["api"] = PlanFixture.card("API", check: c, extra: "scope: Sources/Api.swift")
            let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
            #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:3:check-trivial"], "\(c)")
        }
        // `./path` is the task's own file
        #expect(PlanLint.trivialCheck("test -f ./Sources/Api.swift", scope: ["Sources/Api.swift"], body: "")?.contains("(Sources/Api.swift)") == true)
        for c in ["swift test --filter ApiTests", "scripts/check.sh", "make check && grep -q ok out.txt", "grep -q x a.txt && swift build --build-tests",
                  "swift test --filter ApiTests && grep -q \"<div>\" out.html", "true && bash scripts/check.sh"] {
            var t = PlanFixture.good; t["api"] = PlanFixture.card("API", check: c, extra: "scope: Sources/Api.swift")
            let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
            #expect(PlanLint.lint(f.dir).passed, "\(c)")
        }
    }

    /// C5b: a command that always passes (true, :, echo, printf, exit 0) after `||`, `;`, `|` or a newline, ending the
    /// check, makes it always green whatever ran before; a real check that does not end so stays valid. A `cd` is
    /// neutral when judging a check that only inspects; a substitution that runs code (`diff <(swift run a) golden`) runs code.
    @Test func aTrivialCommandEndingTheCheckSwallowsItsFailure() throws {
        for c in ["swift test --filter ApiTests || echo ok", "swift test --filter ApiTests || exit 0", "swift test --filter ApiTests; exit 0",
                  "swift test --filter ApiTests | true", "swift test --filter ApiTests || true # comentário",
                  "swift test --filter ApiTests || printf 'falhou\\n'",
                  "swift test --filter ApiTests || (echo falhou)", "swift test --filter ApiTests || true;",
                  "cd Sources && grep -q rota Api.swift"] {
            var t = PlanFixture.good; t["api"] = PlanFixture.card("API", check: c, extra: "scope: Sources/Api.swift")
            let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
            #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:3:check-trivial"], "\(c)")
        }
        for c in ["swift test --filter ApiTests || scripts/check.sh", "swift build; echo ---; swift test --filter ApiTests",
                  "swift test --filter ApiTests || (echo falhou; exit 1)", "swift test --filter ApiTests && echo ok",
                  "swift test --filter ApiTests || exit 1", "diff <(swift run a) golden.txt", "cd Sources && swift test --filter ApiTests",
                  "grep -q \"#x\" a.txt && swift test --filter ApiTests"] {
            var t = PlanFixture.good; t["api"] = PlanFixture.card("API", check: c, extra: "scope: Sources/Api.swift")
            let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
            #expect(PlanLint.lint(f.dir).passed, "\(c)")
        }
        // a newline cuts like `;` (a card's check is one line; a `collie-work.json` one may not be)
        #expect(PlanLint.swallows("swift test\necho fim") && !PlanLint.swallows("echo inicio\nswift test"))
    }

    /// C4a: `<x>` and `...` are placeholders only as whole words: `grep "<div>"` and `diff <(a) <(b)` are commands.
    @Test func aPlaceholderIsAWholeWord() {
        for c in ["grep \"<div>\" index.html", "diff <(a) <(b)", "echo a...b && make", "grep -q '<a href>' x"] {
            #expect(PlanLint.checkRefusal(c) == nil, "\(c)")
        }
        for c in ["swift test --filter <teste>", "<comando>", "make ...", "TODO"] {
            #expect(PlanLint.checkRefusal(c) != nil, "\(c)")
        }
    }

    /// C4a: `tasks`, `waves.md` and each card are `lstat`ed before any read: a link (even to a folder of good cards out
    /// of the project), a package reached by `..` out of the project: `plan-unsafe-path`, the lint fails.
    @Test func linksAndPathsOutOfTheProjectAreRefused() throws {
        let out = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { out.cleanup() }
        let fm = FileManager.default
        // the folder `tasks` a link to good cards elsewhere
        let a = try PlanFixture(waves: PlanFixture.waves, tasks: [:]); defer { a.cleanup() }
        try fm.removeItem(at: a.dir.appendingPathComponent("tasks"))
        try fm.createSymbolicLink(at: a.dir.appendingPathComponent("tasks"), withDestinationURL: out.dir.appendingPathComponent("tasks"))
        let pa = PlanLint.lint(a.dir)
        #expect(!pa.passed && rules(pa).contains("tasks:1:plan-unsafe-path") && pa.tasks.isEmpty, "\(pa.text)")
        // one card a link
        let b = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { b.cleanup() }
        try fm.removeItem(at: b.dir.appendingPathComponent("tasks/api.md"))
        try fm.createSymbolicLink(at: b.dir.appendingPathComponent("tasks/api.md"), withDestinationURL: out.dir.appendingPathComponent("tasks/api.md"))
        #expect(rules(PlanLint.lint(b.dir)) == ["tasks/api.md:1:plan-unsafe-path"])
        // waves.md a link
        let c = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { c.cleanup() }
        try fm.removeItem(at: c.dir.appendingPathComponent("waves.md"))
        try fm.createSymbolicLink(at: c.dir.appendingPathComponent("waves.md"), withDestinationURL: out.dir.appendingPathComponent("waves.md"))
        #expect(rules(PlanLint.lint(c.dir)).first == "waves.md:1:plan-unsafe-path")
        // `..`: the package out of the project it must lie in
        let up = URL(fileURLWithPath: out.dir.path + "/tasks/..")
        let pu = PlanLint.lint(up, root: out.dir.appendingPathComponent("tasks"))
        #expect(!pu.passed && rules(pu).contains(".:1:plan-unsafe-path"), "\(pu.text)")
        #expect(PlanLint.lint(up, root: out.dir).passed)
    }

    /// C4a: a card that does not open (a folder, no read permission) is a `task-unreadable` finding with its file.
    @Test func anUnreadableCardIsSaid() throws {
        var t = PlanFixture.good; t["api"] = nil
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.dir.appendingPathComponent("tasks/api.md"), withIntermediateDirectories: true)
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:task-unreadable"])
        try FileManager.default.removeItem(at: f.dir.appendingPathComponent("tasks/api.md"))
        try f.write("tasks/api.md", PlanFixture.card("API", check: "swift test --filter ApiTests"))
        chmod(f.dir.appendingPathComponent("tasks/api.md").path, 0)
        defer { chmod(f.dir.appendingPathComponent("tasks/api.md").path, 0o644) }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:task-unreadable"])
    }

    @Test func areaAndCheckTogetherAreRefused() throws {
        var t = PlanFixture.good; t["api"] = PlanFixture.card("API", extra: "area: api")
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:3:area-e-check"])
        // an area alone is a check
        try f.write("tasks/api.md", "# API\n\narea: api\n\nProva: ApiTests.\n")
        #expect(PlanLint.lint(f.dir).passed)
    }

    @Test func aCardOver1500CharactersIsRefused() throws {
        var t = PlanFixture.good; t["api"] = PlanFixture.card("API") + String(repeating: "x", count: 1500)
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:cartao-grande"])
    }

    @Test func aCycleInNeedsIsRefusedAtANeedsLine() throws {
        var t = PlanFixture.good; t["login"] = PlanFixture.card("Login", extra: "needs: tela")
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        #expect(rules(p) == ["tasks/login.md:4:ciclo"], "\(p.text)")
        #expect(p.findings[0].message.contains("login → tela → login"))
        // an unknown task in needs, and needing itself
        t["login"] = PlanFixture.card("Login", extra: "needs: nada, login")
        let g = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { g.cleanup() }
        #expect(rules(PlanLint.lint(g.dir)) == ["tasks/login.md:4:needs", "tasks/login.md:4:needs"])
    }

    @Test func aTaskWithNoTestCitedIsRefused() throws {
        var t = PlanFixture.good; t["api"] = "# API\n\ncheck: make check\n\nFazer a API.\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:sem-teste"])
        for cited in ["test_login", "login_test", "login.test.ts", "tests/api.py", "ApiSpec"] {
            try f.write("tasks/api.md", "# API\n\ncheck: make check\n\nProva: \(cited).\n")
            #expect(PlanLint.lint(f.dir).passed, "\(cited)")
        }
    }

    @Test func theWavesFileIsCheckedWithItsLines() throws {
        let f = try PlanFixture(waves: "- solta\n## Onda 1\n- login\n- login\n- falta\n## Onda 2\n- tela\n", tasks: PlanFixture.good); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["waves.md:1:onda", "waves.md:4:onda", "waves.md:5:onda", "tasks/api.md:1:onda"])
        let g = try PlanFixture(waves: "", tasks: [:]); defer { g.cleanup() }
        try? FileManager.default.removeItem(at: g.dir.appendingPathComponent("waves.md"))
        #expect(rules(PlanLint.lint(g.dir)) == ["waves.md:1:onda", "tasks:1:onda"])
    }

    @Test func fieldsInsideACodeFenceAreText() throws {
        var t = PlanFixture.good; t["api"] = "# API\n\n```\ncheck: swift test --filter ApiTests\n```\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        #expect(rules(PlanLint.lint(f.dir)) == ["tasks/api.md:1:sem-check"])
    }

    @Test func theJsonCarriesTheFindings() throws {
        var t = PlanFixture.good; t["api"] = "# API\n\nSem check. Prova: ApiTests.\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        guard case .object(let o) = PlanLint.json(PlanLint.lint(f.dir)), case .array(let fs)? = o["findings"] else { Issue.record("json"); return }
        #expect(o["passed"] == .bool(false) && fs.count == 1)
        guard case .object(let first) = fs[0] else { Issue.record("finding"); return }
        #expect(first["file"] == .string("tasks/api.md") && first["line"] == .number(1) && first["rule"] == .string("sem-check"))
    }
}
