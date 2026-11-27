import Testing
import Foundation
import CollieCore
import CollieClient
@testable import CollieApp

private let pad = UUID()
private let owner = UUID()

private func term(_ id: UUID, _ name: String) -> TerminalRecord {
    TerminalRecord(id: id, name: name, preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)
}

/// 5 tasks: 2 done, one running on its 2nd attempt, one deferred, one open; the loop on check.
private func work(state: WorkLoopState.State = .running) -> Work {
    var w = Work(title: "Laço idiomas", terminalId: owner, paddockId: pad, tasks: [
        WorkTask(id: "a", title: "A", state: .done, tries: 1), WorkTask(id: "b", title: "B", state: .done, tries: 1),
        WorkTask(id: "c", title: "C", state: .inProgress, tries: 1), WorkTask(id: "d", title: "D", state: .deferred, tries: 3),
        WorkTask(id: "e", title: "E")])
    var l = WorkLoopState(state: state, task: "c", attempt: 2, tries: 3)
    l.show(.check)
    w.loop = l
    return w
}

@MainActor @Suite(.appPT) struct LoopFloatTests {
    @Test func oneItemPerRunningLoopAnchoredToItsOwner() throws {
        let items = LoopFloat.make(work: work(), terminals: [term(UUID(), "outro"), term(owner, "pastor")])
        let i = try #require(items.first)
        #expect(items.count == 1)
        #expect(i.anchor == owner && i.owner == "pastor")
        #expect(i.title == "Laço idiomas")
    }

    @Test func countCurrentTaskAndAttempt() throws {
        let i = try #require(LoopFloat.make(work: work(), terminals: [term(owner, "pastor")]).first)
        #expect(i.progressText == "2/5")
        #expect(i.current == "C" && i.currentId == "c")
        #expect(i.attemptText == "tentativa 2 de 3")
        #expect(i.pillText == "laço 2/5 · check rodando")
    }

    @Test func marksByTaskState() throws {
        let i = try #require(LoopFloat.make(work: work(), terminals: []).first)
        #expect(i.tasks.map(\.mark) == ["✔", "✔", "●", "–", "◌"])
    }

    @Test func noVisibleOwnerHasNoAnchor() throws {
        let i = try #require(LoopFloat.make(work: work(), terminals: [term(UUID(), "outro")]).first)
        #expect(i.anchor == nil && i.owner == nil)
        #expect(LoopFloat.side(node: nil, viewport: CGSize(width: 800, height: 600)) == .none)
        #expect(LoopFloat.frame(node: nil, side: .none, size: CGSize(width: 150, height: 30), viewport: CGSize(width: 800, height: 600))
                == CGRect(x: 12, y: 558, width: 150, height: 30))
    }

    @Test func finishedOrNoLoopIsGone() {
        #expect(LoopFloat.make(work: work(state: .finished), terminals: [term(owner, "pastor")]).isEmpty)
        #expect(LoopFloat.make(work: nil, terminals: []).isEmpty)
    }

    @Test func rightOfTheNodeLeftWhenItDoesNotFit() {
        let vp = CGSize(width: 1000, height: 600)
        let left = CGRect(x: 40, y: 40, width: 400, height: 300), right = CGRect(x: 600, y: 40, width: 380, height: 300)
        #expect(LoopFloat.side(node: left, viewport: vp) == .right)
        #expect(LoopFloat.side(node: right, viewport: vp) == .left)
        let s = CGSize(width: LoopFloat.width + LoopFloat.gap, height: 200)
        #expect(LoopFloat.frame(node: left, side: .right, size: s, viewport: vp).origin == CGPoint(x: 440, y: 40))
        #expect(LoopFloat.frame(node: right, side: .left, size: s, viewport: vp).maxX == 600)
    }
}
