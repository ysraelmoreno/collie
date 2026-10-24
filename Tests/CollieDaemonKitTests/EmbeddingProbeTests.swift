import Testing
import Foundation
import NaturalLanguage

/// Plan 2T Task 1 spike gates: the plugin layout `claude plugin validate` accepts (tokenless: no session, no prompt,
/// a fake HOME) and whether this Mac has the pt/en sentence-embedding assets. Missing ones skip, never fail.
private let claudePath: String? = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }

private func cosine(_ a: [Double], _ b: [Double]) -> Double {
    let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot(), nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return na == 0 || nb == 0 ? 0 : dot / (na * nb)
}

@Suite struct EmbeddingProbeTests {
    @Test(.enabled(if: claudePath != nil), .timeLimit(.minutes(1)))
    func pluginFixtureValidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("collie-procedures"), home = root.appendingPathComponent("home")
        let skill = plugin.appendingPathComponent("skills/rodar-testes")
        for d in [plugin.appendingPathComponent(".claude-plugin"), skill, home] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try #"{"name":"collie-procedures","version":"1.0.0","description":"Procedimentos aprendidos pelo Collie"}"#
            .write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try """
            ---
            name: rodar-testes
            description: Quando for rodar testes neste projeto.
            ---

            1. Rode só a suíte que mudou: `swift test --filter <Suíte>`.
            2. Nunca rode a suíte inteira.
            """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: try #require(claudePath))
        p.arguments = ["plugin", "validate", "--json", plugin.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]   // never the user's ~/.claude
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(String(decoding: data, as: UTF8.self))")
        #expect(json["success"] as? Bool == true)
        #expect((json["manifest"] as? [String: Any])?["errors"] as? [Any] == nil
                || ((json["manifest"] as? [String: Any])?["errors"] as? [Any])?.isEmpty == true)
        // `contents` lists only components with findings: a clean SKILL.md is absent
        let contents = json["contents"] as? [[String: Any]] ?? []
        #expect(contents.allSatisfy { ($0["errors"] as? [Any] ?? []).isEmpty && ($0["warnings"] as? [Any] ?? []).isEmpty }, "\(contents)")
    }

    @Test(.enabled(if: NLEmbedding.sentenceEmbedding(for: .portuguese) != nil))
    func portugueseSentenceEmbeddingProbe() throws {
        let e = try #require(NLEmbedding.sentenceEmbedding(for: .portuguese))
        #expect(e.dimension > 0)
        let a = try #require(e.vector(for: "rodar os testes")), b = try #require(e.vector(for: "executar a suíte de testes"))
        let c = try #require(e.vector(for: "cor do botão"))
        #expect(cosine(a, b) > cosine(a, c), "\(cosine(a, b)) vs \(cosine(a, c))")
    }

    @Test(.enabled(if: NLEmbedding.sentenceEmbedding(for: .english) != nil))
    func englishSentenceEmbeddingProbe() throws {
        let e = try #require(NLEmbedding.sentenceEmbedding(for: .english))
        #expect(e.dimension > 0)
        let a = try #require(e.vector(for: "run the tests")), b = try #require(e.vector(for: "execute the test suite"))
        let c = try #require(e.vector(for: "button color"))
        #expect(cosine(a, b) > cosine(a, c), "\(cosine(a, b)) vs \(cosine(a, c))")
    }
}
