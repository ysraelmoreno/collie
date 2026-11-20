import Testing
import Foundation
@testable import VizinhoKit

func tmpProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cercas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

private func fence(_ kind: Fence.Kind, module: String? = "Bad", suffix: String? = "Panel", baseline: [String] = []) -> Fence {
    Fence(kind: kind, dir: "Sources/P", suffix: suffix, ext: "swift", module: module, evidence: "0 de 11 importam \(module ?? "")",
          baseline: baseline)
}

private func respond(_ root: URL, event: String = "stop", files: [String], data: URL?) throws -> Data {
    let body = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "event": event, "project": root.path, "files": files] as [String: Any])
    return Vizinho.respond(eventJSON: body, dataDir: data)
}

private func panels11() -> [String: String] {
    var f: [String: String] = [:]
    for i in 0..<11 { f["Sources/P/Item\(i)Panel.swift"] = "import Foundation\nimport CollieCore\nstruct Item\(i)Panel {}\n" }
    return f
}

@Suite struct FencesTests {
    @Test func forbidImportBreaksOnlyWhenImported() throws {
        let root = try tmpProject(["Sources/P/AlfaPanel.swift": "import Bad\n", "Sources/P/BetaPanel.swift": "import Foundation\n"])
        let f = fence(.forbidImport)
        let v = Fences.check(project: root, files: ["Sources/P/AlfaPanel.swift", "Sources/P/BetaPanel.swift"], fences: [f])
        #expect(v == [Violation(file: "Sources/P/AlfaPanel.swift", fence: f)])
    }

    @Test func requireImportBreaksOnlyWhenMissing() throws {
        let root = try tmpProject(["Sources/P/AlfaPanel.swift": "import Foundation\n", "Sources/P/BetaPanel.swift": "import Bad\n"])
        let f = fence(.requireImport)
        let v = Fences.check(project: root, files: ["Sources/P/AlfaPanel.swift", "Sources/P/BetaPanel.swift"], fences: [f])
        #expect(v == [Violation(file: "Sources/P/AlfaPanel.swift", fence: f)])
    }

    @Test func requireTestBreaksUntilThePairExists() throws {
        let root = try tmpProject(["Sources/P/FooPanel.swift": "struct FooPanel {}\n"])
        let f = fence(.requireTest, module: nil)
        #expect(Fences.check(project: root, files: ["Sources/P/FooPanel.swift"], fences: [f]).count == 1)
        try "".write(to: root.appendingPathComponent("FooPanelTests.swift"), atomically: true, encoding: .utf8)
        #expect(Fences.check(project: root, files: ["Sources/P/FooPanel.swift"], fences: [f]).isEmpty)
    }

    @Test func baselineFileIsTolerated() throws {
        let root = try tmpProject(["Sources/P/AlfaPanel.swift": "import Bad\n"])
        let f = fence(.forbidImport, baseline: ["Sources/P/AlfaPanel.swift"])
        #expect(Fences.check(project: root, files: ["Sources/P/AlfaPanel.swift"], fences: [f]).isEmpty)
    }

    @Test func filesOutsideTheGroupAreNotChecked() throws {
        let root = try tmpProject([
            "Sources/Q/QuiPanel.swift": "import Bad\n",      // other folder
            "Sources/P/Plain.swift": "import Bad\n",       // no Panel suffix
            "Sources/P/XisPanel.kt": "import Bad\n",         // other extension
        ])
        let files = ["Sources/Q/QuiPanel.swift", "Sources/P/Plain.swift", "Sources/P/XisPanel.kt"]
        #expect(Fences.check(project: root, files: files, fences: [fence(.forbidImport)]).isEmpty)
        // suffix null = every file of the folder with the extension: Plain.swift now counts, the other two still do not
        let all = Fences.check(project: root, files: files, fences: [fence(.forbidImport, suffix: nil)])
        #expect(all.map(\.file) == ["Sources/P/Plain.swift"])
    }

    @Test func deletedFileIsIgnored() throws {
        let root = try tmpProject([:])
        #expect(Fences.check(project: root, files: ["Sources/P/GonePanel.swift", "../x/OutPanel.swift"], fences: [fence(.forbidImport)]).isEmpty)
    }

    @Test func ratchetShrinksBaselineAndNeverGrowsIt() throws {
        let root = try tmpProject([
            "Sources/P/AlfaPanel.swift": "import Foundation\n",   // fixed
            "Sources/P/BetaPanel.swift": "import Bad\n",          // still breaks, tolerated
            "Sources/P/DeltaPanel.swift": "import Foundation\n",   // fixed, but not checked this time
        ])
        let file = root.appendingPathComponent("data/cercas.json")
        let f = fence(.forbidImport, baseline: ["Sources/P/AlfaPanel.swift", "Sources/P/BetaPanel.swift", "Sources/P/DeltaPanel.swift"])
        try Fences.write([f], to: file)
        let v = Fences.check(project: root, files: ["Sources/P/AlfaPanel.swift", "Sources/P/BetaPanel.swift"],
                             fences: Fences.load(file), fencesFile: file)
        #expect(v.isEmpty)
        #expect(Fences.load(file).first?.baseline == ["Sources/P/BetaPanel.swift", "Sources/P/DeltaPanel.swift"])
        // a new file that breaks is reported, and the baseline on disk does not take it in
        try "import Bad\n".write(to: root.appendingPathComponent("Sources/P/GamaPanel.swift"), atomically: true, encoding: .utf8)
        let again = Fences.check(project: root, files: ["Sources/P/GamaPanel.swift", "Sources/P/BetaPanel.swift"],
                                 fences: Fences.load(file), fencesFile: file)
        #expect(again.map(\.file) == ["Sources/P/GamaPanel.swift"])
        #expect(Fences.load(file).first?.baseline == ["Sources/P/BetaPanel.swift", "Sources/P/DeltaPanel.swift"])
    }

    @Test func loadIsForgivingAndReadsTheDocumentedFormat() throws {
        let root = try tmpProject(["bad.json": "lixo", "ok.json": """
            [{ "id": "forbid-import:Sources/ColliePlugins:Panel:CollieDaemonKit", "kind": "forbid-import",
               "dir": "Sources/ColliePlugins", "suffix": "Panel", "ext": "swift", "module": "CollieDaemonKit",
               "evidence": "0 de 11 importam CollieDaemonKit", "baseline": [] }]
            """])
        #expect(Fences.load(root.appendingPathComponent("missing.json")).isEmpty)
        #expect(Fences.load(root.appendingPathComponent("bad.json")).isEmpty)
        let expected = Fence(kind: .forbidImport, dir: "Sources/ColliePlugins", suffix: "Panel", ext: "swift",
                             module: "CollieDaemonKit", evidence: "0 de 11 importam CollieDaemonKit")
        #expect(Fences.load(root.appendingPathComponent("ok.json")) == [expected])
        // null suffix survives a round trip
        let whole = fence(.requireTest, module: nil, suffix: nil)
        let out = root.appendingPathComponent("out.json")
        try Fences.write([whole], to: out)
        #expect(Fences.load(out) == [whole])
        #expect(try String(contentsOf: out, encoding: .utf8).contains("\"suffix\" : null"))
    }

    @Test func worktreesShareTheKey() throws {
        let main = try tmpProject([".git/HEAD": "ref: refs/heads/main\n", "Sources/x.swift": ""])
        let other = try tmpProject([".git/HEAD": "ref: refs/heads/main\n"])
        let wt = try tmpProject([".git": "gitdir: \(main.path)/.git/worktrees/wt\n"])
        #expect(Fences.key(project: wt) == Fences.key(project: main))
        #expect(Fences.key(project: other) != Fences.key(project: main))
        #expect(Fences.key(project: main).count == 16)
        // inside a subfolder the root is still found
        #expect(Fences.key(project: main.appendingPathComponent("Sources")) == Fences.key(project: main))
    }
}

@Suite struct FencesRespondTests {
    @Test func stopBlocksWithTheFenceText() throws {
        var f = panels11()
        f["Sources/P/FooPanel.swift"] = "import CollieDaemonKit\n"
        let root = try tmpProject(f)
        let data = try tmpProject([:])
        let ban = Fence(kind: .forbidImport, dir: "Sources/P", suffix: "Panel", ext: "swift", module: "CollieDaemonKit",
                        evidence: "0 de 11 importam CollieDaemonKit")
        try Fences.write([ban], to: data.appendingPathComponent(Fences.key(project: root)).appendingPathComponent("cercas.json"))
        let out = try #require(try JSONSerialization.jsonObject(with: respond(root, files: ["Sources/P/FooPanel.swift"], data: data)) as? [String: String])
        #expect(out["block"] == """
            Cerca quebrada (aprovada pelo dono do projeto):
            - Sources/P/FooPanel.swift importa CollieDaemonKit; 0 de 11 arquivos *Panel.swift desta pasta importam.
              Causa raiz: o que você precisa de CollieDaemonKit deve chegar pelo que os irmãos usam. Modelo: Sources/P/Item0Panel.swift
            """)
        // a clean file of the same turn: nothing
        #expect(try respond(root, files: ["Sources/P/Item0Panel.swift"], data: data) == Data("{}".utf8))
    }

    @Test func blockHasAtMostFiveBreaksAndEighteenHundredCharacters() throws {
        var f = panels11()
        for i in 0..<7 { f["Sources/P/Bad\(i)Panel.swift"] = "import CollieDaemonKit\n" }
        let root = try tmpProject(f)
        let data = try tmpProject([:])
        let ban = Fence(kind: .forbidImport, dir: "Sources/P", suffix: "Panel", ext: "swift", module: "CollieDaemonKit",
                        evidence: "0 de 11 importam CollieDaemonKit")
        try Fences.write([ban], to: data.appendingPathComponent(Fences.key(project: root)).appendingPathComponent("cercas.json"))
        let files = (0..<7).map { "Sources/P/Bad\($0)Panel.swift" }
        let out = try #require(try JSONSerialization.jsonObject(with: respond(root, files: files, data: data)) as? [String: String])
        let text = try #require(out["block"])
        #expect(text.components(separatedBy: "\n- ").count - 1 == 5)
        #expect(text.count <= 1800)
    }

    @Test func noFencesFileOrNoDataFolderMeansNothingToSay() throws {
        var f = panels11()
        f["Sources/P/FooPanel.swift"] = "import CollieDaemonKit\n"
        let root = try tmpProject(f)
        let data = try tmpProject([:])
        #expect(try respond(root, files: ["Sources/P/FooPanel.swift"], data: data) == Data("{}".utf8))
        #expect(try respond(root, files: ["Sources/P/FooPanel.swift"], data: nil) == Data("{}".utf8))
    }

    @Test func proposalsAreWrittenWhenMissingAndKeptFor24Hours() throws {
        var f = panels11()
        f["Sources/CollieCore/Core.swift"] = ""   // a project module: only those are proposed
        let root = try tmpProject(f)
        let data = try tmpProject([:])
        let file = data.appendingPathComponent(Fences.key(project: root)).appendingPathComponent("propostas.json")
        _ = try respond(root, files: [], data: data)
        #expect(Fences.load(file).isEmpty == false)
        // fresh file: not rewritten
        try "[]".write(to: file, atomically: true, encoding: .utf8)
        _ = try respond(root, files: [], data: data)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[]")
        // older than 24 h: rewritten
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: file.path)
        _ = try respond(root, files: [], data: data)
        #expect(Fences.load(file).isEmpty == false)
    }

    @Test func approvedProposalDoesNotComeBack() throws {
        var f = panels11()
        // both imports are modules of this project (only those are proposed); "Foundation" here is just a folder name
        f["Sources/CollieCore/Core.swift"] = ""
        f["Sources/Foundation/F.swift"] = ""
        let root = try tmpProject(f)
        let data = try tmpProject([:])
        let dir = data.appendingPathComponent(Fences.key(project: root))
        let approved = Fence(kind: .requireImport, dir: "Sources/P", suffix: "Panel", ext: "swift", module: "CollieCore",
                             evidence: "11 de 11 importam CollieCore")
        try Fences.write([approved], to: dir.appendingPathComponent("cercas.json"))
        _ = try respond(root, files: [], data: data)
        // the folder imports Foundation and CollieCore everywhere: two proposals, one already approved
        #expect(Fences.load(dir.appendingPathComponent("propostas.json")).map(\.id) == ["require-import:Sources/P:Panel:Foundation"])
    }
}
