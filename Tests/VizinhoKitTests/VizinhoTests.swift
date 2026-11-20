import Testing
import Foundation
@testable import VizinhoKit

private func project(_ files: [String: String]) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vizinho-\(UUID().uuidString)")
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

private func panels(_ n: Int, dir: String = "Sources/P", imports: String = "import Foundation\nimport CollieCore\n",
                    extra: [String: String] = [:]) -> [String: String] {
    var f = extra
    for i in 0..<n { f["\(dir)/Item\(i)Panel.swift"] = imports + "struct Item\(i)Panel {}\n" }
    return f
}

@Suite struct VizinhoTests {
    @Test func camelAndDottedSuffix() {
        #expect(Vizinho.typeSuffix("FooPanel") == "Panel")
        #expect(Vizinho.typeSuffix("foo.test") == ".test")
        #expect(Vizinho.typeSuffix("foo.service") == ".service")
        #expect(Vizinho.typeSuffix("foo") == nil)
        #expect(Vizinho.typeSuffix("Foo") == nil)
    }

    @Test func missingImportAndFormat() {
        var f = panels(11)
        f["Sources/P/FooPanel.swift"] = "import Foundation\nstruct FooPanel {}\n"
        f["Sources/P/Other.swift"] = "import Nope\n"   // other type: not a sibling
        let g = Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift")
        #expect(g?.hasPrefix("Sources/P/FooPanel.swift: 11 arquivos *Panel.swift nesta pasta seguem a mesma forma.\nModelo: Sources/P/Item") == true)
        #expect(g?.contains("- 11 de 11 importam CollieCore; este não importa") == true)
    }

    @Test func fewerThanThreeSiblings() {
        var f = panels(2)
        f["Sources/P/FooPanel.swift"] = "struct FooPanel {}\n"
        #expect(Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift") == nil)
    }

    @Test func importNobodyHas() {
        var f = panels(5)
        f["Sources/P/FooPanel.swift"] = "import Foundation\nimport CollieCore\nimport CollieDaemonKit\n"
        let g = Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift")
        #expect(g?.contains("- 0 de 5 importam CollieDaemonKit; este importa") == true)
        // under 5 siblings the "nobody has it" fact is off
        var f4 = panels(4)
        f4["Sources/P/FooPanel.swift"] = "import Foundation\nimport CollieCore\nimport CollieDaemonKit\n"
        #expect(Vizinho.guide(project: project(f4), file: "Sources/P/FooPanel.swift") == nil)
    }

    @Test func pairedTestMissing() {
        var f = panels(5)
        for i in 0..<4 { f["Tests/PTests/Item\(i)PanelTests.swift"] = "" }
        f["Sources/P/FooPanel.swift"] = "import Foundation\nimport CollieCore\n"
        let g = Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift")
        #expect(g?.contains("- 4 de 5 têm teste (ex.: Tests/PTests/Item0PanelTests.swift); este não tem") == true)
        f["Tests/PTests/FooPanelTests.swift"] = ""
        #expect(Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift") == nil)
    }

    @Test func modelIsMedianOfMajorityNotClosestName() {
        var f: [String: String] = [:]
        f["s/AaaPanel.swift"] = "import A\nimport B\n" + String(repeating: "//x\n", count: 50)   // has all, biggest
        f["s/BbbPanel.swift"] = "import A\nimport B\n" + String(repeating: "//x\n", count: 10)
        f["s/CccPanel.swift"] = "import A\nimport B\n"                                             // smallest
        f["s/EeePanel.swift"] = "import A\nimport B\n" + String(repeating: "//x\n", count: 30)
        f["s/FffPanel.swift"] = "import A\nimport B\n" + String(repeating: "//x\n", count: 5)   // 5 of 6 have B (83%); Bbb is the median size
        f["s/DddPanel.swift"] = "import Weed\n"                                                  // lacks majority imports
        f["s/AaabPanel.swift"] = "import A\n"                                                    // new file, name-closest to Aaa
        let g = Vizinho.guide(project: project(f), file: "s/AaabPanel.swift")
        #expect(g?.contains("Modelo: s/BbbPanel.swift") == true)
        #expect(g?.contains("importam B; este não importa") == true)
    }

    @Test func noFactsIsNil() {
        var f = panels(5)
        f["Sources/P/FooPanel.swift"] = "import Foundation\nimport CollieCore\n"
        for i in 0..<5 { f["Tests/Item\(i)PanelTests.swift"] = ""; }
        f["Tests/FooPanelTests.swift"] = ""
        #expect(Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift") == nil)
    }

    @Test func ignoredFolders() {
        var f = panels(5, dir: "node_modules/x")
        f["node_modules/x/FooPanel.swift"] = "struct FooPanel {}\n"
        #expect(Vizinho.guide(project: project(f), file: "node_modules/x/FooPanel.swift") == nil)
        // tests inside ignored folders do not count as pairs
        var g = panels(5)
        for i in 0..<5 { g["build/Item\(i)PanelTests.swift"] = "" }
        g["Sources/P/FooPanel.swift"] = "import Foundation\nimport CollieCore\n"
        #expect(Vizinho.guide(project: project(g), file: "Sources/P/FooPanel.swift") == nil)
    }

    @Test func otherLanguages() {
        var f: [String: String] = [:]
        for i in 0..<3 { f["src/a\(i).service.ts"] = "import { x } from './base'\n" }
        f["src/new.service.ts"] = "export const a = 1\n"
        let g = Vizinho.guide(project: project(f), file: "src/new.service.ts")
        #expect(g?.contains("*.service.ts") == true && g?.contains("importam ./base") == true)
        #expect(Vizinho.imports("from a.b import c\nimport os, sys as s\n", ext: "py") == ["a.b", "os", "sys"])
        #expect(Vizinho.imports("import static a.B.c;\nimport x.Y\n", ext: "java") == ["a.B.c", "x.Y"])
        #expect(Vizinho.imports("@testable import Foo.Bar\nimport struct A.B\n", ext: "swift") == ["Foo", "A"])
        #expect(Vizinho.imports("import x\n", ext: "rb").isEmpty)
    }

    @Test func respondEditAndStop() throws {
        var f = panels(3)
        f["Sources/P/FooPanel.swift"] = "struct FooPanel {}\n"
        let root = project(f)
        func call(_ ev: String) throws -> [String: Any] {
            let body = #"{"apiVersion":1,"event":"\#(ev)","project":"\#(root.path)","files":["Sources/P/FooPanel.swift","nope.swift"]}"#
            return try JSONSerialization.jsonObject(with: Vizinho.respond(eventJSON: Data(body.utf8))) as! [String: Any]
        }
        #expect((try call("edit")["guide"] as? String)?.contains("importam CollieCore") == true)
        #expect(try call("stop").isEmpty)
        #expect(Vizinho.respond(eventJSON: Data("lixo".utf8)) == Data("{}".utf8))
    }

    @Test func sizeLimits() throws {
        var many = ""
        for i in 0..<80 { many += "import Mod\(i)LongLongLongName\n" }
        // every sibling has the 80 imports: 80 facts, so the text must be cut
        var f = panels(3, imports: many)
        f["Sources/P/FooPanel.swift"] = "struct FooPanel {}\n"
        let g = try #require(Vizinho.guide(project: project(f), file: "Sources/P/FooPanel.swift"))
        #expect(g.count <= 1200)
        // a file past 256 KiB is read only up to the limit
        let huge = String(repeating: "x", count: 300_000)
        let url = project(["h.txt": huge]).appendingPathComponent("h.txt")
        #expect(Vizinho.read(url)?.utf8.count == 256 * 1024)
    }

    @Test func fastOnTwoHundredFiles() {
        var f = panels(200)
        f["Sources/P/FooPanel.swift"] = "struct FooPanel {}\n"
        let root = project(f)
        let t = Date()
        let g = Vizinho.guide(project: root, file: "Sources/P/FooPanel.swift")
        #expect(g != nil)
        #expect(Date().timeIntervalSince(t) < 1)
    }
}
