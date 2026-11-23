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

@Suite struct FactoryBaitTests {
    // MARK: catalog

    @Test func catalogReadWhole() throws {
        let d = try Data(contentsOf: repo.appendingPathComponent(FactoryBait.catalogPath))
        guard case .success(let c) = FactoryBait.parseCatalog(d) else { Issue.record("\(String(describing: failure(FactoryBait.parseCatalog(d))?.message))"); return }
        #expect(c.baits.map(\.id) == ["logica", "teste-fraco", "segredo-no-diff", "corrida", "spec-editado"])
        #expect(Set(c.baits.map(\.id)).count == c.baits.count)
        #expect(c.baits.first { $0.id == "spec-editado" }?.layer == .judge && c.baits.first { $0.id == "logica" }?.layer == .review)
        #expect(Set(c.baits.map(\.stack)) == ["swift", "any"])
        #expect(FactoryBait.text(c).split(separator: "\n").count == 5)
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
        #expect(sample.captureRateByPersona() == ["correcao": .init(caught: 1, total: 4), "seguranca": .init(caught: 1, total: 4)])
        #expect(sample.escaped() == ["review": 1, "judge": 1])
        #expect(BaitResults().escaped().isEmpty && BaitResults().captureRateByLayer().isEmpty)
        let r = sample.report()
        #expect(r.contains("review: 2/3 (66%)") && r.contains("correcao: 1/4 (25%)") && r.contains("custo: 1020 s"))
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
        // an escaped run may omit the persona and carry the layer it got past; null is accepted for both
        if case .failure(let e) = results(#"{"version": 1, "runs": [{"bait": "x", "date": "d", "caught": false, "layer": null, "persona": null, "costSeconds": 0}]}"#) { Issue.record("\(e.message)") }
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
        try put(proj, FactoryBait.resultsPath, #"{"version": 1, "runs": [], "x": 1}"#)
        guard case .failure(let e) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("bad file accepted"); return }
        #expect(e.message.contains("campo desconhecido 'x'"))
        let file = proj.appendingPathComponent(FactoryBait.resultsPath)
        try FileManager.default.removeItem(at: file)
        let outside = try dir("isca-out")
        defer { try? FileManager.default.removeItem(at: outside) }
        try put(outside, "r.json", sample.render())
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("r.json"))
        guard case .failure(let l) = FactoryDoctorReader.snapshot(root: proj) else { Issue.record("link accepted"); return }
        #expect(l.message.contains("link simbólico"))
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
