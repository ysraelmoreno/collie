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

/// Runs `bash scripts/gate.sh` of the model `stack` in a project made of `files`, with the runners (`swift`, `npx`, `python3`)
/// swapped for a stub that prints its arguments and exits 0; `links` are symlinks (path: target). Returns the exit code and stdout + stderr.
private func runGate(_ stack: String, _ files: [String: String], links: [String: String] = [:]) throws -> (status: Int32, out: String) {
    let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
    try put(d, "scripts/gate.sh", try text(modelos.appendingPathComponent("\(stack)/scripts/gate.sh")))
    for (rel, body) in files { try put(d, rel, body) }
    for (rel, target) in links { try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent(rel).path, withDestinationPath: target) }
    for runner in ["swift", "npx", "python3"] {
        try put(d, "stub/\(runner)", "#!/bin/bash\necho \"stub \(runner) $*\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.appendingPathComponent("stub/\(runner)").path)
    }
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["scripts/gate.sh"]
    p.currentDirectoryURL = d
    p.environment = ["PATH": d.appendingPathComponent("stub").path + ":/usr/bin:/bin"]
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
        // F5b (N1): its text also cites the configs that govern the runner (the judge guards by substring), at least the main one
        let main = ["swift": "Package.swift", "node": "package.json", "python": "pyproject.toml"][stack]!
        #expect(s.config!.gate!.hasPrefix("bash scripts/gate.sh # ") && s.config!.gate!.split(separator: " ").contains { $0 == main }, "\(stack): \(s.config!.gate!)")
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
            #expect(r.status != 0 && r.out.contains("link simbólico") && !r.out.contains("stub "), "\(stack): \(r.out)")
            // a linked folder (its config sits in an ignored, pruned folder) fails as well
            let dir = try runGate(stack, ["node_modules/x/\(name)": "x\n"], links: ["tests2": "node_modules/x"])
            #expect(dir.status != 0 && dir.out.contains("tests2: link simbólico") && !dir.out.contains("stub "), "\(stack): \(dir.out)")
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
        let sw = try runGate("swift", ["Package.swift": "// passWithNoTests\n"])
        #expect(sw.status == 0 && sw.out.contains("stub swift test"), "\(sw.out)")
        #expect(!(try text(modelos.appendingPathComponent("swift/scripts/gate.sh"))).contains("grep"))
    }
}
