import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// U4: the bait catalog, its patches, the results file and `collie factory bait list|report`.
private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func catalog(_ json: String) -> Result<FactoryBait.Catalog, FactoryBait.BaitError> { FactoryBait.parseCatalog(Data(json.utf8)) }
private func results(_ json: String) -> Result<BaitResults, FactoryBait.BaitError> { BaitResults.parse(Data(json.utf8)) }
private func failure<T>(_ r: Result<T, FactoryBait.BaitError>) -> FactoryBait.BaitError? { if case .failure(let e) = r { return e }; return nil }

private func dir(_ tag: String) throws -> URL {
    let d = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("\(tag)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func put(_ dir: URL, _ rel: String, _ body: String) throws {
    let u = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: u)
}
@discardableResult private func git(_ args: [String], in d: URL) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.email=isca@example.invalid", "-c", "user.name=isca", "-c", "commit.gpgsign=false"] + args
    p.currentDirectoryURL = d
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}

private let sample = BaitResults(runs: [
    .init(bait: "logica", date: "2026-11-23", caught: true, layer: .review, persona: "correcao", costSeconds: 420),
    .init(bait: "corrida", date: "2026-11-23", caught: false, layer: .review, costSeconds: 300),
    .init(bait: "segredo-no-diff", date: "2026-11-24", caught: true, layer: .review, persona: "seguranca", costSeconds: 200),
    .init(bait: "spec-editado", date: "2026-11-24", caught: false, layer: .judge, costSeconds: 100),
])

/// A profile whose review layer scores above 0, so an escape there shows.
private func cfgReview() throws -> ProjectWorkConfig {
    let j = #"{"gate": "swift test", "factory": {"version": 1, "review": {"personas": ["correcao"], "callOwner": true}}}"#
    switch ProjectWorkConfig.parse(Data(j.utf8)) { case .success(let ok): return ok.config; case .failure(let e): throw e }
}

@Suite struct FactoryBaitTests {
    // MARK: catalog

    @Test func catalogReadWhole() throws {
        let d = try Data(contentsOf: repo.appendingPathComponent(FactoryBait.catalogPath))
        guard case .success(let c) = FactoryBait.parseCatalog(d) else { Issue.record("\(String(describing: failure(FactoryBait.parseCatalog(d))?.message))"); return }
        #expect(c.baits.map(\.id) == ["logica", "teste-fraco", "segredo-no-diff", "corrida", "spec-editado", "gate-editado"])
        #expect(Set(c.baits.map(\.id)).count == c.baits.count)
        // F3: the judge does not guard the task's check, so the edited check is the reviewer's to veto
        let spec = c.baits.first { $0.id == "spec-editado" }
        #expect(spec?.layer == .review && spec?.expect == .veto && spec?.description.contains("juiz não protege") == true)
        // F5b (N9): the judge layer has its bait: the copy's gate cites the script the agent edits, a guard refuses it
        let gate = c.baits.first { $0.id == "gate-editado" }
        #expect(gate?.layer == .judge && gate?.expect == .`guard` && gate?.stack == "any" && gate?.description.contains("scripts/check-isca.sh") == true)
        #expect(c.baits.filter { $0.id != "gate-editado" }.allSatisfy { $0.layer == .review && $0.expect == .veto })
        #expect(Set(c.baits.map(\.stack)) == ["swift", "any"])
        #expect(FactoryBait.text(c).split(separator: "\n").count == 6)
        // F5b: the copy can never push, and the Swift baits (no target in Package.swift) are documented as the reviewer's only
        let skill = String(decoding: try Data(contentsOf: repo.appendingPathComponent("docs/fabrica/skill/factory-bait/SKILL.md")), as: UTF8.self)
        for w in ["config remote.pushDefault /dev/null", "hooks/pre-push", "medem só o revisor", "gate-editado"] { #expect(skill.contains(w), "\(w)") }
    }

    @Test func everyPatchAppliesOnAFixture() throws {
        let d = try Data(contentsOf: repo.appendingPathComponent(FactoryBait.catalogPath))
        guard case .success(let c) = FactoryBait.parseCatalog(d) else { Issue.record("catalog"); return }
        let fix = try dir("isca-fix")
        defer { try? FileManager.default.removeItem(at: fix) }
        // the skill's copy: a repository plus the base the skill commits before the patch
        try put(fix, "Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Fixture\")\n")
        try FileManager.default.copyItem(at: repo.appendingPathComponent("docs/fabrica/iscas/base/scripts"), to: fix.appendingPathComponent("scripts"))
        #expect(try git(["init", "-q"], in: fix) == 0)
        #expect(try git(["add", "-A"], in: fix) == 0 && git(["commit", "-qm", "base"], in: fix) == 0)
        for b in c.baits {
            let patch = repo.appendingPathComponent(b.patch)
            #expect(FileManager.default.fileExists(atPath: patch.path), "\(b.id)")
            #expect(try git(["apply", "--check", patch.path], in: fix) == 0, "\(b.id): git apply --check")
        }
    }

    @Test func catalogStrict() {
        let ok = #"{"id": "x", "stack": "any", "layer": "review", "description": "d", "patch": "docs/fabrica/iscas/patches/x.patch", "expect": "veto"}"#
        if case .failure(let e) = catalog(#"{"version": 1, "baits": [\#(ok)]}"#) { Issue.record("\(e.message)") }
        for bad in ["../fora.patch", "/tmp/x.patch", "docs/../../x.patch", ""] {
            let j = #"{"version": 1, "baits": [{"id": "x", "stack": "any", "layer": "review", "description": "d", "patch": "\#(bad)", "expect": "veto"}]}"#
            #expect(failure(catalog(j)) == .badPath(path: "baits[0].patch"), "\(bad)")
        }
        #expect(failure(catalog(#"{"version": 1, "baits": [], "extra": 1}"#)) == .unknownField("extra"))
        let unknown = ok.replacingOccurrences(of: #""expect""#, with: #""cor": "azul", "expect""#)
        #expect(failure(catalog(#"{"version": 1, "baits": [\#(unknown)]}"#)) == .unknownField("baits[0].cor"))
        #expect(failure(catalog(#"{"version": 2, "baits": []}"#)) == .unsupportedVersion("2"))
        #expect(failure(catalog(#"{"version": 1, "baits": [\#(ok), \#(ok)]}"#)) == .duplicate(path: "baits[].id", value: "x"))
        #expect(failure(catalog(#"{"version": 1, "baits": [\#(ok.replacingOccurrences(of: "\"veto\"", with: "\"talvez\""))]}"#))
                == .badChoice(path: "baits[0].expect", value: "talvez", allowed: ["veto", "check-fail", "guard"]))
        #expect(failure(catalog(#"{"version": 1, "baits": [\#(ok.replacingOccurrences(of: "\"review\"", with: "\"lint\""))]}"#)) != nil)
        #expect(failure(catalog("não é json")) == .badJSON("catalogo.json"))
    }

    // MARK: results

    @Test func resultsRoundTripAndRates() throws {
        let text = sample.render()
        #expect(text == sample.render() && text.hasSuffix("\n"))
        guard case .success(let back) = results(text) else { Issue.record("\(String(describing: failure(results(text))?.message))"); return }
        #expect(back == sample && back.render() == text)
        #expect(sample.captureRateByLayer() == ["review": .init(caught: 2, total: 3), "judge": .init(caught: 0, total: 1)])
        // a persona's denominator is the review layer's runs (3), not every run (4): the report's case "1 of 3"
        #expect(sample.captureRateByPersona() == ["correcao": .init(caught: 1, total: 3), "seguranca": .init(caught: 1, total: 3)])
        #expect(sample.escaped() == ["review": 1, "judge": 1])
        #expect(BaitResults().escaped().isEmpty && BaitResults().captureRateByLayer().isEmpty)
        // F5a (N3): a judge run carrying a persona is not that persona's catch (the numerator counts only the review layer)
        let judged = BaitResults(runs: sample.runs + [.init(bait: "j", date: "d", caught: true, layer: .judge, persona: "correcao", costSeconds: 1)])
        #expect(judged.captureRateByPersona() == ["correcao": .init(caught: 1, total: 3), "seguranca": .init(caught: 1, total: 3)])
        #expect(BaitResults(runs: [.init(bait: "j", date: "d", caught: true, layer: .judge, persona: "p", costSeconds: 1)]).captureRateByPersona().isEmpty)
        let r = sample.report()
        #expect(r.contains("review: 2/3 (66%)") && r.contains("correcao: 1/3 (33%)") && r.contains("custo: 1020 s"))
        #expect(r.contains("corrida (2026-11-23, camada review)") && r.contains("spec-editado"))
        #expect(BaitResults().report().contains("nenhuma isca passou"))
    }

    @Test func resultsStrict() {
        let run = #"{"bait": "logica", "date": "2026-11-23", "caught": true, "layer": "review", "costSeconds": 1}"#
        if case .failure(let e) = results(#"{"version": 1, "runs": [\#(run)]}"#) { Issue.record("\(e.message)") }
        #expect(failure(results(#"{"version": 1, "runs": [], "x": 0}"#)) == .unknownField("x"))
        #expect(failure(results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: "\"date\"", with: "\"nota\": 1, \"date\""))]}"#)) == .unknownField("runs[0].nota"))
        #expect(failure(results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: ", \"layer\": \"review\"", with: ""))]}"#)) == .caughtWithoutLayer(path: "runs[0]"))
        #expect(failure(results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: "true", with: "1"))]}"#)) == .wrongType(path: "runs[0].caught", expected: "booleano"))
        #expect(failure(results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: "\"costSeconds\": 1", with: "\"costSeconds\": -5"))]}"#)) == .outOfRange(path: "runs[0].costSeconds", value: -5))
        // an escaped run may omit the persona (null too) but must carry the layer it got past
        if case .failure(let e) = results(#"{"version": 1, "runs": [{"bait": "x", "date": "d", "caught": false, "layer": "judge", "persona": null, "costSeconds": 0}]}"#) { Issue.record("\(e.message)") }
        for l in [#""layer": null, "#, ""] {
            #expect(failure(results(#"{"version": 1, "runs": [{"bait": "x", "date": "d", "caught": false, \#(l)"costSeconds": 0}]}"#)) == .escapedWithoutLayer(path: "runs[0]"), "\(l)")
        }
        // the cost has a ceiling (a week), so no sum traps
        #expect(failure(results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: "\"costSeconds\": 1", with: "\"costSeconds\": 604801"))]}"#)) == .outOfRange(path: "runs[0].costSeconds", value: 604801))
        if case .failure(let e) = results(#"{"version": 1, "runs": [\#(run.replacingOccurrences(of: "\"costSeconds\": 1", with: "\"costSeconds\": 604800"))]}"#) { Issue.record("\(e.message)") }
        let huge = run.replacingOccurrences(of: "\"costSeconds\": 1", with: "\"costSeconds\": 9000000000000000000")
        #expect(failure(results(#"{"version": 1, "runs": [\#(huge), \#(huge)]}"#)) == .outOfRange(path: "runs[0].costSeconds", value: 9_000_000_000_000_000_000))
    }

    @Test func costSumSaturates() {   // runs built in code skip the parser's ceiling: the sum still never traps
        let big = BaitResults.Run(bait: "x", date: "d", caught: true, layer: .review, costSeconds: 9_000_000_000_000_000_000)
        let r = BaitResults(runs: [big, big])
        #expect(r.totalCost == Int.max && r.report().contains("custo: \(Int.max) s"))
        #expect(sample.totalCost == 1020)
    }

    // MARK: the doctor

    @Test func escapedFromTheFileLowersTheLayer() throws {
        let c: ProjectWorkConfig
        switch ProjectWorkConfig.parse(Data(#"{"gate": "swift test"}"#.utf8)) { case .success(let ok): c = ok.config; case .failure(let e): throw e }
        let clean = FactoryDoctor.score(FactoryDoctor.Snapshot(config: c))
        let hit = FactoryDoctor.score(FactoryDoctor.Snapshot(config: c, baits: sample.doctorInput))
        let s = { (r: FactoryDoctor.Report, l: FactoryDoctor.Layer) in r.layers.first { $0.layer == l }!.score }
        #expect(s(hit, .judge) == max(0, s(clean, .judge) - 1) && s(hit, .static) == s(clean, .static))

        // the reader fills the snapshot from .collie/factory/bait-results.json; a bad file or a link is refused
        let proj = try dir("isca-doc")
        defer { try? FileManager.default.removeItem(at: proj) }
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        guard case .success(let none) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("snapshot"); return }
        #expect(none.baits == nil)
        try put(proj, FactoryBait.resultsPath, sample.render())
        guard case .success(let snap) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("snapshot"); return }
        #expect(snap.baits == FactoryDoctor.BaitResults(escapedBaits: ["review": 1, "judge": 1]))
        // an invalid file does not take the doctor down: a bad root marks every layer, a bad run only its own layer
        try put(proj, FactoryBait.resultsPath, #"{"version": 1, "runs": [], "x": 1}"#)
        guard case .success(let bad) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("bad file took the doctor down"); return }
        #expect(Set(bad.baits?.errors.keys.map { $0 } ?? []) == Set(FactoryDoctor.Layer.allCases.map(\.rawValue)))
        #expect(bad.baits?.errors["judge"]?.contains("campo desconhecido 'x'") == true)
        let good = #"{"bait": "a", "date": "d", "caught": true, "layer": "review", "costSeconds": 1}"#
        try put(proj, FactoryBait.resultsPath, #"{"version": 1, "runs": [\#(good), {"bait": "b", "date": "d", "caught": true, "layer": "judge", "costSeconds": -1}]}"#)
        guard case .success(let one) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("bad run took the doctor down"); return }
        #expect(one.baits?.errors.keys.sorted() == ["judge"] && one.baits?.escapedBaits.isEmpty == true)
        let marked = FactoryDoctor.score(FactoryDoctor.Snapshot(config: c, baits: one.baits))
        #expect(s(marked, .judge) == max(0, s(clean, .judge) - 1) && s(marked, .static) == s(clean, .static))
        #expect(marked.layers.first { $0.layer == .judge }!.evidence.last?.hasPrefix("erro: .collie/factory/bait-results.json: 'runs[1].costSeconds'") == true)
        // F5a (N4): the error does not hide the valid escapes of the other layers
        let gone = #"{"bait": "c", "date": "d", "caught": false, "layer": "review", "costSeconds": 1}"#
        try put(proj, FactoryBait.resultsPath, #"{"version": 1, "runs": [\#(gone), {"bait": "b", "date": "d", "caught": true, "layer": "judge", "costSeconds": -1}]}"#)
        guard case .success(let mixed) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("mixed"); return }
        #expect(mixed.baits == FactoryDoctor.BaitResults(escapedBaits: ["review": 1], errors: ["judge": mixed.baits?.errors["judge"] ?? "?"]))
        #expect(mixed.baits?.errors.keys.sorted() == ["judge"])
        let full = try cfgReview()
        let both = FactoryDoctor.score(FactoryDoctor.Snapshot(config: full, paths: ["docs/fabrica/personas/correcao.md"], baits: mixed.baits))
        let base = FactoryDoctor.score(FactoryDoctor.Snapshot(config: full, paths: ["docs/fabrica/personas/correcao.md"]))
        #expect(s(both, .review) == s(base, .review) - 1 && s(both, .judge) == max(0, s(base, .judge) - 1))
        let file = proj.appendingPathComponent(FactoryBait.resultsPath)
        try FileManager.default.removeItem(at: file)
        let outside = try dir("isca-out")
        defer { try? FileManager.default.removeItem(at: outside) }
        try put(outside, "r.json", sample.render())
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("r.json"))
        guard case .failure(let l) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("link accepted"); return }
        #expect(l.code == .invalidArgs && (l.message.contains("link simbólico") || l.message.contains("fora do projeto")), "\(l.message)")
    }

    // MARK: the command

    @Test func commandsAreRegistered() throws {
        for a in ["list", "report"] {
            let spec = try #require(Commands.spec("factory.bait.\(a)"))
            #expect(!spec.exposedToMCP && !spec.shepherdOnly && spec.params.map(\.name) == ["terminal"])
            #expect(try ArgvParser.parse(["factory", "bait", a]).command == "factory.bait.\(a)")
        }
    }

    @Test func listAndReportFromATerminal() async throws {
        let proj = try dir("isca-cmd")
        defer { try? FileManager.default.removeItem(at: proj) }
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                              args: ["name": .string("T"), "preset": .string("shell"), "cwd": .string(proj.path)]))
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let token = try await tokenOf(d, id)
            let call = { (c: String) in try await send(p, Request(id: "c", terminalId: id, token: token, command: c)) }
            #expect(try await call("factory.bait.list").error?.code == .notFound)
            let empty = try await call("factory.bait.report")
            guard case .object(let e)? = empty.result, case .string(let eo)? = e["output"] else { Issue.record("\(empty)"); return }
            #expect(eo.contains("nenhuma isca passou"))
            try put(proj, FactoryBait.catalogPath, String(decoding: try Data(contentsOf: repo.appendingPathComponent(FactoryBait.catalogPath)), as: UTF8.self))
            try put(proj, FactoryBait.resultsPath, sample.render())
            let list = try await call("factory.bait.list")
            guard case .object(let l)? = list.result, case .string(let lo)? = l["output"] else { Issue.record("\(list)"); return }
            #expect(lo.contains("spec-editado") && lo.split(separator: "\n").count == 5)
            let rep = try await call("factory.bait.report")
            guard case .object(let ro)? = rep.result, case .string(let out)? = ro["output"], case .object(let j)? = ro["report"] else { Issue.record("\(rep)"); return }
            #expect(out.contains("review: 2/3") && j["runs"] == .number(4) && j["costSeconds"] == .number(1020))
        }
    }
}
