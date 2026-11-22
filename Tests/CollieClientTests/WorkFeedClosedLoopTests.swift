import Testing
import Foundation
import CollieCore
@testable import CollieClient

/// M7.3 (A4): a work closed while its loop runs leaves `work.status` at the close, and the history then has the row
/// rebuilt from the work (no summary). When the loop ends the daemon writes the summary and emits `work` for that id:
/// the feed reads the history again, so the row with the summary shows. An event of another paddock reads nothing.
@MainActor @Suite struct WorkFeedClosedLoopTests {
    typealias FakeDaemon = WorkFeedFollowTests.FakeDaemon
    let paddock = UUID()

    func feed(_ d: FakeDaemon) -> WorkFeed {
        let f = WorkFeed()
        f.call = { cmd, args, _ in try await d.call(cmd, args) }
        return f
    }

    @Test func theLoopEndingAfterTheCloseShowsTheSummaryRow() async {
        let d = FakeDaemon(), f = feed(d)
        var w = Work(title: "onda 7", terminalId: UUID(), paddockId: paddock)
        w.loop = WorkLoopState(state: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work?.id == w.id && d.historyCalls == 1)

        d.works = []; d.closed = [(w.id.uuidString, w.title)]   // closed under the running loop: the rebuilt row
        f.workChanged(paddock: paddock, work: w.id)
        await f.settled()
        #expect(d.historyCalls == 2 && f.history.count == 1 && f.history.first?.stopReason == nil)

        d.stopReasons[w.id.uuidString] = "allDone"   // the loop ended: the summary is written
        f.workChanged(paddock: paddock, work: w.id)
        await f.settled()
        #expect(d.historyCalls == 3)
        #expect(f.history.first?.stopReason == "allDone")   // the row with the summary, not the rebuilt one
    }

    @Test func anActiveWorkChangingDoesNotReadTheHistory() async {
        let d = FakeDaemon(), f = feed(d)
        var w = Work(title: "onda 7", terminalId: UUID(), paddockId: paddock)
        w.loop = WorkLoopState(state: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        await f.settled()
        for _ in 0..<3 { f.workChanged(paddock: paddock, work: w.id) }   // the loop's journal
        await f.settled()
        #expect(d.statusCalls >= 2 && d.historyCalls == 1)
    }

    @Test func anEventOfAnotherPaddockReadsNothing() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)
        f.workChanged(paddock: UUID(), work: UUID())
        await f.settled()
        #expect(d.statusCalls == 1 && d.historyCalls == 1)
    }
}
