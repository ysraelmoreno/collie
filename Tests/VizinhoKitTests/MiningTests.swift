import Testing
import Foundation
@testable import VizinhoKit

private func panels(_ n: Int, dir: String = "Sources/P", imports: String = "import Foundation\nimport CollieCore\n",
                    skipImports: Set<Int> = [], tests: Range<Int> = 0..<0) -> [String: String] {
    var f: [String: String] = [:]
    for i in 0..<n {
        f["\(dir)/Item\(i)Panel.swift"] = (skipImports.contains(i) ? "" : imports) + "struct Item\(i)Panel {}\n"
    }
    for i in tests { f["Tests/PTests/Item\(i)PanelTests.swift"] = "" }
    f["Sources/CollieCore/Core.swift"] = "enum Core {}\n"   // CollieCore is a module of the project, not a system one
    return f
}

@Suite struct MiningTests {
    @Test func systemModulesAreNotRequired() throws {
        // all ten import Foundation and CollieCore: only the project's own module becomes a fence
        let r = Mining.propose(project: try tmpProject(panels(10)))
        #expect(r.contains { $0.kind == .requireImport && $0.module == "CollieCore" })
        #expect(!r.contains { $0.module == "Foundation" })
    }

    @Test func aFolderNeverForbidsItsOwnModuleOrWhatASubfolderImports() throws {
        var f: [String: String] = [:]
        // Sources/Kit: ten files at the top import nothing; its subfolder imports Dev
        for i in 0..<10 { f["Sources/Kit/Top\(i).swift"] = "enum Top\(i) {}\n" }
        f["Sources/Kit/Sub/Inner.swift"] = "import Dev\n"
        // elsewhere: twelve files import Kit, Dev and Ui (so the three are imported often enough outside Kit)
        for i in 0..<12 { f["Sources/App/Use\(i).swift"] = "import Kit\nimport Dev\nimport Ui\n" }
        f["Sources/Dev/D.swift"] = ""
        f["Sources/Ui/U.swift"] = ""
        let r = Mining.propose(project: try tmpProject(f)).filter { $0.kind == .forbidImport && $0.dir == "Sources/Kit" }
        #expect(r.map(\.module) == ["Ui"])   // not Kit (itself), not Dev (Sub imports it)
    }

    @Test func requireImportNeedsTenFiles() throws {
        let r = Mining.propose(project: try tmpProject(panels(10)))
        let f = try #require(r.first { $0.kind == .requireImport && $0.module == "CollieCore" })
        #expect(f.id == "require-import:Sources/P:Panel:CollieCore")
        #expect(f.dir == "Sources/P" && f.suffix == "Panel" && f.ext == "swift")
        #expect(f.evidence == "10 de 10 importam CollieCore")
        #expect(f.baseline.isEmpty)
        // nine files: nothing at all
        #expect(Mining.propose(project: try tmpProject(panels(9))).isEmpty)
    }

    @Test func baselineHoldsTheCurrentOffenders() throws {
        // 19 of 20 = 95%: proposed, the odd one out is tolerated; 18 of 20 = 90%: not proposed
        let r = Mining.propose(project: try tmpProject(panels(20, skipImports: [19])))
        let f = try #require(r.first { $0.kind == .requireImport && $0.module == "CollieCore" })
        #expect(f.evidence == "19 de 20 importam CollieCore")
        #expect(f.baseline == ["Sources/P/Item19Panel.swift"])
        let weak = Mining.propose(project: try tmpProject(panels(20, skipImports: [18, 19])))
        #expect(weak.contains { $0.module == "CollieCore" } == false)
    }

    @Test func requireTestFromPairedTests() throws {
        let one = Mining.propose(project: try tmpProject(panels(10, imports: "", tests: 0..<10)))
        let t = try #require(one.first { $0.kind == .requireTest })
        #expect(t.module == nil && t.evidence == "10 de 10 têm teste par" && t.baseline.isEmpty)
        // 19 of 20 paired: proposed with the one missing in the baseline; 18 of 20: not proposed
        let many = Mining.propose(project: try tmpProject(panels(20, imports: "", tests: 0..<19)))
        let m = try #require(many.first { $0.kind == .requireTest && $0.suffix == "Panel" })
        #expect(m.evidence == "19 de 20 têm teste par" && m.baseline == ["Sources/P/Item19Panel.swift"])
        let weak = Mining.propose(project: try tmpProject(panels(20, imports: "", tests: 0..<18)))
        #expect(weak.contains { $0.kind == .requireTest && $0.suffix == "Panel" } == false)
    }

    @Test func forbidImportOfAProjectModuleUsedElsewhere() throws {
        var f = panels(10, imports: "import Foundation\n")
        f["Sources/CollieDaemonKit/Core.swift"] = ""          // the module exists in the project
        for i in 0..<10 { f["Sources/Other/O\(i).swift"] = "import CollieDaemonKit\n" }
        let r = Mining.propose(project: try tmpProject(f))
        let ban = try #require(r.first { $0.kind == .forbidImport && $0.dir == "Sources/P" })
        #expect(ban.module == "CollieDaemonKit" && ban.evidence == "0 de 10 importam CollieDaemonKit" && ban.baseline.isEmpty)
        // Foundation is imported by 10 files outside Sources/Other too, but it is not a module of the project
        #expect(r.contains { $0.kind == .forbidImport && $0.module == "Foundation" } == false)
    }

    @Test func forbidImportNeedsTenFilesOutsideAndAProjectModule() throws {
        var f = panels(10, imports: "import Foundation\n")
        f["Sources/Local/Core.swift"] = ""                     // Local is a project module, imported by only 9 files
        for i in 0..<9 { f["Sources/Third/L\(i).swift"] = "import Local\n" }
        for i in 0..<12 { f["Sources/Other/G\(i).swift"] = "import Ghost\n" }   // 12 files, but Ghost is not in the project
        let r = Mining.propose(project: try tmpProject(f))
        #expect(r.contains { $0.kind == .forbidImport } == false)
    }

    @Test func atMostFiftyProposals() throws {
        var f: [String: String] = [:]
        for d in 0..<60 { f.merge(panels(10, dir: "Sources/D\(d)", imports: "import CollieCore\n")) { a, _ in a } }
        #expect(Mining.propose(project: try tmpProject(f)).count == 50)
    }
}
