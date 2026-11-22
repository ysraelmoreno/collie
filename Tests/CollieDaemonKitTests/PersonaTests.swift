import Testing
import Foundation
@testable import CollieDaemonKit

/// R5: personas parsed from their front-matter and routed by the diff's paths and size.
struct PersonaTests {
    static func file(_ name: String, paths: String = #"["*"]"#, model: String = "sonnet") -> String {
        "---\nname: \(name)\nmodel: \(model)\npaths: \(paths)\n---\n# \(name)\nlente de \(name)\n"
    }

    /// The five personas, with the globs of docs/fabrica/personas/.
    static let files: [String: String] = [
        "correcao.md": file("correcao"),
        "testes.md": file("testes", paths: #"["Tests/**", "Sources/**"]"#),
        "motor-concorrencia.md": file("motor-concorrencia", paths: #"["Sources/CollieDaemonKit/Work/**", "Sources/CollieDaemonKit/Daemon*", "Sources/CollieDaemonKit/Sandbox/**", "Sources/CollieDaemonKit/Remote/**"]"#),
        "seguranca.md": file("seguranca", paths: #"["Sources/CollieDaemonKit/Sandbox/**", "Sources/CollieDaemonKit/Remote/**", "Helpers/**", "scripts/**", "Resources/**"]"#),
        "simplicidade.md": file("simplicidade", model: "haiku"),
    ]

    static func router() throws -> PersonaRouter { PersonaRouter(catalog: try PersonaCatalog.parse(files: files)) }

    static func names(_ paths: [String], lines: Int = 10, diff: String = "", requested: [String]? = nil,
                      max: Int = 4) throws -> [String] {
        try router().select(changedPaths: paths, diffLines: lines, diffText: diff, requested: requested, max: max).map(\.name)
    }

    @Test func validFrontMatterParses() throws {
        let p = try PersonaCatalog.parse(file: "testes.md", text: Self.files["testes.md"] ?? "")
        #expect(p == Persona(name: "testes", model: "sonnet", paths: ["Tests/**", "Sources/**"], body: "# testes\nlente de testes"))
        let noModel = try PersonaCatalog.parse(file: "x.md", text: "---\nname: x\npaths: [\"*\"]\n---\ncorpo")
        #expect(noModel.model == nil)
    }

    @Test(arguments: [
        ("sem front-matter", "# só corpo"),
        ("sem fechamento", "---\nname: x\npaths: [\"*\"]\ncorpo"),
        ("sem name", "---\npaths: [\"*\"]\n---\ncorpo"),
        ("sem paths", "---\nname: x\n---\ncorpo"),
        ("paths não JSON", "---\nname: x\npaths: Tests/**\n---\ncorpo"),
        ("paths vazio", "---\nname: x\npaths: []\n---\ncorpo"),
        ("chave desconhecida", "---\nname: x\npaths: [\"*\"]\ncolor: red\n---\ncorpo"),
        ("corpo vazio", "---\nname: x\npaths: [\"*\"]\n---\n  \n"),
        ("name com espaço", "---\nname: a b\npaths: [\"*\"]\n---\ncorpo"),
    ])
    func malformedIsRefusedWithReason(_ label: String, _ text: String) {
        #expect(throws: PersonaError.self, "\(label)") { try PersonaCatalog.parse(files: ["x.md": text]) }
        do { _ = try PersonaCatalog.parse(files: ["x.md": text]) } catch {
            guard case let .malformed(file, reason)? = error as? PersonaError else { Issue.record("\(error)"); return }
            #expect(file == "x.md")
            #expect(!reason.isEmpty)
        }
    }

    @Test func duplicateNameIsRefused() {
        #expect(throws: PersonaError.self) { try PersonaCatalog.parse(files: ["a.md": Self.file("x"), "b.md": Self.file("x")]) }
    }

    @Test func repoPersonasParse() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/fabrica/personas")
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".md") {
            files[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        let catalog = try PersonaCatalog.parse(files: files)
        #expect(catalog.map(\.name) == ["correcao", "motor-concorrencia", "seguranca", "simplicidade", "testes"])
        #expect(catalog.allSatisfy { $0.body.contains("Contrato de saída") })
    }

    @Test func docsOnlyCallsOnlyCorrecao() throws {
        #expect(try Self.names(["docs/feature-map.md", "README.md"]) == ["correcao"])
    }

    @Test func workCallsMotorAndTestes() throws {
        #expect(try Self.names(["Sources/CollieDaemonKit/Work/WorkLoop.swift"]) == ["correcao", "motor-concorrencia", "testes"])
    }

    @Test func testsCallTestes() throws {
        #expect(try Self.names(["Tests/CollieDaemonKitTests/PersonaTests.swift"]) == ["correcao", "testes"])
    }

    @Test func sandboxAndScriptsCallSeguranca() throws {
        #expect(try Self.names(["scripts/check.sh"]) == ["correcao", "seguranca"])
        #expect(try Self.names(["Sources/CollieDaemonKit/Sandbox/Profile.swift"]) == ["correcao", "seguranca", "motor-concorrencia", "testes"])
    }

    @Test func asyncCodeCallsMotor() throws {
        let diff = "+++ b/Sources/CollieCore/X.swift\n+    let v = await load()\n"
        #expect(try Self.names(["Sources/CollieCore/X.swift"], diff: diff) == ["correcao", "motor-concorrencia", "testes"])
        // removed lines and plain code do not count
        #expect(try Self.names(["Sources/CollieCore/X.swift"], diff: "-  await x\n+  let y = 1\n") == ["correcao", "testes"])
    }

    @Test func bigDiffCallsSimplicidade() throws {
        #expect(try Self.names(["docs/a.md"], lines: 150) == ["correcao"])
        #expect(try Self.names(["docs/a.md"], lines: 151) == ["correcao", "simplicidade"])
    }

    @Test func maxCutsLeastSpecificNeverCorrecao() throws {
        let all = ["Sources/CollieDaemonKit/Sandbox/P.swift", "Tests/X.swift"]
        #expect(try Self.names(all, lines: 400) == ["correcao", "seguranca", "motor-concorrencia", "testes"])
        #expect(try Self.names(all, lines: 400, max: 2) == ["correcao", "seguranca"])
        #expect(try Self.names(all, lines: 400, max: 0) == ["correcao"])
        #expect(try Self.names(all, lines: 400, max: 9) == ["correcao", "seguranca", "motor-concorrencia", "testes", "simplicidade"])
    }

    @Test func requestedWinsAndKeepsCorrecao() throws {
        #expect(try Self.names(["docs/a.md"], requested: ["simplicidade"]) == ["correcao", "simplicidade"])
        #expect(try Self.names(["Sources/CollieDaemonKit/Work/W.swift"], requested: ["testes", "correcao"]) == ["correcao", "testes"])
    }

    @Test func invalidRequestedIsRefused() throws {
        #expect(throws: PersonaError.unknown(name: "estilo")) { try Self.names(["docs/a.md"], requested: ["correcao", "estilo"]) }
    }

    @Test func orderIsStableWhateverTheInput() throws {
        let paths = ["Tests/X.swift", "scripts/a.sh", "Sources/CollieDaemonKit/Work/W.swift"]
        let first = try Self.names(paths, lines: 300, max: 9)
        #expect(try Self.names(paths.reversed(), lines: 300, max: 9) == first)
        #expect(try Self.names(paths, lines: 300, requested: ["simplicidade", "testes", "seguranca"], max: 9)
            == ["correcao", "seguranca", "testes", "simplicidade"])
    }

    @Test func globs() {
        #expect(PersonaRouter.matches(glob: "Sources/**", path: "Sources/A/B.swift"))
        #expect(PersonaRouter.matches(glob: "Sources/CollieDaemonKit/Daemon*", path: "Sources/CollieDaemonKit/DaemonServer.swift"))
        #expect(!PersonaRouter.matches(glob: "Sources/CollieDaemonKit/Daemon*", path: "Sources/CollieDaemonKit/Daemon/X.swift"))
        #expect(!PersonaRouter.matches(glob: "scripts/**", path: "docs/scripts/a.sh"))
        #expect(!PersonaRouter.matches(glob: "a.b", path: "axb"))
    }
}
