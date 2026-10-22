import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct WorkStatusTextTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let term = UUID()

    @Test func matchesShortQuestions() {
        #expect(StatusQuestion.match("Onde estamos?") == .whereAreWe)
        #expect(StatusQuestion.match("o que travou") == .whatIsStuck)
        #expect(StatusQuestion.match("O QUE ESTÁ RODANDO?") == .whatIsRunning)
    }

    @Test func longMessagesAreNotStatus() {
        #expect(StatusQuestion.match("onde estamos com o cache? troca o TTL para 5 min") == nil)
        #expect(StatusQuestion.match("rodar os testes") == nil)
    }

    @Test func instructionsAreNeverSwallowed() {
        for t in ["status code 500 no login", "rodando os testes de novo", "travou o build, arruma", "onde estamos com x? troca y"] {
            #expect(StatusQuestion.match(t) == nil, "\(t)")
        }
        #expect(StatusQuestion.match("status") == .whereAreWe)
        #expect(StatusQuestion.match("como estamos agora?") == .whereAreWe)
        #expect(StatusQuestion.match("o que esta rodando ai?") == .whatIsRunning)
        #expect(StatusQuestion.match("onde estamos?") == .whereAreWe)
    }

    @Test func badgeLinesAreDeterministic() {
        let a = UUID(), b = UUID(), c = UUID()
        let names = [a: "Beta", b: "Alfa", c: "Alfa"]
        let stuck = WorkStatusText.answer(.whatIsStuck, works: [], names: names, badges: [a: .attention, b: .attention, c: .attention], now: now)
        #expect(stuck == "- Alfa: esperando você\n- Alfa: esperando você\n- Beta: esperando você")
        let run = WorkStatusText.answer(.whatIsRunning, works: [], names: names, badges: [a: .working, b: .working], now: now)
        #expect(run == "- Alfa: trabalhando\n- Beta: trabalhando")
    }

    @Test func whereAreWeCountsStates() {
        func t(_ s: TaskState, _ i: Int) -> WorkTask { WorkTask(id: "\(s)\(i)", title: "tarefa \(s)\(i)", state: s, updatedAt: now) }
        let w = Work(title: "Cache", terminalId: term, tasks: [t(.done, 1), t(.done, 2), t(.done, 3), t(.inProgress, 1), t(.open, 1), t(.open, 2), t(.deferred, 1)])
        let s = WorkStatusText.answer(.whereAreWe, works: [w], names: [term: "Claude 1"], badges: [:], now: now)
        #expect(s.contains("3 feitas · 1 em andamento · 2 abertas · 1 para depois"))
        #expect(s.contains("tarefa inProgress1") && s.contains("**Cache**") && s.contains("térreo"))
    }

    @Test func stuckListsGoneUnknownAttention() {
        let other = UUID()
        let w = Work(title: "W", terminalId: term, jobs: [
            WorkJob(id: "a", kind: .shell, label: "build", state: .gone, startedAt: now),
            WorkJob(id: "b", kind: .subagent, label: "review", state: .unknown, startedAt: now.addingTimeInterval(-45 * 60))])
        let s = WorkStatusText.answer(.whatIsStuck, works: [w], names: [term: "A", other: "B"], badges: [other: .attention], now: now)
        #expect(s.split(separator: "\n").count == 3)
        #expect(s.contains("sumiu") && s.contains("sem sinal há 45 min") && s.contains("esperando você"))
    }

    @Test func emptyAnswers() {
        func a(_ q: StatusQuestion) -> String { WorkStatusText.answer(q, works: [], names: [:], badges: [:], now: now) }
        #expect(a(.whereAreWe) == "Nenhum trabalho ativo.")
        #expect(a(.whatIsStuck) == "Nada travado.")
        #expect(a(.whatIsRunning) == "Nada rodando agora.")
    }

    @Test func answerIsBounded() {
        let jobs = (0..<300).map { WorkJob(id: "\($0)", kind: .shell, label: "job número \($0)", startedAt: now) }
        let s = WorkStatusText.answer(.whatIsRunning, works: [Work(title: "W", terminalId: term, jobs: jobs)], names: [:], badges: [:], now: now)
        #expect(s.count <= 4_000)
        #expect(s.split(separator: "\n").last!.hasPrefix("… e mais"))
    }
}
