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
private let base = Date(timeIntervalSince1970: 1_763_690_520)   // 2025-11-21 02:02 UTC
private let utc = TimeZone(identifier: "UTC")!

/// `n` entries, newest first (entry 0 closed latest).
private func entries(_ n: Int) -> [HistoryEntry] {
    (0..<n).map { HistoryEntry(id: "h\($0)", title: "Trabalho \($0)", closedAt: base.addingTimeInterval(Double(-$0) * 3600), done: 4, total: 6, durationSeconds: 6840) }
}
private func loopWork() -> Work {
    var w = Work(title: "T", terminalId: UUID(), paddockId: pad, tasks: [WorkTask(id: "a", title: "A", state: .done)])
    var l = WorkLoopState(state: .running, task: "a", attempt: 1, tries: 3); l.show(.agent); w.loop = l
    return w
}

@MainActor @Suite(.appPT) struct HistorySectionTests {
    @Test func sectionOnlyWithAtLeastOneItem() {
        #expect(!HistorySection.make([]).visible)
        #expect(HistorySection.make(entries(1)).visible)
    }

    @Test func exactlyTwentyOfThirtyAndTheMoreLink() {
        let s = HistorySection.make(entries(30))
        #expect(s.rows.count == 20 && s.hasMore && s.title == "HISTÓRICO · 20")
        #expect(!HistorySection.make(entries(20)).hasMore)
        #expect(HistorySection.make(entries(3)).title == "HISTÓRICO · 3")
    }

    @Test func newestFirstAsGiven() {
        #expect(HistorySection.make(entries(30)).rows.map(\.id) == (0..<20).map { "h\($0)" })
    }

    @Test func twoLinesOfText() {
        let r = HistorySection.make(entries(1), timeZone: utc).rows[0]
        #expect(r.title == "Trabalho 0")
        #expect(r.detailText == "21/11 02:02 · 4/6 feitas · 1h54")
    }

    @Test func outcomeColourSaysHowItEnded() {
        func o(_ e: HistoryEntry) -> HistoryRow.Outcome { HistoryRow(e).outcome }
        #expect(o(HistoryEntry(id: "1", title: "", closedAt: base, done: 6, total: 6)) == .complete)
        #expect(o(HistoryEntry(id: "1", title: "", closedAt: base, done: 5, total: 6, deferred: 1)) == .withDeferred)
        #expect(o(HistoryEntry(id: "1", title: "", closedAt: base, stopReason: "requested", done: 2, total: 6)) == .stopped)
        #expect(o(HistoryEntry(id: "1", title: "", closedAt: base, stopReason: "requested", deferred: 1)) == .stopped)
    }

    @Test func switchingPaddockChangesTheList() async {
        let feed = WorkFeed()
        feed.call = { cmd, args, _ in
            guard cmd == "work.history" else { throw ProtocolError(code: .internal, message: "x") }
            var n = 0
            if case .string("A")? = args["paddock"] { n = 2 } else { n = 5 }
            return .array(entries(n).map { .object(["id": .string($0.id), "title": .string($0.title), "closedAt": .string("2025-11-21T02:02:00Z"),
                                                    "done": .number(4), "total": .number(6)]) })
        }
        func settle(_ count: Int) async { for _ in 0..<200 where feed.history.count != count { try? await Task.sleep(for: .milliseconds(10)) } }
        feed.follow(paddock: UUID(), name: "A"); await settle(2)
        #expect(HistorySection.make(feed.history).rows.count == 2)
        feed.follow(paddock: UUID(), name: "B"); await settle(5)
        #expect(HistorySection.make(feed.history).rows.count == 5)
        feed.follow(paddock: nil, name: nil)
        #expect(!HistorySection.make(feed.history).visible)
    }
}
