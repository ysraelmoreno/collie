import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M6.4 (A4): a work closed while its loop runs keeps its whole journal until the loop ends; the summary written
/// then has the whole timeline (up to `WorkArchive.timelineMax`, `truncated` past it), and only after it does the
/// closed work's journal go back to the 20 newest. The loop only adds events, one write at a time, as here.
@Suite(.serialized) struct ArchiveRunningLoopTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-archive-run-\(UUID().uuidString.prefix(8))") }
    private func files(_ s: WorkStore) async -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: await s.summaries.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    private func event(_ i: Int) -> LoopEvent {
        LoopEvent(at: Date(timeIntervalSince1970: 1_000_000 + Double(i)), kind: .turnEnded, task: "t1", attempt: 1, detail: "e\(i)")
    }
    /// Events `range` recorded `per` to a write, as the loop's writes do.
    private func record(_ s: WorkStore, _ id: UUID, _ range: Range<Int>, per: Int = 10) async throws {
        for chunk in stride(from: range.lowerBound, to: range.upperBound, by: per) {
            try await s.update(id) { w in for i in chunk..<min(chunk + per, range.upperBound) { w.record(event(i)) } }
        }
    }
    private func endLoop(_ s: WorkStore, _ id: UUID) async throws {
        try await s.update(id) { $0.loop?.state = .stopped; $0.loop?.stopReason = .init(.requested) }
    }
    /// A work with a running loop and `before` events, then closed.
    private func closedUnderRunningLoop(_ s: WorkStore, before: Int) async throws -> UUID {
        let w = try await s.start(title: "L", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) { $0.loop = WorkLoopState(state: .running) }
        try await record(s, w.id, 0..<before)
        try await s.close(w.id, by: "app")
        return w.id
    }

    @Test func theSummaryHasEveryEventRecordedAfterTheCloseInOrder() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let id = try await closedUnderRunningLoop(s, before: 30)
        try await record(s, id, 30..<150)
        // closed, the loop still runs: no summary yet, and the journal is whole
        #expect(await files(s).isEmpty)
        #expect(try await s.get(id)?.loop?.events?.count == 150)
        try await endLoop(s, id)
        #expect(await files(s).count == 1)
        let a = try #require(try await s.history { _ in true }.first)
        #expect(a.timeline.map(\.detail) == (0..<150).map { "e\($0)" } && !a.truncated && a.stopReason == "requested")
        // the summary written, the closed work's journal is cut to the 20 newest
        #expect(try await s.get(id)?.loop?.events?.map(\.detail) == (130..<150).map { "e\($0)" })
    }

    @Test func pastTheTimelineLimitTheSummaryKeepsTheNewestBehindATruncatedEvent() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let id = try await closedUnderRunningLoop(s, before: 30)
        try await record(s, id, 30..<630, per: 50)
        try await endLoop(s, id)
        let a = try #require(try await s.history { _ in true }.first)
        #expect(a.truncated && a.timeline.count == WorkArchive.timelineMax)
        #expect(a.timeline[0].kind == "truncated" && a.timeline[0].detail.hasPrefix("131 "))
        #expect(a.timeline[1].detail == "e131" && a.timeline.last?.detail == "e629")
    }

    @Test func withoutARunningLoopTheJournalIsCutAsBefore() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "L", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) { $0.loop = WorkLoopState(state: .running) }
        // open: the ring of 100
        try await record(s, w.id, 0..<150)
        #expect(try await s.get(w.id)?.loop?.events?.count == WorkLoopState.eventsMax)
        // the loop ends, then the work closes: the summary has the ring, the closed work keeps 20
        try await endLoop(s, w.id)
        try await s.close(w.id, by: "app")
        let a = try #require(try await s.history { _ in true }.first)
        #expect(a.timeline.map(\.detail) == (50..<150).map { "e\($0)" })
        #expect(try await s.get(w.id)?.loop?.events?.count == WorkStore.maxClosedEvents)
        // a later write of the closed work (its loop not running) is cut again at once
        try await record(s, w.id, 150..<180)
        #expect(try await s.get(w.id)?.loop?.events?.map(\.detail) == (160..<180).map { "e\($0)" })
    }

    @Test func theSummaryDoesNotChangeAfterTheLoopEnds() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let id = try await closedUnderRunningLoop(s, before: 40)
        try await endLoop(s, id)
        let name = try #require(await files(s).first)
        let url = await s.summaries.appendingPathComponent(name)
        let bytes = try Data(contentsOf: url)
        try await record(s, id, 40..<80)
        try await s.update(id) { $0.notes.append(WorkNote(text: "depois")); $0.loop?.state = .finished }
        #expect(await files(s) == [name])
        #expect(try Data(contentsOf: url) == bytes)
    }
}
