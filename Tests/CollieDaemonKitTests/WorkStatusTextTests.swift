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
        #expect(s.contains("tarefa inProgress1") && s.contains("**Cache**") && s.contains("pasto"))
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

    @Test func loopLine() {
        var w = Work(title: "W", terminalId: term, tasks: [WorkTask(id: "a", title: "Build it", state: .inProgress)])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 2, tries: 3)
        #expect(WorkStatusText.recall(w).contains("em laço: Build it (tentativa 2/3)"), "\(WorkStatusText.recall(w))")
        w.loop?.phase = .check
        #expect(WorkStatusText.recall(w).contains("em laço: Build it (tentativa 2/3) · rodando o check"), "\(WorkStatusText.recall(w))")
        w.loop?.phase = .gate
        #expect(WorkStatusText.recall(w).contains("· rodando o portão"))
        w.loop?.state = .finished; w.loop?.task = nil
        #expect(WorkStatusText.recall(w).contains("laço terminou"))
        w.loop = nil
        #expect(!WorkStatusText.recall(w).contains("laço"))
    }

    /// M1.1: a stopped loop says why, in the status line and in the end notice; a finished one reads as before.
    @Test func stoppedLoopShowsItsReason() {
        var w = Work(title: "W", terminalId: term, tasks: [WorkTask(id: "a", title: "Build it")])
        w.loop = WorkLoopState(state: .stopped, used: 3)
        #expect(WorkStatusText.loopLine(w) == "laço parado (3 tentativas)")   // written before the field existed
        w.loop?.stopReason = .init(.maxReached)
        #expect(WorkStatusText.loopLine(w) == "laço parado (3 tentativas) · limite de tentativas (--max) atingido")
        #expect(WorkStatusText.recall(w).contains("· limite de tentativas (--max) atingido"))
        #expect(WorkStatusText.loopEnded(w).hasPrefix("[collie] Laço de \"W\" parou (limite de tentativas (--max) atingido): 0 feitas, 0 adiadas."))
        w.loop?.stopReason = .init(.othersWorking, detail: "dev")
        #expect(WorkStatusText.loopLine(w) == "laço parado (3 tentativas) · 'dev' trabalhando no cercado")
        w.loop = WorkLoopState(state: .finished, used: 3)
        #expect(WorkStatusText.loopLine(w) == "laço terminou (3 tentativas)")
        #expect(WorkStatusText.loopEnded(w).hasPrefix("[collie] Laço de \"W\" terminou: 0 feitas, 0 adiadas."))
    }

    /// M2.4: both notices end with where the state is read, once, and the task's stays on one line.
    @Test func noticesEndWithTheStateHint() {
        let hint = " · estado: collie work status"
        let e = TaskEvidence(commits: ["abc1234 feat: x"], shortstat: "1 file changed", checkTail: "ok", seconds: 9, attempt: 1)
        let done = WorkTask(id: "a", title: "Build\nit", state: .done, evidence: e)
        let late = WorkTask(id: "b", title: "Flaky", state: .deferred, reason: "loop: check failed\n(exit 1)")
        for t in [done, late, WorkTask(id: "c", title: "By hand", state: .done)] {
            let line = WorkStatusText.taskEnded(t)
            #expect(line.hasPrefix("[collie] Laço, tarefa terminada: ") && line.hasSuffix(hint), "\(line)")
            #expect(!line.contains("\n") && line.components(separatedBy: "collie work status").count == 2, "\(line)")
            #expect(!line.hasSuffix("?"))   // a notice is never read as a question
        }
        #expect(WorkStatusText.taskEnded(done) == "[collie] Laço, tarefa terminada: ✓ Build it · tentativa 1 · 1 commit · 1 file changed" + hint)
        var w = Work(title: "W", terminalId: term, tasks: [done, late])
        var stopped = WorkLoopState(state: .stopped, used: 3)
        stopped.stopReason = .init(.maxReached)
        for state in [WorkLoopState(state: .finished, tasks: ["a", "b"]), stopped] {
            w.loop = state
            let lines = WorkStatusText.loopEnded(w).components(separatedBy: "\n")
            #expect(lines[0].hasPrefix("[collie] Laço de \"W\" ") && lines[0].hasSuffix("1 feitas, 1 adiadas." + hint), "\(lines[0])")
            #expect(WorkStatusText.loopEnded(w).components(separatedBy: "collie work status").count == 2)   // once
            #expect(lines.count == 3 && !lines.contains { $0.hasSuffix("?") })
        }
    }

    /// M1.2: the journal shows only where it is asked for (`work status --events`): every status line reads as before.
    @Test func theJournalChangesNoStatusLine() {
        var w = Work(title: "W", terminalId: term, tasks: [WorkTask(id: "a", title: "Build it", state: .inProgress)])
        for state in [WorkLoopState.State.running, .stopped, .finished] {
            w.loop = WorkLoopState(state: state, task: "a", attempt: 2, tries: 3, used: 2, gate: "make lint")
            if state == .stopped { w.loop?.stopReason = .init(.maxReached) }
            let before = [WorkStatusText.loopLine(w), WorkStatusText.gateLine(w), WorkStatusText.statsLine(w), WorkStatusText.recall(w), WorkStatusText.loopEnded(w),
                          WorkStatusText.answer(.whereAreWe, works: [w], names: [:], badges: [:], now: now)]
            w.loop?.record(LoopEvent(at: now, kind: .verdict, task: "a", attempt: 2, detail: "check failed (exit 1)"))
            let after = [WorkStatusText.loopLine(w), WorkStatusText.gateLine(w), WorkStatusText.statsLine(w), WorkStatusText.recall(w), WorkStatusText.loopEnded(w),
                         WorkStatusText.answer(.whereAreWe, works: [w], names: [:], badges: [:], now: now)]
            #expect(before == after, "\(state)")
            #expect(!after.compactMap { $0 }.joined().contains("verdict"))
        }
        #expect(WorkStatusText.loopLine(w) == "laço terminou (2 tentativas)")
    }

    @Test func doneLineShowsTheEvidence() {
        var t = WorkTask(id: "a", title: "Build\nit", state: .done)
        #expect(WorkStatusText.doneLine(t) == nil)   // no evidence: the status line stays as it was
        t.evidence = TaskEvidence(commits: ["abc1234 feat: x", "abc1235 fix: y"], shortstat: "3 files changed, 10 insertions(+)",
                                  checkTail: "ok", seconds: 9, attempt: 2)
        #expect(WorkStatusText.doneLine(t) == "✓ Build it · tentativa 2 · 2 commits · 3 files changed, 10 insertions(+)")
        t.evidence = TaskEvidence(commits: ["abc1234 feat: x"], shortstat: "", checkTail: "", seconds: 1, attempt: 1)
        #expect(WorkStatusText.doneLine(t) == "✓ Build it · tentativa 1 · 1 commit")
        t.state = .open   // reopened: the evidence goes, and the line with it
        #expect(WorkStatusText.doneLine(t) == nil)
    }

    @Test func gateLine() {
        var w = Work(title: "W", terminalId: term)
        #expect(WorkStatusText.gateLine(w) == nil)
        w.loop = WorkLoopState(state: .running)
        #expect(WorkStatusText.gateLine(w) == nil)
        w.loop?.gate = "bash scripts/ci/lint.sh\n&& true"
        #expect(WorkStatusText.gateLine(w) == "portão: bash scripts/ci/lint.sh && true", "\(WorkStatusText.gateLine(w) ?? "")")
    }

    @Test func statsLine() {
        func t(_ id: String, _ s: TaskState, tries: Int?, seconds: Int? = nil) -> WorkTask {
            WorkTask(id: id, title: id, state: s, tries: tries,
                     evidence: seconds.map { TaskEvidence(commits: ["abc"], shortstat: "", checkTail: "", seconds: $0, attempt: tries ?? 1) })
        }
        var w = Work(title: "W", terminalId: term, tasks: [t("hand", .done, tries: nil), t("open", .open, tries: nil)])
        #expect(WorkStatusText.statsLine(w) == nil)   // no loop ran a task: nothing changes
        w.tasks += [t("a", .done, tries: 1, seconds: 3_600), t("b", .done, tries: 1, seconds: 3_600), t("c", .done, tries: 1, seconds: 500),
                    t("d", .done, tries: 1, seconds: 100), t("e", .done, tries: 2), t("f", .deferred, tries: 3)]
        #expect(WorkStatusText.statsLine(w) == "laço: 5/6 feitas · 4 na 1ª · 1 adiada · média 1,5 tentativas · 2h10", "\(WorkStatusText.statsLine(w) ?? "")")
        w.tasks = [t("a", .done, tries: 1, seconds: 725), t("b", .deferred, tries: 3), t("c", .deferred, tries: 3)]
        #expect(WorkStatusText.statsLine(w) == "laço: 1/3 feitas · 1 na 1ª · 2 adiadas · média 2,3 tentativas · 12min")
        w.tasks = [t("a", .done, tries: 1, seconds: 40)]
        #expect(WorkStatusText.statsLine(w) == "laço: 1/1 feitas · 1 na 1ª · 0 adiadas · média 1,0 tentativas · 40s")
        w.tasks = [t("a", .done, tries: 1, seconds: 3_900)]
        #expect(WorkStatusText.statsLine(w)?.hasSuffix("· 1h05") == true)
    }
}
