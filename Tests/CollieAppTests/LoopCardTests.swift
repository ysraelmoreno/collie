import Testing
import Foundation
import SwiftUI
import CollieCanvas
import ColliePlugins
import CollieCore
import CollieClient
import CollieProtocol
@testable import CollieApp

private let pad = UUID()

/// 5 tasks taken: 3 done, one running on its 2nd attempt (1 finished), one open.
private func work(phase: WorkLoopState.Phase? = .check, tasks: [WorkTask]? = nil, state: WorkLoopState.State = .running) -> Work {
    var w = Work(title: "Roadmap · onda 6", terminalId: UUID(), paddockId: pad, tasks: tasks ?? [
        WorkTask(id: "a", title: "A", state: .done, tries: 1), WorkTask(id: "b", title: "B", state: .done, tries: 1),
        WorkTask(id: "c", title: "C", state: .done, tries: 2), WorkTask(id: "d", title: "D", state: .inProgress, tries: 1),
        WorkTask(id: "e", title: "E")])
    var l = WorkLoopState(state: state, task: "d", attempt: 2, tries: 3)
    if let phase { l.show(phase) }
    w.loop = l
    return w
}

@MainActor @Suite(.appPT) struct LoopCardTests {
    @Test func titleCountAndBar() throws {
        let c = try #require(LoopCard.make(work: work(), paddock: pad))
        #expect(c.title == "Roadmap · onda 6")
        #expect(c.progressText == "3/5")
        #expect(c.fraction == 0.6)
        #expect(c.attempt == 2)
    }

    @Test func noTasksIsAnEmptyBarNotADivisionByZero() throws {
        let c = try #require(LoopCard.make(work: work(tasks: []), paddock: pad))
        #expect(c.progressText == "0/0" && c.fraction == 0)
        #expect(c.attempt == nil && c.statusText == "check rodando")
    }

    @Test func phaseLineInEveryPhase() {
        func line(_ p: WorkLoopState.Phase?) -> String? { LoopCard.make(work: work(phase: p), paddock: pad)?.statusText }
        #expect(line(.agent) == "tentativa 2 · agente trabalhando")
        #expect(line(.check) == "tentativa 2 · check rodando")
        #expect(line(.gate) == "tentativa 2 · portão rodando")
        #expect(line(nil) == "tentativa 2 · preparando")
    }

    @Test func accessibilityLabelReadsTheCard() {
        #expect(LoopCard.make(work: work(), paddock: pad)?.accessibilityLabel
                == "laço Roadmap · onda 6, 3 de 5 feitas, tentativa 2, check rodando")
    }

    @Test func noCardWithoutARunningLoopHere() {
        #expect(LoopCard.make(work: nil, paddock: pad) == nil)
        #expect(LoopCard.make(work: work(state: .finished), paddock: pad) == nil)
        #expect(LoopCard.make(work: work(), paddock: UUID()) == nil)
    }
}
