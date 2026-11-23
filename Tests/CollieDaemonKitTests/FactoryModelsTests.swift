import Testing
import Foundation
import CollieCore

/// U2: the stack models of `/collie:factory init` (docs/fabrica/modelos/<stack>/) are valid profiles and score as a working static layer.
private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let modelos = repo.appendingPathComponent("docs/fabrica/modelos")

private func text(_ u: URL) throws -> String { String(decoding: try Data(contentsOf: u), as: UTF8.self) }

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
            for f in ["profile.json", "ci.yml", "README.md", "scripts/check-feature.sh"] {
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
        #expect(FactoryDoctor.judge(s).score >= 2, "\(stack): \(FactoryDoctor.judge(s).evidence)")
    }
}
