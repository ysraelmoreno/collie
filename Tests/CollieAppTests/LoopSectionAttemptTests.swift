import Testing
import Foundation
import CollieCore
@testable import CollieApp

// M8.1: `WorkTask.tries` counts an attempt at its end, so a running row names the one under way (`tries + 1`, never past
// `max`); done and deferred rows the attempts used; an open row never tried, none ("0/3" is gone).

private let pad = UUID()

private func row(_ state: TaskState, tries: Int, current: Bool = false, max: Int = 3) -> LoopSection.TaskRow {
    var w = Work(title: "T", terminalId: UUID(), paddockId: pad, tasks: [WorkTask(id: "a", title: "A", state: state, tries: tries)])
    w.loop = WorkLoopState(state: .running, task: current ? "a" : nil, attempt: tries + 1, tries: max)
    return LoopSection.make(work: w, paddock: pad).rows[0]
}

@Suite(.appPT) struct LoopSectionAttemptTests {
    @Test func runningNamesTheAttemptUnderWay() {
        let r = row(.inProgress, tries: 1)
        #expect(r.triesText == "tentativa 2/3")
        #expect(r.accessibilityLabel == "A, rodando, tentativa 2/3")
        #expect(row(.open, tries: 1, current: true).triesText == "tentativa 2/3")   // the loop's current task, still open
    }

    @Test func runningNeverPassesMax() {
        #expect(row(.inProgress, tries: 3).triesText == "tentativa 3/3")
    }

    @Test func openNeverTriedShowsNoCount() {
        let r = row(.open, tries: 0)
        #expect(r.triesText == "" && !r.accessibilityLabel.contains("0/3"))
        #expect(r.accessibilityLabel == "A, aberta")
    }

    @Test func doneAndDeferredShowTheAttemptsUsed() {
        #expect(row(.done, tries: 2).triesText == "tentativa 2/3")
        #expect(row(.deferred, tries: 3).triesText == "tentativa 3/3")
        #expect(row(.done, tries: 1).accessibilityLabel == "A, feita, tentativa 1/3")
    }
}
