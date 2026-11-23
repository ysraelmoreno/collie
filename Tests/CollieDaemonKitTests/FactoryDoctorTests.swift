import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private typealias D = FactoryDoctor

private func cfg(_ json: String) throws -> ProjectWorkConfig {
    switch ProjectWorkConfig.parse(Data(json.utf8)) {
    case .success(let ok): return ok.config
    case .failure(let e): Issue.record("\(e.message)"); throw e
    }
}
private func layer(_ r: D.Report, _ l: D.Layer) -> D.LayerScore { r.layers.first { $0.layer == l }! }

/// A project folder (with `.git`, so it is its own root) the test removes at the end.
private func project(_ body: (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory))
        .appendingPathComponent("fdoc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
private func put(_ dir: URL, _ rel: String, _ body: String) throws {
    let u = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: u)
}
/// A shell terminal in `cwd`; each call is one `factory.doctor` from it.
private func doctor(_ d: Daemon, _ p: Paths, cwd: URL) async throws -> ([String: JSONValue]) async throws -> Response {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                      args: ["name": .string("T"), "preset": .string("shell"), "cwd": .string(cwd.path)]))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    let token = try await tokenOf(d, id)
    return { args in try await send(p, Request(id: "c", terminalId: id, token: token, command: "factory.doctor", args: args)) }
}

@Suite struct FactoryDoctorTests {
    // MARK: the score

    @Test func emptyProject() {
        let r = D.score(D.Snapshot())
        #expect(r.layers.map(\.layer) == D.Layer.allCases)   // the pyramid's order
        #expect(r.layers.map(\.score) == [0, 1, 0, 0, 1, 1])
        #expect(layer(r, .verification).evidence.first?.contains("sem verificação em runtime ainda") == true)
        #expect(r.layers.allSatisfy { !$0.nextAction.isEmpty })
        #expect(!r.passes(min: 1) && r.passes(min: 0))
    }

    @Test func buildOnlyGateIsWeak() throws {   // design's acceptance criterion 3
        for gate in ["swift build", "tsc --noEmit", "cargo check", "npm run build", "make"] {
            let s = layer(D.score(D.Snapshot(config: try cfg(#"{"gate": "\#(gate)"}"#))), .static)
            #expect(s.score == 1 && s.rating == .fraco, "\(gate)")
            #expect(s.evidence.contains { $0.contains("só compila") }, "\(gate)")
            #expect(s.evidence.first == "collie-work.json: gate = \"\(gate)\"")
        }
        // a script the gate cites that only builds is weak too
        let viaScript = D.Snapshot(config: try cfg(#"{"gate": "scripts/ci.sh"}"#), scripts: ["scripts/ci.sh": "#!/bin/sh\nswift build\n"])
        #expect(layer(D.score(viaScript), .static).score == 1)
    }

    @Test func testsRatchetAndSameCIRaise() throws {
        let c = try cfg(#"{"gate": "swift test", "factory": {"version": 1, "static": {"ratchets": [{"name": "lint", "measure": "scripts/lint-count.sh"}]}}}"#)
        let s = D.Snapshot(config: c, ci: [".github/workflows/ci.yml": "jobs:\n  t:\n    steps:\n      - run: swift test\n"])
        let st = layer(D.score(s), .static)
        #expect(st.score == 3 && st.rating == .forte)
        #expect(st.evidence.contains("+ catracas: lint"))
        #expect(st.evidence.contains("+ o CI roda o mesmo gate: .github/workflows/ci.yml: - run: swift test"))
        // only tests: OK, not FORTE
        #expect(layer(D.score(D.Snapshot(config: try cfg(#"{"gate": "swift test"}"#))), .static).score == 2)
        // the tests run inside a script the gate cites: the evidence names the script's line
        let deep = D.Snapshot(config: try cfg(#"{"gate": "./scripts/ci.sh"}"#), scripts: ["scripts/ci.sh": "set -e\nnpx jest --ci\n"])
        #expect(layer(D.score(deep), .static).evidence.contains("o gate roda testes: scripts/ci.sh: npx jest --ci"))
    }

    @Test func scriptOutsideTheRepoOrIgnoredWarns() throws {
        let out = layer(D.score(D.Snapshot(config: try cfg(#"{"gate": "/Users/x/check.sh && swift test"}"#))), .judge)
        #expect(out.score == 1 && out.evidence.contains("aviso: gate cita script fora do repositório: /Users/x/check.sh"))
        #expect(layer(D.score(D.Snapshot(config: try cfg(#"{"precheck": "../other/pre.sh"}"#))), .judge).score == 1)
        let ign = D.Snapshot(config: try cfg(#"{"gate": "scripts/local/gate.sh"}"#), gitignore: "# local\nscripts/local/\n")
        #expect(layer(D.score(ign), .judge).evidence.contains("aviso: gate cita script ignorado pelo git (.gitignore): scripts/local/gate.sh"))
        let grepOnly = D.Snapshot(config: try cfg(#"{"gate": "swift test"}"#),
                                  scripts: ["scripts/check-u9.sh": "#!/bin/sh\nset -e\ntest -f Sources/X.swift\ngrep -q foo Sources/X.swift\n"])
        let j = layer(D.score(grepOnly), .judge)
        #expect(j.score == 1 && j.evidence.contains { $0.contains("scripts/check-u9.sh só faz grep/test -f") })
        let good = D.Snapshot(config: try cfg(#"{"gate": "scripts/ci.sh"}"#), scripts: ["scripts/ci.sh": "swift test\n"])
        let g = layer(D.score(good), .judge)
        #expect(g.score == 3 && g.evidence == ["gate cita scripts/ci.sh, versionado: lido do commit base"])
    }

    @Test func smallRules() {
        #expect(D.runsTests("swift test --filter X") && D.runsTests("npm test") && D.runsTests("go test ./...") && D.runsTests("cd a && pytest -q"))
        #expect(D.runsTests("xcodebuild test -scheme A") && D.runsTests("./node_modules/.bin/vitest run"))
        #expect(!D.runsTests("test -f x && swift build") && !D.runsTests("make") && !D.runsTests("cargo check"))
        #expect(D.citedPaths("./scripts/a.sh x && bash tools/b.py --flag=c/d && echo hi") == ["scripts/a.sh", "tools/b.py"])
        #expect(D.outsideRepo("/a") && D.outsideRepo("~/a") && D.outsideRepo("a/../../b") && !D.outsideRepo("scripts/a.sh"))
        #expect(D.ignored("build/x.sh", "build") && D.ignored("a/tmp.sh", "*.sh") && D.ignored("local/x", "/local/"))
        #expect(!D.ignored("src/local/x", "/local/") && !D.ignored("scripts/a.sh", "# scripts\n!scripts/a.sh"))
        #expect(D.onlyLooksForFiles("test -f a && grep -q b a\n[ -f c ]") && !D.onlyLooksForFiles("grep x a && swift test") && !D.onlyLooksForFiles(""))
        #expect(D.personaFile("pm", ["docs/fabrica/personas/pm.md"]) == "docs/fabrica/personas/pm.md")
        #expect(D.personaFile("pm", ["review/personas/pm.md"]) == "review/personas/pm.md" && D.personaFile("pm", ["pm.md"]) == nil)
        #expect([0, 1, 2, 3].map(D.rating) == [.fraco, .fraco, .ok, .forte])
    }

    @Test func verificationReviewProseGuardrails() throws {
        let full = try cfg("""
        {"areas": {"web-ui": "npm test", "core": "swift test"},
         "factory": {"version": 1,
           "verification": {"scenarios": [{"area": "core", "command": "scripts/run-core.sh"}]},
           "review": {"personas": ["pm", "sec"], "callOwner": true},
           "prose": {"traps": ["2e221b6c", "62f553cc"]},
           "guardrails": {"budgetSeconds": 3600, "maxTries": 3, "destructive": ["rm -rf"]}}}
        """)
        let r = D.score(D.Snapshot(config: full, paths: ["docs/fabrica/personas/pm.md", "docs/fabrica/personas/sec.md"]))
        let v = layer(r, .verification)
        #expect(v.score == 2 && v.evidence.contains("aviso: área de UI 'web-ui' sem cenário"))
        #expect(layer(r, .review).score == 3)
        let p = layer(r, .prose)
        #expect(p.score == 2 && p.evidence.contains { $0.contains("nota máxima 2") })   // never 3 offline
        #expect(layer(r, .guardrails).score == 3)
        // personas without their files: 2 (callOwner still counts); no file and no callOwner: 1
        let noFiles = D.score(D.Snapshot(config: full)); #expect(layer(noFiles, .review).score == 2)
        let bare = try cfg(#"{"factory": {"version": 1, "review": {"personas": ["pm"]}, "guardrails": {"maxTries": 2}}}"#)
        #expect(layer(D.score(D.Snapshot(config: bare)), .review).score == 1)
        #expect(layer(D.score(D.Snapshot(config: bare)), .guardrails).score == 2)
    }

    @Test func escapedBaitLowersItsLayer() throws {
        let c = try cfg(#"{"gate": "swift test"}"#)
        let clean = D.score(D.Snapshot(config: c, baits: D.BaitResults()))
        let hit = D.score(D.Snapshot(config: c, baits: D.BaitResults(escapedBaits: ["static": 2, "judge": 0])))
        #expect(layer(clean, .static).score == 2 && layer(hit, .static).score == 1 && layer(hit, .static).rating == .fraco)
        #expect(layer(hit, .static).evidence.last == "2 isca(s) passaram por esta camada")
        #expect(layer(hit, .judge) == layer(clean, .judge))
        // never below 0
        #expect(layer(D.score(D.Snapshot(baits: D.BaitResults(escapedBaits: ["review": 1]))), .review).score == 0)
    }

    @Test func deterministicAndJSONRoundTrips() throws {
        let s = D.Snapshot(config: try cfg(#"{"gate": "scripts/ci.sh", "areas": {"b": "x", "a": "y"}}"#),
                           scripts: ["scripts/ci.sh": "swift test\n", "scripts/check-1.sh": "grep a b\n", "scripts/check-0.sh": "test -f x\n"],
                           ci: ["Makefile": "ci:\n\tscripts/ci.sh\n", ".github/workflows/a.yml": "run: scripts/ci.sh\n"])
        let a = D.score(s), b = D.score(s)
        #expect(a == b && D.text(a, min: 1) == D.text(b, min: 1))
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys   // the CLI prints sorted keys too
        #expect(try enc.encode(a) == enc.encode(b))
        #expect(try JSONDecoder().decode(D.Report.self, from: JSONEncoder().encode(a)) == a)
        #expect(layer(a, .static).evidence.contains("+ áreas: a, b"))
        #expect(layer(a, .static).evidence.contains("+ o CI roda o mesmo gate: .github/workflows/a.yml: run: scripts/ci.sh"))   // sorted: .github first
    }

    // MARK: the command

    @Test func commandIsRegistered() throws {
        let spec = try #require(Commands.spec("factory.doctor"))
        #expect(!spec.exposedToMCP && !spec.shepherdOnly && spec.params.map(\.name) == ["min", "terminal"])
        let r = try ArgvParser.parse(["factory", "doctor", "--min", "2"])
        #expect(r.command == "factory.doctor" && r.args["min"] != nil)
    }

    @Test func doctorReadsAndNeverRuns() async throws {
        try await project { dir in
            let marker = dir.appendingPathComponent("ran-\(UUID().uuidString.prefix(6))").path
            try put(dir, "collie-work.json", #"{"gate": "touch \#(marker) && scripts/ci.sh", "precheck": "swift build --build-tests"}"#)
            try put(dir, "scripts/ci.sh", "touch \(marker)-ci\nswift test\n")
            try put(dir, ".github/workflows/ci.yml", "      - run: touch \(marker) && scripts/ci.sh\n")
            try await withDaemon { d, p in
                let call = try await doctor(d, p, cwd: dir)
                let r = try await call([:])
                #expect(r.ok, "\(r)")
                guard case .object(let o)? = r.result, case .string(let out)? = o["output"], let rep = o["report"] else { Issue.record("\(r)"); return }
                #expect(o["passed"] == .bool(false) && o["min"] == .number(1))   // verification and review are 0
                #expect(out.contains("static") && out.contains("FORTE") && out.contains("Só leitura"))
                #expect(out.contains("abaixo de 1: verification, review"))
                // --json: the report decodes back
                let report = try JSONDecoder().decode(D.Report.self, from: JSONEncoder().encode(rep))
                #expect(layer(report, .static).score == 3 && layer(report, .static).evidence.contains("o gate roda testes: scripts/ci.sh: swift test"))
                let zero = try await call(["min": .number(0)])
                guard case .object(let z)? = zero.result else { Issue.record("\(zero)"); return }
                #expect(z["passed"] == .bool(true))
                #expect(try await call(["min": .number(4)]).error?.code == .invalidArgs)
                for suffix in ["", "-ci"] { #expect(!FileManager.default.fileExists(atPath: marker + suffix), "ran \(suffix)") }
            }
        }
    }

    @Test func readerRefusesSymlinkAndLargeFile() async throws {
        try await project { dir in
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("fdoc-out-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try put(outside, "c.json", #"{"gate":"swift test"}"#)
            try put(outside, "s.sh", "swift test\n")
            let file = dir.appendingPathComponent("collie-work.json")
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("c.json"))
            try await withDaemon { d, p in
                let call = try await doctor(d, p, cwd: dir)
                let r = try await call([:])
                #expect(!r.ok && r.error?.message.contains("link simbólico") == true, "\(r)")
                try FileManager.default.removeItem(at: file)
                try put(dir, "collie-work.json", "{\"gate\": \"" + String(repeating: "a", count: 17 * 1024) + "\"}")
                let big = try await call([:])
                #expect(!big.ok && big.error?.message.contains("16 KB") == true, "\(big)")
            }
            // scripts: a link (file or folder on the way) is never read; a big one is cut at 64 KB
            try put(dir, "collie-work.json", #"{"gate": "scripts/a.sh && linked/s.sh && scripts/big.sh"}"#)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/a.sh"), withDestinationURL: outside.appendingPathComponent("s.sh"))
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: outside)
            try put(dir, "scripts/big.sh", String(repeating: "x", count: 70 * 1024))
            guard case .success(let s) = FactoryDoctorReader.snapshot(root: dir) else { Issue.record("snapshot"); return }
            #expect(s.scripts["scripts/a.sh"] == nil && s.scripts["linked/s.sh"] == nil)
            #expect(s.scripts["scripts/big.sh"]?.utf8.count == FactoryDoctorReader.maxScriptBytes)
            #expect(s.paths.contains("linked") && !s.paths.contains("linked/s.sh") && !s.paths.contains(".git"))
        }
    }
}
