import Testing
import Foundation
@testable import CollieDaemonKit

/// R5: personas parsed from their front-matter and routed by the diff's paths and size.
@Suite(.memoryPT) struct PersonaTests {
    static func file(_ name: String, paths: String = #"["*"]"#, model: String = "sonnet") -> String {
        "---\nname: \(name)\nmodel: \(model)\npaths: \(paths)\n---\n# \(name)\nlente de \(name)\n"
    }

    /// F2 X5: the repository's own personas (docs/fabrica/personas/*.md), read as they are: the routing tested is theirs.
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/fabrica/personas")
    static let files: [String: String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.filter { $0.hasSuffix(".md") }.compactMap { n in
            (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)).map { (n, $0) }
        })
    }()

    static func router() throws -> PersonaRouter { PersonaRouter(catalog: try PersonaCatalog.parse(files: files)) }

    static func names(_ paths: [String], lines: Int = 10, diff: String = "", requested: [String]? = nil,
                      max: Int = 4) throws -> [String] {
        try router().select(changedPaths: paths, diffLines: lines, diffText: diff, requested: requested, max: max).map(\.name)
    }

    @Test func validFrontMatterParses() throws {
        let p = try PersonaCatalog.parse(file: "testes.md", text: Self.file("testes", paths: #"["Tests/**", "Sources/**"]"#))
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
        let catalog = try PersonaCatalog.parse(files: Self.files)
        #expect(catalog.map(\.name) == ["correcao", "motor-concorrencia", "seguranca", "simplicidade", "testes"])
        #expect(catalog.allSatisfy { $0.body.contains("Contrato de saída") })
        // F2 X5: the line a finding points at is the new file's, never the patch's
        #expect(catalog.allSatisfy { $0.body.contains("a linha no ARQUIVO NOVO (depois da mudança), nunca o número de linha do patch") })
        // routed with the real catalog: each area calls the persona whose globs name it
        #expect(try Self.names([".github/workflows/ci.yml"]) == ["correcao", "seguranca"])
        #expect(try Self.names(["Helpers/x.swift"]) == ["correcao", "seguranca"])
        #expect(try Self.names(["Sources/CollieDaemonKit/Remote/R.swift"]) == ["correcao", "seguranca", "motor-concorrencia", "testes"])
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

    /// F2 X4: a persona or a spec of the work's tasks is what judges the next attempts: seguranca reviews the change.
    @Test func personasAndSpecsCallSeguranca() throws {
        #expect(try Self.names(["docs/fabrica/personas/correcao.md"]) == ["correcao", "seguranca"])
        let r = try Self.router()
        #expect(try r.select(changedPaths: ["docs/x/spec.md"], diffLines: 1, specs: ["docs/x/spec.md"]).map(\.name) == ["correcao", "seguranca"])
        #expect(try r.select(changedPaths: ["docs/x/other.md"], diffLines: 1, specs: ["docs/x/spec.md"]).map(\.name) == ["correcao"])
        let real = try PersonaCatalog.parse(file: "seguranca.md", text: Self.files["seguranca.md"] ?? "")
        #expect(PersonaRouter.matches(real.paths, any: ["docs/fabrica/personas/testes.md"]))
        #expect(PersonaRouter.matches(real.paths, any: ["docs/superpowers/specs/dl14/x4.md"]))
    }

    @Test func globs() {
        #expect(PersonaRouter.matches(glob: "Sources/**", path: "Sources/A/B.swift"))
        #expect(PersonaRouter.matches(glob: "Sources/CollieDaemonKit/Daemon*", path: "Sources/CollieDaemonKit/DaemonServer.swift"))
        #expect(!PersonaRouter.matches(glob: "Sources/CollieDaemonKit/Daemon*", path: "Sources/CollieDaemonKit/Daemon/X.swift"))
        #expect(!PersonaRouter.matches(glob: "scripts/**", path: "docs/scripts/a.sh"))
        #expect(!PersonaRouter.matches(glob: "a.b", path: "axb"))
    }
}
