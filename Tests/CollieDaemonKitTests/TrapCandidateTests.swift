import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// F1: the same failure in 2+ attempts of a work becomes a candidate trap in the auto-land summary; never saved.
@Suite struct TrapCandidateTests {
    private static func note(_ task: String, _ n: Int, _ reason: String, _ tail: String = "") -> WorkNote {
        WorkNote(at: Date(), text: "[loop \(task)] Task \(task), tentativa \(n)/3: \(reason) (agente w-\(task)-t\(n))" + (tail.isEmpty ? "" : "\n" + tail))
    }

    private static func work(_ notes: [WorkNote]) -> Work {
        var w = Work(title: "W", terminalId: UUID(), branch: "main")
        w.tasks = [WorkTask(id: "a", title: "Task a"), WorkTask(id: "b", title: "Task b")]
        w.notes = notes
        return w
    }

    @Test func signatureNormalizesNumbersAndPaths() {
        let a = TrapCandidates.normalize("/Users/x/.collie/paddocks/p1/Sources/A.swift:12:5: error: oops in 3.2s")
        let b = TrapCandidates.normalize("/tmp/other/Sources/A.swift:99:1: error: oops in 10.7s")
        #expect(a == b)
        #expect(a == "<path> error: oops in #.#s")
    }

    @Test func twoEqualFailuresAreACandidate() {
        let w = Self.work([
            Self.note("a", 1, "check failed (exit 1)", "Building...\n/wt/a/X.swift:3:1: error: cannot find 'foo'"),
            Self.note("b", 1, "check failed (exit 2)", "/wt/b/X.swift:7:9: error: cannot find 'foo'"),
        ])
        let c = TrapCandidates.find(w)
        #expect(c == [.init(signature: "check: <path> error: cannot find 'foo'", count: 2, tasks: ["Task a", "Task b"])])
        let text = TrapCandidates.section(w).joined(separator: "\n")
        #expect(text.contains("## Armadilhas candidatas"))
        #expect(text.contains("2 vezes, tarefas: Task a; Task b"))
        #expect(text.contains("collie memory save --kind pitfall --subject 'trap-check-path-error-cannot-find-foo' --title 'check: <path> error: cannot find foo'"))
    }

    @Test func sameVetoTwiceIsACandidate() {
        let w = Self.work([
            Self.note("a", 1, "revisor recusou: [correcao] Sources/X.swift:42 falta teste"),
            Self.note("a", 2, "recusada duas vezes pela revisão: chame o dono; revisor recusou: [seg] Y.swift:1 a | [correcao] Sources/X.swift:9 outra"),
        ])
        #expect(TrapCandidates.find(w) == [.init(signature: "veto [correcao] Sources/X.swift", count: 2, tasks: ["Task a"])])
    }

    @Test func distinctFailuresAreNot() {
        let w = Self.work([
            Self.note("a", 1, "check failed (exit 1)", "error: one"),
            Self.note("a", 2, "gate failed (exit 1)", "error: one"),
            Self.note("b", 1, "check failed (exit 1)", "error: two"),
            Self.note("b", 2, "no new commit"),
            Self.note("b", 3, "no new commit"),
        ])
        #expect(TrapCandidates.find(w).isEmpty)
        #expect(TrapCandidates.section(w).isEmpty)
    }

    @Test func atMostFive() {
        let notes = (0..<7).flatMap { i in
            [Self.note("a", 1, "check failed (exit 1)", "error: kind \(String(UnicodeScalar(97 + i)!))"),
             Self.note("b", 1, "check failed (exit 1)", "error: kind \(String(UnicodeScalar(97 + i)!))")]
        }
        #expect(TrapCandidates.find(Self.work(notes)).count == 5)
        #expect(TrapCandidates.section(Self.work(notes)).filter { $0.hasPrefix("- ") }.count == 5)
    }

    @Test func scrubbed() {
        let w = Self.work([
            Self.note("a", 1, "gate failed (exit 1)", "error: auth password=hunter2 sk-abcdefghijkl"),
            Self.note("b", 1, "gate failed (exit 1)", "error: auth password=hunter2 sk-abcdefghijkl"),
        ])
        let text = TrapCandidates.section(w).joined(separator: "\n")
        #expect(!text.isEmpty && !text.contains("hunter2") && !text.contains("sk-abcdefghijkl"))
        #expect(text.contains("[hidden]"))
    }

    @Test func noRepeatNoSectionInTheSummary() {
        var w = Self.work([Self.note("a", 1, "check failed (exit 1)", "error: once")])
        w.loop = WorkLoopState(tries: 3, timeout: 60)
        w.loop?.autoLand = WorkLoopState.AutoLand(gate: "true")
        let once = AutoLandSummary.text(w, started: Date(), ended: Date(), stop: nil, base: nil, doctor: nil)
        #expect(!once.contains("Armadilhas candidatas"))
        w.notes.append(Self.note("b", 1, "check failed (exit 1)", "error: once"))
        let twice = AutoLandSummary.text(w, started: Date(), ended: Date(), stop: nil, base: nil, doctor: nil)
        #expect(twice.contains("## Armadilhas candidatas") && twice.contains("check: error: once: 2 vezes"))
    }
}
