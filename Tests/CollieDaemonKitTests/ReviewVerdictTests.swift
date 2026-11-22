import Testing
import Foundation
@testable import CollieDaemonKit

/// R2: a reviewer's answer read fail closed, the personas aggregated, and the fixed review prompt.
struct ReviewVerdictTests {
    static let approve = #"{"persona":"correcao","verdict":"approve","findings":[]}"#
    static let reject = #"{"persona":"seguranca","verdict":"reject","findings":[{"severity":"blocker","file":"src/X.swift","line":12,"claim":"token vaza no log","fix":"redigir o token"},{"severity":"nit","file":"src/Y.swift","line":3,"claim":"nome ruim","fix":"renomear"}]}"#

    @Test func approved() {
        let v = ReviewVerdict.parse(Self.approve, persona: "correcao")
        #expect(v == PersonaVerdict(persona: "correcao", approved: true, findings: [], invalid: nil))
    }

    @Test func rejectedWithFindings() {
        let v = ReviewVerdict.parse(Self.reject, persona: "seguranca")
        #expect(!v.approved)
        #expect(v.invalid == nil)
        #expect(v.findings.count == 2)
        #expect(v.findings[0] == ReviewFinding(severity: .blocker, file: "src/X.swift", line: 12,
                                               claim: "token vaza no log", fix: "redigir o token"))
    }

    @Test func noiseBeforeAndAfter() {
        let text = "⏺ lendo o diff {sem json aqui\n> \(Self.approve)\n\n  ? for shortcuts  } esc to interrupt"
        let v = ReviewVerdict.parse(text, persona: "correcao")
        #expect(v.approved && v.invalid == nil)
    }

    @Test func multilineJSON() {
        let text = "resultado:\n{\n  \"persona\": \"correcao\",\n  \"verdict\": \"approve\",\n  \"findings\": []\n}\n"
        #expect(ReviewVerdict.parse(text, persona: "correcao").approved)
    }

    @Test func twoJSONsLastWins() {
        let first = #"{"persona":"correcao","verdict":"reject","findings":[{"severity":"major","claim":"x"}]}"#
        let v = ReviewVerdict.parse(first + "\nrevendo...\n" + Self.approve, persona: "correcao")
        #expect(v.approved)
        let v2 = ReviewVerdict.parse(Self.approve + "\n" + first, persona: "correcao")
        #expect(!v2.approved && v2.invalid == nil)
    }

    @Test func truncated() {
        let cut = String(Self.approve.dropLast(5))
        let v = ReviewVerdict.parse(cut, persona: "correcao")
        #expect(!v.approved)
        #expect(v.invalid?.hasPrefix("resposta do revisor inválida:") == true)
        // An earlier complete answer does not pass when a later one was cut.
        let later = Self.approve + "\n" + #"{"persona":"correcao","verdict":"rej"#
        #expect(!ReviewVerdict.parse(later, persona: "correcao").approved)
        let laterNoVerdictKey = Self.approve + "\n" + #"{"persona":"correcao","verd"#
        #expect(!ReviewVerdict.parse(laterNoVerdictKey, persona: "correcao").approved)
    }

    @Test func noJSON() {
        let v = ReviewVerdict.parse("parece bom, aprovado!", persona: "correcao")
        #expect(!v.approved && v.invalid?.contains("resposta do revisor inválida") == true)
    }

    @Test func wrongTypes() {
        let cases = [
            #"{"persona":"correcao","verdict":"approve","findings":[{"severity":"minor","line":"12","claim":"x"}]}"#,
            #"{"persona":"correcao","verdict":"approve","findings":"nenhum"}"#,
            #"{"persona":"correcao","verdict":true,"findings":[]}"#,
            #"{"persona":"correcao","verdict":"approve"}"#,
            #"{"persona":"correcao","verdict":"maybe","findings":[]}"#,
            #"{"persona":"correcao","verdict":"approve","findings":[{"severity":"critical","claim":"x"}]}"#,
        ]
        for text in cases {
            let v = ReviewVerdict.parse(text, persona: "correcao")
            #expect(!v.approved, "\(text)")
            #expect(v.invalid?.hasPrefix("resposta do revisor inválida:") == true, "\(text)")
        }
    }

    @Test func wrongPersona() {
        let v = ReviewVerdict.parse(Self.approve, persona: "seguranca")
        #expect(!v.approved)
        #expect(v.invalid?.contains("persona 'correcao'") == true)
    }

    @Test func incoherentApprove() {
        let text = #"{"persona":"testes","verdict":"approve","findings":[{"severity":"major","file":"a.swift","line":1,"claim":"teste não falha","fix":"assert"}]}"#
        let v = ReviewVerdict.parse(text, persona: "testes")
        #expect(!v.approved)
        #expect(v.invalid?.contains("incoerente") == true)
        #expect(ReviewVerdict.aggregate([v]).reason?.contains("a.swift:1 teste não falha") == true)
    }

    @Test func limits() {
        let finding = #"{"severity":"nit","claim":"x"}"#
        let twenty = #"{"persona":"p","verdict":"approve","findings":["# + Array(repeating: finding, count: 20).joined(separator: ",") + "]}"
        #expect(ReviewVerdict.parse(twenty, persona: "p").approved)
        let many = #"{"persona":"p","verdict":"approve","findings":["# + Array(repeating: finding, count: 21).joined(separator: ",") + "]}"
        #expect(!ReviewVerdict.parse(many, persona: "p").approved)
        let ok = #"{"persona":"p","verdict":"approve","findings":[{"severity":"nit","claim":""# + String(repeating: "a", count: 400) + #""}]}"#
        #expect(ReviewVerdict.parse(ok, persona: "p").approved)
        let long = #"{"persona":"p","verdict":"approve","findings":[{"severity":"nit","claim":""# + String(repeating: "a", count: 401) + #""}]}"#
        #expect(!ReviewVerdict.parse(long, persona: "p").approved)
    }

    @Test func aggregateOneRefusalDrops() {
        let ok = ReviewVerdict.parse(Self.approve, persona: "correcao")
        let no = ReviewVerdict.parse(Self.reject, persona: "seguranca")
        let outcome = ReviewVerdict.aggregate([ok, no])
        #expect(!outcome.approved)
        #expect(outcome.reason?.hasPrefix("revisor recusou: [seguranca] src/X.swift:12 token vaza no log") == true)
        #expect(outcome.reason?.contains("nome ruim") == false)
    }

    @Test func aggregateMinorsBecomeNotes() {
        let text = #"{"persona":"simplicidade","verdict":"approve","findings":[{"severity":"minor","file":"a.swift","line":4,"claim":"helper duplicado","fix":"reusar"},{"severity":"nit","claim":"vírgula"}]}"#
        let outcome = ReviewVerdict.aggregate([ReviewVerdict.parse(Self.approve, persona: "correcao"),
                                              ReviewVerdict.parse(text, persona: "simplicidade")])
        #expect(outcome.approved && outcome.reason == nil)
        #expect(outcome.notes == ["[simplicidade] a.swift:4 helper duplicado (fix: reusar)", "[simplicidade] vírgula"])
    }

    @Test func aggregateAllApprove() {
        let outcome = ReviewVerdict.aggregate([ReviewVerdict.parse(Self.approve, persona: "correcao")])
        #expect(outcome == ReviewOutcome(approved: true, reason: nil, notes: []))
        #expect(!ReviewVerdict.aggregate([]).approved)
        let invalid = ReviewVerdict.aggregate([ReviewVerdict.parse("lixo", persona: "testes")])
        #expect(invalid.reason?.contains("[testes] resposta do revisor inválida") == true)
    }

    static let persona = Persona(name: "seguranca", model: "sonnet", paths: ["**"], body: "# Persona: Segurança\nlente de segurança")

    @Test func promptHasPersonaSpecDiffCheckButNotAgent() {
        let agentWords = "confie em mim, está tudo certo"
        let prompt = ReviewPrompt.build(persona: Self.persona, spec: "SPEC: fazer X", diff: "+let x = 1",
                                        evidence: "12 testes passaram", check: "scripts/check-factory-loop.sh r2")
        for part in ["lente de segurança", "SPEC: fazer X", "+let x = 1", "12 testes passaram",
                     "scripts/check-factory-loop.sh r2", "JULGA", #""persona":"seguranca""#] {
            #expect(prompt.contains(part), "\(part)")
        }
        #expect(!prompt.contains(agentWords))
        #expect(!prompt.contains("diff truncado"))
    }

    @Test func hugeDiffTruncatedWithWarning() {
        let diff = String(repeating: "+ã linha\n", count: 10_000)
        let prompt = ReviewPrompt.build(persona: Self.persona, spec: "s", diff: diff, evidence: "", check: "c",
                                        maxDiffBytes: 1_001)
        #expect(prompt.contains("diff truncado"))
        #expect(prompt.utf8.count < 4_000)
        #expect(ReviewPrompt.truncated(diff, maxBytes: 1_001).hasPrefix(String(diff.prefix(50))))
    }
}
