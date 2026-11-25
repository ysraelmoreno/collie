import Testing
import Foundation
import CollieCore

/// U2: the stack models of `/collie:factory init` (docs/fabrica/modelos/<stack>/) are valid profiles and score as a working static layer.
private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let modelos = repo.appendingPathComponent("docs/fabrica/modelos")

private func text(_ u: URL) throws -> String { String(decoding: try Data(contentsOf: u), as: UTF8.self) }

/// A new folder from mkdtemp in the system temporary folder (no fixed path).
private func tempDir() throws -> URL {
    var tpl = Array((NSTemporaryDirectory() + "collie-gate-XXXXXX").utf8CString)
    guard mkdtemp(&tpl) != nil else { throw CocoaError(.fileWriteUnknown) }
    return URL(fileURLWithPath: tpl.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
}
private func put(_ dir: URL, _ rel: String, _ body: String) throws {
    let u = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: u)
}

/// Runs `bash scripts/<script> <args>` (gate.sh by default) of the model `stack` in a project made of `files`, with the runners
/// (`swift`, `npx`, `python3`) swapped for a stub that prints its arguments and exits 0 (`stubs` overrides one by name); `links`
/// are symlinks (path: target). F6b: `prep` makes the folder a git repository with everything not ignored added, since the gate
/// looks only at what git sees. F7b: `noGit` leaves git out of the script's PATH. Returns the exit code and stdout + stderr.
private func runGate(_ stack: String, _ files: [String: String], links: [String: String] = [:],
                     stubs: [String: String] = [:], prep: String = "git init -q && git add -A", noGit: Bool = false,
                     script: String = "gate.sh", args: [String] = []) throws -> (status: Int32, out: String) {
    let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
    for s in ["gate.sh", "check-feature.sh"] {
        try put(d, "scripts/\(s)", try text(modelos.appendingPathComponent("\(stack)/scripts/\(s)")))
    }
    for (rel, body) in files { try put(d, rel, body) }
    for (rel, target) in links { try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent(rel).path, withDestinationPath: target) }
    for runner in ["swift", "npx", "python3"] {
        try put(d, "stub/\(runner)", stubs[runner] ?? "#!/bin/bash\necho \"stub \(runner) $*\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.appendingPathComponent("stub/\(runner)").path)
    }
    let env = ["PATH": d.appendingPathComponent("stub").path + ":/usr/bin:/bin", "HOME": d.path]
    let g = Process()
    g.executableURL = URL(fileURLWithPath: "/bin/bash")
    g.arguments = ["-c", prep]
    g.currentDirectoryURL = d; g.environment = env
    try g.run(); g.waitUntilExit()
    #expect(g.terminationStatus == 0, "prep: \(prep)")
    var runEnv = env
    if noGit {   // only the tools the scripts call, git left out
        let bin = d.appendingPathComponent("nogit")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for t in ["dirname", "mktemp", "rm", "env", "awk"] {
            let src = ["/usr/bin/\(t)", "/bin/\(t)"].first { FileManager.default.isExecutableFile(atPath: $0) }!
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(t).path, withDestinationPath: src)
        }
        runEnv["PATH"] = d.appendingPathComponent("stub").path + ":" + bin.path
    }
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["scripts/\(script)"] + args
    p.currentDirectoryURL = d
    p.environment = runEnv
    p.standardOutput = pipe; p.standardError = pipe
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

/// The project the skill would generate from one model: the profile as `collie-work.json`, its scripts, its CI skeleton,
/// the default personas at `docs/fabrica/personas`.
private func snapshot(_ stack: String) throws -> FactoryDoctor.Snapshot {
    let dir = modelos.appendingPathComponent(stack)
    let config: ProjectWorkConfig
    switch ProjectWorkConfig.parse(try Data(contentsOf: dir.appendingPathComponent("profile.json"))) {
    case .success(let ok):
        #expect(ok.warnings.isEmpty, "\(stack): \(ok.warnings)")
        config = ok.config
    case .failure(let e): Issue.record("\(stack)/profile.json: \(e.message)"); throw e
    }
    var scripts: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts").path) {
        scripts["scripts/\(name)"] = try text(dir.appendingPathComponent("scripts/\(name)"))
    }
    let personas = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("docs/fabrica/personas").path)
        .filter { $0.hasSuffix(".md") }.map { "docs/fabrica/personas/\($0)" }
    // F5b: the configs the gate's text cites after `#` exist in the project (the init keeps only those)
    let configs = (config.gate ?? "").split(separator: "#", maxSplits: 1).dropFirst().first.map { $0.split(separator: " ").map(String.init) } ?? []
    return FactoryDoctor.Snapshot(config: config, scripts: scripts, paths: (Array(scripts.keys) + personas + configs).sorted(),
                                  ci: [".github/workflows/ci.yml": try text(dir.appendingPathComponent("ci.yml"))])
}

@Suite struct FactoryModelsTests {
    @Test func theThreeStacksHaveAModel() throws {
        let stacks = try FileManager.default.contentsOfDirectory(atPath: modelos.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(stacks == ["node", "python", "swift"])
        for s in stacks {
            for f in ["profile.json", "ci.yml", "README.md", "scripts/check-feature.sh", "scripts/gate.sh"] {
                #expect(FileManager.default.fileExists(atPath: modelos.appendingPathComponent("\(s)/\(f)").path), "\(s)/\(f)")
            }
            #expect(try text(modelos.appendingPathComponent("\(s)/README.md")).contains("Dono"), "\(s): README sem dono")
        }
    }

    @Test(arguments: ["swift", "node", "python"])
    func modelIsAValidProfileThatRunsTests(_ stack: String) throws {
        let s = try snapshot(stack)
        let f = try #require(s.config?.factory, "\(stack): profile.json sem factory")
        #expect(!f.ratchets.isEmpty && !f.personas.isEmpty, "\(stack)")

        let st = FactoryDoctor.staticLayer(s)
        #expect(st.score >= 2, "\(stack): static \(st.score) \(st.evidence)")
        #expect(FactoryDoctor.score(s).layers.first { $0.layer == .static }?.score == st.score)

        // every persona the profile names is a default persona the skill copies
        let review = FactoryDoctor.review(s)
        #expect(!review.evidence.contains { $0.hasPrefix("aviso:") }, "\(stack): \(review.evidence)")
        // the task check runs tests and is never a file/word lookup; the CI runs the gate
        for (p, body) in s.scripts {
            #expect(!FactoryDoctor.onlyLooksForFiles(body), "\(stack)/\(p) só procura arquivo")
            #expect(FactoryDoctor.testRunnerSource(p, s.scripts) != nil, "\(stack)/\(p) não roda teste")
        }
        #expect(FactoryDoctor.ciCiting(s.config!.gate!, s.ci) != nil, "\(stack): ci.yml não roda o gate")
        // F3: the gate cites a versioned script (scripts/gate.sh), so the judge guards it: 3, not the 2 of a bare gate.
        // F6b (M2): its text cites only pure runner configs (the judge guards by substring), at least one where the stack has
        // one; never a manifest, so a task that adds a dependency, a script, a fixture or a target stays possible
        let words = s.config!.gate!.split(separator: " ").map(String.init)
        let manifests = ["package.json", "pyproject.toml", "Package.swift", "setup.cfg", "conftest.py"]
        #expect(!words.contains { manifests.contains($0) }, "\(stack): \(s.config!.gate!)")
        if stack == "swift" { #expect(s.config!.gate! == "bash scripts/gate.sh") }
        else {
            #expect(s.config!.gate!.hasPrefix("bash scripts/gate.sh # "), "\(stack): \(s.config!.gate!)")
            let after = words.drop { $0 != "#" }.dropFirst()
            #expect(!after.isEmpty && after.allSatisfy(FactoryDoctor.isRunnerConfig), "\(stack): \(s.config!.gate!)")
        }
        let j = FactoryDoctor.judge(s)
        #expect(j.score == 3 && j.evidence.contains("gate cita scripts/gate.sh, versionado: lido do commit base"), "\(stack): \(j.evidence)")
        let gate = try #require(s.scripts["scripts/gate.sh"])
        // F5a (N4): the model's runner is called directly; were it `npm test`, the judge would drop to 2
        #expect(!FactoryDoctor.viaPackageScript(FactoryDoctor.testRunnerSource(s.config!.gate!, s.scripts) ?? ""), "\(stack)")
        var viaNpm = s; viaNpm.scripts["scripts/gate.sh"] = "set -e\nnpm test\n"
        viaNpm.paths.removeAll { $0 == "package.json" }   // a gate that cites package.json guards the test script too (N4)
        #expect(FactoryDoctor.judge(viaNpm).score == 2, "\(stack)")
        let governs: [String: [String]] = ["swift": ["Package.swift"],
                                           "node": ["package.json", "jest.config.*", "vitest.config.*", "vite.config.*", "vitest.workspace.*"],
                                           "python": ["conftest.py", "pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"]]
        let header = gate.split(separator: "\n").prefix { $0.hasPrefix("#") }.joined(separator: "\n")
        for f in governs[stack]! { #expect(header.contains(f), "\(stack)/scripts/gate.sh: o comentário do topo não cita \(f)") }
        // the runner is called directly: no code line goes through `npm test` (comments may name it)
        let code = { (t: String) in t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n") }
        #expect(!code(gate).contains("npm test") && !code(s.scripts["scripts/check-feature.sh"] ?? "").contains("npm test"), "\(stack): runner pelo npm test")
        // F5b (N5): node's runner is fixed by the init, never picked by grep in package.json at run time nor downloaded
        if stack == "node" {
            for p in ["scripts/gate.sh", "scripts/check-feature.sh"] {
                let c = code(s.scripts[p] ?? "")
                #expect(!c.contains("grep -q") && c.contains("npx --no-install vitest run") && !c.contains("npx jest"), "\(p): \(c)")
            }
        }
        // F5b (N6): the python CI installs the dev extra, falling back to the plain package, and pytest by name
        if stack == "python" {
            let ci = try text(modelos.appendingPathComponent("python/ci.yml"))
            #expect(ci.contains(#"pip install -e ".[dev]" 2>/dev/null || python3 -m pip install -e ."#) && ci.contains("pip install pytest"))
        }
    }

    /// F3/F5b: the rule of scripts/gate.sh, run: a config that forces success fails the gate (also in a folder whose name has a
    /// space and glob characters), a clean one runs the runner.
    @Test(arguments: [
        ("node", ["package.json": #"{"devDependencies": {"vitest": "1"}}"#, "a b [c]*?/vite.config.ts": "export default { test: { passWithNoTests: true } }\n"],
         ["package.json": #"{"devDependencies": {"vitest": "1"}}"#, "a b [c]*?/vite.config.ts": "export default {}\n"], "stub npx --no-install vitest run"),
        ("node", ["package.json": #"{"jest": {"passWithNoTests": true}}"#], ["package.json": #"{"jest": {"passWithNoTests": false}}"#], "stub npx --no-install vitest run"),
        ("node", ["package.json": #"{"jest": {"testFailureExitCode": 0}}"#], ["package.json": "{}", "jest.config.js": "// passWithNoTests: true is never set here\n"], "stub npx"),
        ("python", ["a b [c]*?/conftest.py": "def pytest_sessionfinish(session):\n    session.exitstatus = 0\n"],
         ["a b [c]*?/conftest.py": "import pytest\n# never set exitstatus = 0\n", "pyproject.toml": "[tool.pytest.ini_options]\n"], "stub python3 -P -m pytest -q"),
        ("python", ["conftest.py": "def pytest_sessionfinish(session):\n    session.exitstatus\t= pytest.ExitCode.OK\n"], ["conftest.py": "\n"], "stub python3"),
        ("python", ["pytest.ini": "[pytest]\naddopts = --co\n"], ["pytest.ini": "[pytest]\naddopts = --cov=src\n"], "stub python3"),
        ("python", ["tox.ini": "[pytest]\naddopts = --collect-only\n"], ["tox.ini": "[tox]\n"], "stub python3"),
        ("python", ["conftest.py": "import os\nos._exit(0)\n"], ["setup.cfg": "[metadata]\n"], "stub python3"),
        // F6b (n1, m5): only an assignment forces success; a comparison or another exit code does not
        ("node", ["jest.config.js": "module.exports = { testFailureExitCode: 0 }\n"],
         ["package.json": #"{"jest": {"testFailureExitCode": 1}}"#], "stub npx"),
        ("python", ["conftest.py": "def pytest_sessionfinish(session):\n    session.exitstatus = False\n"],
         ["conftest.py": "def pytest_sessionfinish(session):\n    if session.exitstatus == pytest.ExitCode.OK:\n        pass\n"], "stub python3"),
        ("python", ["conftest.py": "session.exitstatus = (0)\n"], ["conftest.py": "x = (0)\n"], "stub python3"),
        // F6b (n1): `//` is no comment in a .py, `#` is no comment in a .js
        ("python", ["conftest.py": "// session.exitstatus = 0\n"], ["conftest.py": "# session.exitstatus = 0\n"], "stub python3"),
        ("node", ["jest.config.js": "# passWithNoTests: true\n"], ["jest.config.js": "// passWithNoTests: true\n"], "stub npx"),
        // F7b (nit): what follows a `#` out of quotes is a comment; a `#` inside quotes is not
        ("python", ["pyproject.toml": "[tool.pytest.ini_options]\naddopts = \"-q # --co\"\n"],
         ["pytest.ini": "[pytest]\naddopts = \"-q\"  # do not add --co\n", "setup.cfg": "[tool:pytest]\naddopts = '-q' # --collect-only\n"], "stub python3"),
        ("python", ["conftest.py": "x = '#'; session.exitstatus = 0\n"], ["conftest.py": "x = 1  # session.exitstatus = 0\n"], "stub python3"),
    ])
    func gateRefusesAForcedSuccessConfig(_ stack: String, _ forced: [String: String], _ clean: [String: String], _ ran: String) throws {
        let bad = try runGate(stack, forced)
        #expect(bad.status != 0, "\(stack): \(bad.out)")
        #expect(bad.out.contains("a config do runner força sucesso"), "\(stack): \(bad.out)")
        #expect(!bad.out.contains("stub "), "\(stack): o runner rodou com a config forçada")
        let good = try runGate(stack, clean)
        #expect(good.status == 0 && good.out.contains(ran) && !good.out.contains("força sucesso"), "\(stack): \(good.out)")
    }

    /// F5b (N1): a symlinked config fails the gate (its target is out of the judge's sight); a pytest.py or pytest/ at the root
    /// (which would stand in for pytest) fails the python gate; the swift gate only runs swift test.
    @Test func gateRefusesLinksAndAShadowPytest() throws {
        for (stack, name) in [("node", "jest.config.js"), ("python", "pytest.ini")] {
            let r = try runGate(stack, ["cfg/real": "x\n"], links: [name: "cfg/real"])
            #expect(r.status != 0 && r.out.contains("link simbólico em arquivo de config do runner: \(name)") && !r.out.contains("stub "), "\(stack): \(r.out)")
            // F7b (m-E): a linked folder fails only when its target leaves the repository; inside it, git lists the target's files
            let dir = try runGate(stack, [:], links: ["tests2": "/usr"])
            #expect(dir.status != 0 && dir.out.contains("link simbólico para pasta fora do repositório: tests2") && !dir.out.contains("stub "), "\(stack): \(dir.out)")
            let inside = try runGate(stack, [".agents/skills/x.md": "x\n", ".claude/settings.json": "{}\n"], links: [".claude/skills": "../.agents/skills"])
            #expect(inside.status == 0 && inside.out.contains("stub ") && !inside.out.contains("gate:"), "\(stack): \(inside.out)")
            // F6b (M1): only what git sees counts: an ignored venv (its links, its site-packages conftest.py) and a versioned
            // link that is no runner config (CLAUDE.md -> AGENTS.md) leave the gate green
            let ok = try runGate(stack, [".gitignore": "venv/\n", "AGENTS.md": "x\n", "venv/bin/real": "x\n",
                                         "venv/lib/site-packages/conftest.py": "session.exitstatus = 0\n",
                                         "venv/lib/site-packages/jest.config.js": "module.exports = { passWithNoTests: true }\n"],
                                 links: ["CLAUDE.md": "AGENTS.md", "venv/bin/python": "real"])
            #expect(ok.status == 0 && ok.out.contains("stub ") && !ok.out.contains("gate:"), "\(stack): \(ok.out)")
        }
        // a folder named like grep's "path:line:#" prefix cannot pass a forced line off as a comment
        for (stack, rel, body) in [("python", "a:1:#x/conftest.py", "session.exitstatus = 0\n"),
                                   ("node", "a:1:#x/jest.config.js", "module.exports = { passWithNoTests: true }\n")] {
            let r = try runGate(stack, [rel: body])
            #expect(r.status != 0 && r.out.contains("força sucesso") && !r.out.contains("stub "), "\(stack): \(r.out)")
        }
        for files in [["pytest.py": "import sys; sys.exit(0)\n"], ["pytest/__main__.py": "\n"]] {
            let r = try runGate("python", files)
            #expect(r.status != 0 && r.out.contains("troca o pytest") && !r.out.contains("stub "), "\(files): \(r.out)")
        }
        // F7b (M-A): Python below 3.11 has no -P, so gate and check run isolated `python3 -I -m pytest`
        for script in ["gate.sh", "check-feature.sh"] {
            let old = try runGate("python", [:], stubs: ["python3": "#!/bin/bash\n[ \"$1 $2\" = \"-I -c\" ] && exit 1\necho \"stub python3 $*\"\n"],
                                  script: script, args: script == "gate.sh" ? [] : ["tests"])
            #expect(old.status == 0 && old.out.contains("stub python3 -I -m pytest -q") && !old.out.contains("-P"), "\(script): \(old.out)")
        }
        let new = try runGate("python", [:])
        #expect(new.status == 0 && new.out.contains("stub python3 -P -m pytest -q"), "\(new.out)")
        let sw = try runGate("swift", ["Package.swift": "// passWithNoTests\n"])
        #expect(sw.status == 0 && sw.out.contains("stub swift test"), "\(sw.out)")
        #expect(!(try text(modelos.appendingPathComponent("swift/scripts/gate.sh"))).contains("grep"))
    }

    /// F7b (M-A): a pluggy.py or _pytest/ at the root that exits 0 never stands in for pytest, in the gate and in the check, with
    /// each Python found (below 3.11 runs -I, from 3.11 -P). pytest is faked in a venv outside the project (no download): its
    /// __main__ imports pluggy and _pytest and fails, as a failing test would. Without the flags the shadow wins (exit 0).
    @Test func rootModulesCannotStandInForPytest() throws {
        let pys = ["/usr/bin/python3", "/opt/homebrew/bin/python3.10", "/opt/homebrew/bin/python3.12", "/usr/bin/python3.10", "/usr/bin/python3.12"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard !pys.isEmpty else { return }
        for py in pys {
            let v = try tempDir(); defer { try? FileManager.default.removeItem(at: v) }
            let mk = Process(), out = Pipe()
            mk.executableURL = URL(fileURLWithPath: "/bin/bash")
            mk.arguments = ["-c", "\"$0\" -m venv --without-pip \"$1\" && \"$1/bin/python\" -I -c 'import sysconfig; print(sysconfig.get_paths()[\"purelib\"])'", py, v.appendingPathComponent("venv").path]
            mk.standardOutput = out
            try mk.run()
            let site = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            mk.waitUntilExit()
            try #require(mk.terminationStatus == 0 && site.hasPrefix("/"), "\(py): venv")
            let s = URL(fileURLWithPath: site)
            try put(s, "pytest/__init__.py", "")
            try put(s, "pytest/__main__.py", "import pluggy, _pytest\nraise SystemExit(1)\n")
            try put(s, "pluggy.py", "")
            try put(s, "_pytest/__init__.py", "")
            let vpy = v.appendingPathComponent("venv/bin/python").path
            let real = "#!/bin/bash\nexec \"\(vpy)\" \"$@\"\n"
            let bare = "#!/bin/bash\na=(); for x in \"$@\"; do [ \"$x\" = -I ] || [ \"$x\" = -P ] || a+=(\"$x\"); done\nexec \"\(vpy)\" \"${a[@]}\"\n"
            for shadow in ["pluggy.py", "_pytest/__init__.py"] {
                let files = [shadow: "import os\nos._exit(0)\n", "tests/test_x.py": "def test_x():\n    assert False\n"]
                for script in ["gate.sh", "check-feature.sh"] {
                    let args = script == "gate.sh" ? [] : ["tests"]
                    let r = try runGate("python", files, stubs: ["python3": real], script: script, args: args)
                    #expect(r.status != 0, "\(py) \(script) \(shadow): \(r.out)")
                }
                let control = try runGate("python", files, stubs: ["python3": bare])
                #expect(control.status == 0, "\(py) \(shadow): sem -I/-P a sombra deveria ganhar: \(control.out)")
            }
        }
    }

    /// F7b: the gates fail closed (no git, outside a repository, a git error) and see ignored runner configs, pruning venvs,
    /// node_modules/, .tox/ and site-packages/; the forced() block is one text in every model, so a rule changes once.
    @Test func gateFailsClosedAndSeesIgnoredConfigs() throws {
        for stack in ["node", "python"] {
            let noGit = try runGate(stack, [:], noGit: true)
            #expect(noGit.status != 0 && noGit.out.contains("git não encontrado") && !noGit.out.contains("stub "), "\(stack): \(noGit.out)")
            let outside = try runGate(stack, [:], prep: "true")
            #expect(outside.status != 0 && outside.out.contains("fora de um repositório git") && !outside.out.contains("stub "), "\(stack): \(outside.out)")
            let broken = try runGate(stack, ["a.txt": "x\n"], prep: "git init -q && git add -A && printf junk > .git/index")
            #expect(broken.status != 0 && broken.out.contains("git ls-files falhou") && !broken.out.contains("stub "), "\(stack): \(broken.out)")
            // pruned: a venv (pyvenv.cfg), node_modules/, .tox/, site-packages/
            let pruned = try runGate(stack, [".gitignore": "env1/\nnode_modules/\n.tox/\nlib/\n", "env1/pyvenv.cfg": "home = /usr\n",
                                             "env1/x/conftest.py": "session.exitstatus = 0\n", "env1/x/jest.config.js": "module.exports = { passWithNoTests: true }\n",
                                             "node_modules/x/jest.config.js": "module.exports = { passWithNoTests: true }\n",
                                             ".tox/py/conftest.py": "session.exitstatus = 0\n", "lib/site-packages/conftest.py": "session.exitstatus = 0\n"])
            #expect(pruned.status == 0 && pruned.out.contains("stub ") && !pruned.out.contains("gate:"), "\(stack): \(pruned.out)")
        }
        // m-B: an ignored config is seen (.git/info/exclude or .gitignore), links among them too
        let excluded = try runGate("python", ["tests/conftest.py": "def pytest_sessionfinish(session):\n    session.exitstatus = 0\n"],
                                   prep: "git init -q && printf 'tests/conftest.py\\n' >> .git/info/exclude && git add -A")
        #expect(excluded.status != 0 && excluded.out.contains("tests/conftest.py:2") && !excluded.out.contains("stub "), "\(excluded.out)")
        let lib = try runGate("python", [".gitignore": "lib/\n", "lib/conftest.py": "session.exitstatus = 0\n"])
        #expect(lib.status != 0 && lib.out.contains("lib/conftest.py:1"), "\(lib.out)")
        let vitest = try runGate("node", [".gitignore": "vitest.config.ts\n", "vitest.config.ts": "export default { test: { passWithNoTests: true } }\n"])
        #expect(vitest.status != 0 && vitest.out.contains("vitest.config.ts:1"), "\(vitest.out)")
        let link = try runGate("node", [".gitignore": "jest.config.js\n", "cfg/real": "x\n"], links: ["jest.config.js": "cfg/real"])
        #expect(link.status != 0 && link.out.contains("link simbólico em arquivo de config do runner: jest.config.js"), "\(link.out)")

        // one forced() block for every model, and one interpreter choice for the python gate and check
        func block(_ s: String) -> String? {
            guard let a = s.range(of: "# forced <ERE"), let b = s.range(of: "\n}\n", range: a.upperBound..<s.endIndex) else { return nil }
            return String(s[a.lowerBound..<b.upperBound])
        }
        let node = block(try text(modelos.appendingPathComponent("node/scripts/gate.sh")))
        let py = block(try text(modelos.appendingPathComponent("python/scripts/gate.sh")))
        #expect(node != nil && node == py, "o bloco forced() de node e python divergiu")
        for p in ["python/scripts/gate.sh", "python/scripts/check-feature.sh"] {
            let t = try text(modelos.appendingPathComponent(p))
            #expect(t.contains("if python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then exec python3 -P -m pytest -q")
                    && t.contains("exec python3 -I -m pytest -q") && !t.contains("exec python3 -m pytest"), "\(p)")
        }
    }
}
