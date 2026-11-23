import Testing
import Foundation
import CollieCore

private typealias PE = FactoryProfile.ProfileError

/// Parses `factory` given as JSON text.
private func profile(_ json: String) -> Result<FactoryProfile, PE> {
    FactoryProfile.parse(try! JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
}
private func error(_ json: String) -> PE? {
    if case .failure(let e) = profile(json) { e } else { nil }
}
private func work(_ s: String) -> Result<(config: ProjectWorkConfig, warnings: [String]), ProjectWorkConfig.ConfigError> {
    ProjectWorkConfig.parse(Data(s.utf8))
}

private let full = """
{ "version": 1,
  "static":       { "architecture": ["scripts/ci/check-architecture.sh"], "ratchets": [{"name": "lint", "measure": "scripts/ci/lint.sh --count", "baseline": "scripts/lint-baseline.txt"}] },
  "verification": { "scenarios": [{"area": "ui", "command": "scripts/ui-check.sh"}] },
  "review":       { "personas": ["correcao", "seguranca"], "threshold": "blocker", "callOwner": true },
  "guardrails":   { "budgetSeconds": 2400, "maxTries": 3, "destructive": ["rm -rf"], "land": "factory-paddock" },
  "prose":        { "traps": ["07d5be97", "2e221b6c"] } }
"""

@Suite struct FactoryProfileTests {
    @Test func fullProfileIsReadWhole() throws {
        let p = try profile(full).get()
        #expect(p.version == 1)
        #expect(p.architecture == ["scripts/ci/check-architecture.sh"])
        #expect(p.ratchets == [.init(name: "lint", measure: "scripts/ci/lint.sh --count", baseline: "scripts/lint-baseline.txt")])
        #expect(p.scenarios == [.init(area: "ui", command: "scripts/ui-check.sh")])
        #expect(p.personas == ["correcao", "seguranca"])
        #expect(p.threshold == .blocker)
        #expect(p.callOwner)
        #expect(p.budgetSeconds == 2400 && p.maxTries == 3)
        #expect(p.destructive == ["rm -rf"])
        #expect(p.land == .factoryPaddock)
        #expect(p.traps == ["07d5be97", "2e221b6c"])
    }

    @Test func onlyVersionGivesDefaults() throws {
        let p = try profile(#"{"version": 1}"#).get()
        #expect(p == FactoryProfile())
        #expect(p.threshold == .major && p.land == .manual && !p.callOwner && p.budgetSeconds == nil && p.maxTries == nil)
    }

    @Test func versionRules() {
        #expect(error("{}") == .missingField("factory.version"))
        #expect(error(#"{"version": 2}"#) == .unsupportedVersion("2"))
        #expect(error(#"{"version": true}"#) == .wrongType(path: "factory.version", expected: "número"))
        #expect(error(#"[1]"#) == .wrongType(path: "factory", expected: "objeto"))
        #expect(error(#"{"version": 2}"#)?.message == "factory.version é 2; só a version 1 é aceita")
    }

    @Test func unknownFieldIsAnErrorAtEveryLevel() {
        #expect(error(#"{"version": 1, "extra": 1}"#) == .unknownField("factory.extra"))
        #expect(error(#"{"version": 1, "review": {"foo": 1}}"#) == .unknownField("factory.review.foo"))
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a", "measure": "m", "x": 1}]}}"#) == .unknownField("factory.static.ratchets[0].x"))
        #expect(error(#"{"version": 1, "review": {"foo": 1}}"#)?.message.contains("factory.review.foo") == true)
    }

    @Test func wrongType() {
        #expect(error(#"{"version": 1, "review": {"callOwner": "sim"}}"#) == .wrongType(path: "factory.review.callOwner", expected: "booleano"))
        #expect(error(#"{"version": 1, "review": {"callOwner": 1}}"#) == .wrongType(path: "factory.review.callOwner", expected: "booleano"))
        #expect(error(#"{"version": 1, "static": {"architecture": "x"}}"#) == .wrongType(path: "factory.static.architecture", expected: "lista"))
        #expect(error(#"{"version": 1, "guardrails": {"maxTries": 2.5}}"#) == .wrongType(path: "factory.guardrails.maxTries", expected: "número inteiro"))
        #expect(error(#"{"version": 1, "prose": 3}"#) == .wrongType(path: "factory.prose", expected: "objeto"))
        let m = error(#"{"version": 1, "review": {"callOwner": "sim"}}"#)?.message ?? ""
        #expect(m.contains("factory.review.callOwner") && m.contains("booleano"))
    }

    @Test func commandsFollowTheTopLevelRules() {
        #expect(error(#"{"version": 1, "static": {"architecture": ["a\nb"]}}"#) == .badCommand(.controlCharacter(key: "factory.static.architecture[0]")))
        #expect(error(#"{"version": 1, "verification": {"scenarios": [{"area": "ui", "command": " "}]}}"#) == .badCommand(.emptyCommand(key: "factory.verification.scenarios[0].command")))
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a", "measure": 3}]}}"#) == .badCommand(.wrongType(key: "factory.static.ratchets[0].measure", expected: "texto")))
        let long = String(repeating: "x", count: 1001)
        #expect(error(#"{"version": 1, "static": {"architecture": ["\#(long)"]}}"#) == .badCommand(.commandTooLong(key: "factory.static.architecture[0]", length: 1001)))
        #expect(error(#"{"version": 1, "static": {"architecture": ["a\nb"]}}"#)?.message.contains("factory.static.architecture[0]") == true)
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a"}]}}"#) == .missingField("factory.static.ratchets[0].measure"))
    }

    @Test func namesAndBaseline() {
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a", "measure": "m"}, {"name": "a", "measure": "n"}]}}"#) == .duplicate(path: "factory.static.ratchets[].name", value: "a"))
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "Lint", "measure": "m"}]}}"#) == .badName(path: "factory.static.ratchets[0].name", name: "Lint"))
        #expect(error(#"{"version": 1, "verification": {"scenarios": [{"area": "u i", "command": "c"}]}}"#) == .badName(path: "factory.verification.scenarios[0].area", name: "u i"))
        for bad in ["../x", "a/../b", "/etc/x", "", "a\\u0000b", String(repeating: "a", count: 201)] {
            #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a", "measure": "m", "baseline": "\#(bad)"}]}}"#) == .badBaseline(path: "factory.static.ratchets[0].baseline"), "\(bad)")
        }
        #expect(error(#"{"version": 1, "static": {"ratchets": [{"name": "a", "measure": "m", "baseline": "a..b/c.txt"}]}}"#) == nil)
        #expect(error(#"{"version": 1, "review": {"personas": ["a", "a"]}}"#) == .duplicate(path: "factory.review.personas", value: "a"))
        let many = (0...20).map { "\"p\($0)\"" }.joined(separator: ",")
        #expect(error(#"{"version": 1, "review": {"personas": [\#(many)]}}"#) == .tooMany(path: "factory.review.personas", count: 21, limit: 20))
    }

    @Test func choicesAndRanges() {
        #expect(error(#"{"version": 1, "review": {"threshold": "minor"}}"#) == .badChoice(path: "factory.review.threshold", value: "minor", allowed: ["blocker", "major"]))
        #expect(error(#"{"version": 1, "guardrails": {"land": "auto"}}"#) == .badChoice(path: "factory.guardrails.land", value: "auto", allowed: ["manual", "factory-paddock"]))
        #expect(error(#"{"version": 1, "guardrails": {"budgetSeconds": 59}}"#) == .outOfRange(path: "factory.guardrails.budgetSeconds", value: 59, range: 60...86400))
        #expect(error(#"{"version": 1, "guardrails": {"budgetSeconds": 86401}}"#) == .outOfRange(path: "factory.guardrails.budgetSeconds", value: 86401, range: 60...86400))
        #expect(error(#"{"version": 1, "guardrails": {"maxTries": 11}}"#) == .outOfRange(path: "factory.guardrails.maxTries", value: 11, range: 1...10))
        #expect(error(#"{"version": 1, "guardrails": {"budgetSeconds": 60, "maxTries": 10}}"#) == nil)
        #expect(error(#"{"version": 1, "guardrails": {"destructive": ["a\tb"]}}"#) == .badText(path: "factory.guardrails.destructive[0]"))
        #expect(error(#"{"version": 1, "review": {"threshold": "minor"}}"#)?.message == "'factory.review.threshold' é 'minor'; use 'blocker' ou 'major'")
    }

    @Test func traps() {
        #expect(error(#"{"version": 1, "prose": {"traps": ["07D5BE97"]}}"#) == .badTrap(path: "factory.prose.traps[0]", value: "07D5BE97"))
        #expect(error(#"{"version": 1, "prose": {"traps": ["07d5be9"]}}"#) == .badTrap(path: "factory.prose.traps[0]", value: "07d5be9"))
        #expect(error(#"{"version": 1, "prose": {"traps": ["07d5be97", "07d5be97"]}}"#) == .duplicate(path: "factory.prose.traps", value: "07d5be97"))
    }

    @Test func messagesAreOneLineAndDistinct() {
        let all: [PE] = [.unknownField("p"), .missingField("p"), .wrongType(path: "p", expected: "texto"), .unsupportedVersion("2"),
                         .badCommand(.emptyCommand(key: "p")), .badName(path: "p", name: "A"), .duplicate(path: "p", value: "a"),
                         .tooMany(path: "p", count: 3, limit: 2), .badBaseline(path: "p"), .badChoice(path: "p", value: "x", allowed: ["a"]),
                         .outOfRange(path: "p", value: 1, range: 2...3), .badText(path: "p"), .badTrap(path: "p", value: "x")]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(all.allSatisfy { !$0.message.isEmpty && !$0.message.contains("\n") })
    }

    // MARK: inside collie-work.json

    @Test func workConfigReadsFactory() throws {
        let ok = try work(#"{"version": 1, "gate": "g", "factory": \#(full)}"#).get()
        #expect(ok.warnings.isEmpty)
        #expect(ok.config.gate == "g")
        #expect(ok.config.factory == (try profile(full).get()))
    }

    @Test func workConfigWithoutFactoryIsUnchanged() throws {
        let ok = try work(#"{"version": 1, "gate": "g", "areas": {"ask": "a"}}"#).get()
        #expect(ok.config.factory == nil)
        #expect(ok.config == ProjectWorkConfig(gate: "g", areas: ["ask": "a"]))
        #expect(ok.warnings.isEmpty)
    }

    @Test func invalidFactoryFailsTheWholeFile() {
        guard case .failure(let e) = work(#"{"version": 1, "factory": {"version": 1, "review": {"foo": 1}}}"#) else { Issue.record("passed"); return }
        #expect(e == .invalidFactory(.unknownField("factory.review.foo")))
        #expect(e.message == PE.unknownField("factory.review.foo").message)
    }
}
