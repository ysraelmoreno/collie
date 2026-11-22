import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieClient

/// M6.2: the Trilho feed follows the paddock's work by the daemon's `work` event (never a timer, never a long wait that
/// ends): a work opened after the paddock, a second loop, a close, two works, a paddock switch, bursts.
/// M7.3: no clock. A wait is the feed's `settled()` or the daemon's `untilCalls(n)`, both continuations, so a slow
/// machine only makes the test slower, never a negative assert pass early.
@MainActor @Suite struct WorkFeedFollowTests {
    /// A daemon that answers `work.status` and `work.history` from what the test puts in it. `hold`: a `work.status`
    /// waits until `release()`.
    @MainActor final class FakeDaemon {
        var works: [Work] = []
        var closed: [(id: String, title: String)] = []
        /// The `stopReason` of a closed row (a summary written); absent: the row rebuilt from the work, without one.
        var stopReasons: [String: String] = [:]
        var fail = false
        var hold = false
        var statusCalls = 0, historyCalls = 0, inFlight = 0, maxInFlight = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        private var waiters: [(n: Int, c: CheckedContinuation<Void, Never>)] = []

        /// Returns once `work.status` was asked `n` times (the call held, if `hold`).
        func untilCalls(_ n: Int) async {
            guard statusCalls < n else { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
        func release() {
            hold = false
            let h = held; held = []; h.forEach { $0.resume() }
        }
        private func called() {
            let ready = waiters.filter { $0.n <= statusCalls }; waiters.removeAll { $0.n <= statusCalls }
            ready.forEach { $0.c.resume() }
        }

        func json(_ w: Work) -> JSONValue {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            return try! JSONDecoder().decode(JSONValue.self, from: e.encode(w))
        }
        func call(_ cmd: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            if fail { throw ProtocolError(code: .daemonUnavailable, message: "down") }
            switch cmd {
            case "work.status":
                statusCalls += 1; inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
                defer { inFlight -= 1 }
                called()
                if hold { await withCheckedContinuation { held.append($0) } }
                return .object(["works": .array(works.map(json))])
            case "work.history":
                historyCalls += 1
                return .array(closed.map { c in
                    var o: [String: JSONValue] = ["id": .string(c.id), "title": .string(c.title),
                                                  "closedAt": .string("2026-11-21T02:02:00Z"), "done": .number(1), "total": .number(1)]
                    if let s = stopReasons[c.id] { o["stopReason"] = .string(s) }
                    return .object(o)
                })
            default: throw ProtocolError(code: .internal, message: "unexpected \(cmd)")
            }
        }
    }

    let paddock = UUID()

    func feed(_ d: FakeDaemon) -> WorkFeed {
        let f = WorkFeed()
        f.call = { cmd, args, _ in try await d.call(cmd, args) }
        return f
    }
    func work(_ title: String, paddock: UUID? = nil, loop: WorkLoopState.State? = nil, opened: Date = Date()) -> Work {
        var w = Work(title: title, terminalId: UUID(), paddockId: paddock ?? self.paddock, openedAt: opened)
        if let loop { w.loop = WorkLoopState(state: loop) }
        return w
    }

    @Test func workStartedAfterOpeningThePaddockShows() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)
        #expect(f.work == nil)
        let w = work("onda 6", loop: .running); d.works = [w]
        f.workChanged(paddock: paddock)   // work start + work run
        await f.settled(); #expect(f.work?.id == w.id)
        #expect(f.work?.loop?.state == .running)
    }

    @Test func aSecondRunAfterAnEndedLoopShowsAgain() async {
        let d = FakeDaemon(), f = feed(d)
        var w = work("onda 6", loop: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work?.loop?.state == .running)
        w.loop?.state = .finished; d.works = [w]
        f.workChanged(paddock: paddock)
        await f.settled(); #expect(f.work?.loop?.state == .finished)
        w.loop?.state = .running; d.works = [w]
        f.workChanged(paddock: paddock)   // second work run
        await f.settled(); #expect(f.work?.loop?.state == .running)
    }

    @Test func historyReloadsWhenTheLoopEndsAndWhenTheWorkCloses() async {
        let d = FakeDaemon(), f = feed(d)
        var w = work("onda 6", loop: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work != nil && d.historyCalls == 1)
        w.loop?.state = .finished; d.works = [w]
        f.workChanged(paddock: paddock)
        await f.settled(); #expect(d.historyCalls == 2)   // the loop ended
        #expect(f.history.isEmpty)
        d.works = []; d.closed = [(w.id.uuidString, w.title)]
        f.workChanged(paddock: paddock)   // work done
        await f.settled(); #expect(f.history.count == 1)
        #expect(f.history.first?.title == "onda 6")
        #expect(f.work == nil)
    }

    @Test func picksTheWorkWhoseLoopRuns() async {
        let d = FakeDaemon(), f = feed(d)
        let idle = work("todo implícito"), runs = work("onda 6", loop: .running)
        d.works = [idle, runs]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work?.id == runs.id)
        let old = work("velho", loop: .finished, opened: Date(timeIntervalSince1970: 1)), new = work("novo", loop: .stopped)
        #expect(WorkFeed.pick([idle, old, new])?.id == new.id)   // none running: the newest with a loop
        #expect(WorkFeed.pick([idle])?.id == idle.id)
        #expect(WorkFeed.pick([]) == nil)
    }

    @Test func switchingPaddockClearsAndIgnoresTheOld() async {
        let d = FakeDaemon(), f = feed(d)
        let other = UUID()
        d.works = [work("aqui", loop: .running)]; d.closed = [("1", "fechado")]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work != nil && f.history.count == 1)
        d.hold = true
        f.workChanged(paddock: paddock)
        await d.untilCalls(2)   // a read of the old paddock in flight
        f.follow(paddock: other, name: "outro")
        #expect(f.work == nil && f.history.isEmpty)   // at once, before any read
        d.release()
        await f.settled(); #expect(d.inFlight == 0 && d.statusCalls == 3 && d.historyCalls == 2)
        #expect(f.work == nil)   // the old paddock's work never shows here
    }

    @Test func anEventOfAnotherPaddockIsIgnored() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)
        f.workChanged(paddock: UUID(), work: UUID())
        await f.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)   // a read started would be waited for
        f.workChanged(paddock: nil)   // a removed work: its paddock is unknown, read again
        await f.settled(); #expect(d.statusCalls == 2)
        let pasto = WorkFeed(); pasto.call = f.call
        pasto.follow(paddock: nil, name: nil); pasto.workChanged(paddock: nil)
        await pasto.settled(); await f.settled()
        #expect(d.statusCalls == 2)   // the Pasto shows no work: nothing read
    }

    @Test func aBurstIsOneReadInFlight() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)
        d.hold = true
        f.workChanged(paddock: paddock)
        await d.untilCalls(2)
        #expect(d.inFlight == 1)
        for _ in 0..<50 { f.workChanged(paddock: paddock) }
        let w = work("onda 6", loop: .running); d.works = [w]
        // released by a task queued on the main actor after the burst: a read the burst started (no coalescing) asks
        // first and is held too, so it shows in `maxInFlight`; a clock plays no part
        Task { @MainActor in d.release() }
        await d.untilCalls(3)
        await f.settled(); #expect(f.work?.id == w.id && d.inFlight == 0)
        #expect(d.maxInFlight == 1)
        #expect(d.statusCalls == 3)   // the first, the one held, one for the whole burst
    }

    @Test func aFailingDaemonLeavesItEmpty() async {
        let d = FakeDaemon(), f = feed(d)
        d.works = [work("onda 6", loop: .running)]; d.closed = [("1", "fechado")]
        f.follow(paddock: paddock, name: "collie")
        await f.settled(); #expect(f.work != nil && f.history.count == 1)
        d.fail = true
        f.workChanged(paddock: paddock)
        await f.settled(); #expect(f.work == nil && f.history.isEmpty)
    }

    @Test func theWorkEventRoundTripsAndReachesTheFeed() async throws {
        let id = UUID(), p = UUID()
        for e in [WorkspaceEvent.work(id, paddock: p), .work(id, paddock: nil)] {
            #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: JSONEncoder().encode(e)) == e)
        }
        let d = FakeDaemon()
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-feed-\(UUID())")))
        client.workFeed.call = { cmd, args, _ in try await d.call(cmd, args) }
        client.workFeed.follow(paddock: p, name: "collie")
        await client.workFeed.settled(); #expect(d.statusCalls == 1 && d.historyCalls == 1)
        client.apply(.work(id, paddock: p))
        await client.workFeed.settled(); #expect(d.statusCalls == 2)
        #expect(d.historyCalls == 2)   // M7.3: the event carries the work; not active here, so the history is read too
    }
}
