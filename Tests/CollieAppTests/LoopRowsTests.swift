import Testing
import Foundation
import CollieCore
import CollieClient
@testable import CollieApp

private let pad = UUID()
private let term = UUID()

private func work(_ state: WorkLoopState.State? = .running, paddock: UUID? = pad, closed: Bool = false) -> Work {
    var w = Work(title: "T", terminalId: UUID(), paddockId: paddock, tasks: [
        WorkTask(id: "a", title: "Feita", state: .done, tries: 1), WorkTask(id: "b", title: "Rodando", state: .inProgress, tries: 1),
        WorkTask(id: "c", title: "Adiada", state: .deferred, tries: 3), WorkTask(id: "d", title: "Aberta")])
    if closed { w.closedAt = Date() }
    if let state { var l = WorkLoopState(state: state, task: "b", attempt: 2, tries: 3); l.show(.agent); w.loop = l }
    return w
}

@MainActor @Suite(.appPT) struct LoopRowsTests {
    @Test func rowsKeepTaskOrderWithStateAndTries() {
        let s = LoopSection.make(work: work(), paddock: pad)
        #expect(s.rows.map(\.title) == ["Feita", "Rodando", "Adiada", "Aberta"])
        #expect(s.rows.map(\.triesText) == ["tentativa 1/3", "tentativa 2/3", "tentativa 3/3", ""])
    }

    @Test func accessibilityLabelSaysTheStateInWords() {
        let s = LoopSection.make(work: work(), paddock: pad)
        #expect(s.rows.map(\.accessibilityLabel) == ["Feita, feita, tentativa 1/3", "Rodando, rodando, tentativa 2/3",
                                                     "Adiada, adiada, tentativa 3/3", "Aberta, aberta"])
    }

    @Test func clickOpensTheAttemptTerminalOnlyWhileItExists() {
        var w = work()
        w.jobs = [WorkJob(id: "x-t1", kind: .loop, label: "Rodando", terminal: UUID()), WorkJob(id: "x-t2", kind: .loop, label: "Rodando", terminal: term),
                  WorkJob(id: "o", kind: .shell, label: "Rodando", terminal: UUID())]
        #expect(LoopSection.agent(forTask: "b", in: w, alive: [term]) == term)    // the newest attempt
        #expect(LoopSection.agent(forTask: "b", in: w, alive: []) == nil)         // dismissed
        #expect(LoopSection.agent(forTask: "d", in: w, alive: [term]) == nil)     // no attempt yet
        #expect(LoopSection.agent(forTask: "zz", in: w, alive: [term]) == nil)
        #expect(LoopSection.agent(forTask: "b", in: nil, alive: [term]) == nil)
    }
}
