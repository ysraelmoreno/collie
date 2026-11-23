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
/// swapped for a stub that prints its arguments and exits 0. Returns the exit code and stdout + stderr.
private func runGate(_ stack: String, _ files: [String: String]) throws -> (status: Int32, out: String) {
    let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
    try put(d, "scripts/gate.sh", try text(modelos.appendingPathComponent("\(stack)/scripts/gate.sh")))
    for (rel, body) in files { try put(d, rel, body) }
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
    return FactoryDoctor.Snapshot(config: config, scripts: scripts, paths: (Array(scripts.keys) + personas).sorted(),
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
        // F3: the gate cites a versioned script (scripts/gate.sh), so the judge guards it: 3, not the 2 of a bare gate
        #expect(s.config!.gate == "bash scripts/gate.sh")
        let j = FactoryDoctor.judge(s)
        #expect(j.score == 3 && j.evidence.contains("gate cita scripts/gate.sh, versionado: lido do commit base"), "\(stack): \(j.evidence)")
        let gate = try #require(s.scripts["scripts/gate.sh"])
        let governs: [String: [String]] = ["swift": ["Package.swift"],
                                           "node": ["package.json", "jest.config.*", "vitest.config.*", "vite.config.*", "vitest.workspace.*"],
                                           "python": ["conftest.py", "pyproject.toml"]]
        let header = gate.split(separator: "\n").prefix { $0.hasPrefix("#") }.joined(separator: "\n")
        for f in governs[stack]! { #expect(header.contains(f), "\(stack)/scripts/gate.sh: o comentário do topo não cita \(f)") }
        #expect(!gate.contains("npm test") && !(s.scripts["scripts/check-feature.sh"] ?? "").contains("npm test"), "\(stack): runner pelo npm test")
    }

    /// F3: the rule of scripts/gate.sh, run: a config that forces success fails the gate (also in a folder whose name has a
    /// space and glob characters), a clean one runs the runner.
    @Test(arguments: [
        ("swift", ["Package.swift": "// passWithNoTests\n"], ["Package.swift": "// swift-tools-version:5.9\n"], "stub swift test"),
        ("node", ["package.json": #"{"devDependencies": {"vitest": "1"}}"#, "a b [c]*?/vite.config.ts": "export default { test: { passWithNoTests: true } }\n"],
         ["package.json": #"{"devDependencies": {"vitest": "1"}}"#, "a b [c]*?/vite.config.ts": "export default {}\n"], "stub npx vitest run"),
        ("node", ["package.json": #"{"jest": {"passWithNoTests": true}}"#], ["package.json": #"{"devDependencies": {"jest": "29"}}"#], "stub npx jest"),
        ("python", ["a b [c]*?/conftest.py": "def pytest_sessionfinish(session):\n    session.exitstatus = 0\n"],
         ["a b [c]*?/conftest.py": "import pytest\n", "pyproject.toml": "[tool.pytest.ini_options]\n"], "stub python3 -m pytest -q"),
    ])
    func gateRefusesAForcedSuccessConfig(_ stack: String, _ forced: [String: String], _ clean: [String: String], _ ran: String) throws {
        let bad = try runGate(stack, forced)
        #expect(bad.status != 0, "\(stack): \(bad.out)")
        #expect(bad.out.contains("a config do runner força sucesso"), "\(stack): \(bad.out)")
        #expect(!bad.out.contains("stub "), "\(stack): o runner rodou com a config forçada")
        let good = try runGate(stack, clean)
        #expect(good.status == 0 && good.out.contains(ran) && !good.out.contains("força sucesso"), "\(stack): \(good.out)")
    }
}
