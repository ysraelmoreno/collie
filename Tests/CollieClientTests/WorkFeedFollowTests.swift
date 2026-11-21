import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieClient

/// M6.2: the Trilho feed follows the paddock's work by the daemon's `work` event (never a timer, never a long wait that
/// ends): a work opened after the paddock, a second loop, a close, two works, a paddock switch, bursts.
@MainActor @Suite struct WorkFeedFollowTests {
    /// A daemon that answers `work.status` and `work.history` from what the test puts in it.
    @MainActor final class FakeDaemon {
        var works: [Work] = []
        var closed: [(id: String, title: String)] = []
        var fail = false
        var hold = false
        var statusCalls = 0, historyCalls = 0, inFlight = 0, maxInFlight = 0

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
                while hold { try await Task.sleep(for: .milliseconds(5)) }
                return .object(["works": .array(works.map(json))])
            case "work.history":
                historyCalls += 1
                return .array(closed.map { .object(["id": .string($0.id), "title": .string($0.title),
                                                     "closedAt": .string("2026-11-21T02:02:00Z"), "done": .number(1), "total": .number(1)]) })
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
    /// Waits for `cond` (the feed reads on its own task); false if it never holds.
    func settle(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<300 { if cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return cond()
    }

    @Test func workStartedAfterOpeningThePaddockShows() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { d.statusCalls == 1 && d.historyCalls == 1 })
        #expect(f.work == nil)
        let w = work("onda 6", loop: .running); d.works = [w]
        f.workChanged(paddock: paddock)   // work start + work run
        #expect(await settle { f.work?.id == w.id })
        #expect(f.work?.loop?.state == .running)
    }

    @Test func aSecondRunAfterAnEndedLoopShowsAgain() async {
        let d = FakeDaemon(), f = feed(d)
        var w = work("onda 6", loop: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { f.work?.loop?.state == .running })
        w.loop?.state = .finished; d.works = [w]
        f.workChanged(paddock: paddock)
        #expect(await settle { f.work?.loop?.state == .finished })
        w.loop?.state = .running; d.works = [w]
        f.workChanged(paddock: paddock)   // second work run
        #expect(await settle { f.work?.loop?.state == .running })
    }

    @Test func historyReloadsWhenTheLoopEndsAndWhenTheWorkCloses() async {
        let d = FakeDaemon(), f = feed(d)
        var w = work("onda 6", loop: .running); d.works = [w]
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { f.work != nil && d.historyCalls == 1 })
        w.loop?.state = .finished; d.works = [w]
        f.workChanged(paddock: paddock)
        #expect(await settle { d.historyCalls == 2 })   // the loop ended
        #expect(f.history.isEmpty)
        d.works = []; d.closed = [(w.id.uuidString, w.title)]
        f.workChanged(paddock: paddock)   // work done
        #expect(await settle { f.history.count == 1 })
        #expect(f.history.first?.title == "onda 6")
        #expect(f.work == nil)
    }

    @Test func picksTheWorkWhoseLoopRuns() async {
        let d = FakeDaemon(), f = feed(d)
        let idle = work("todo implícito"), runs = work("onda 6", loop: .running)
        d.works = [idle, runs]
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { f.work?.id == runs.id })
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
        #expect(await settle { f.work != nil && f.history.count == 1 })
        d.hold = true
        f.follow(paddock: other, name: "outro")
        #expect(f.work == nil && f.history.isEmpty)   // at once, before any read
        d.hold = false
        #expect(await settle { d.inFlight == 0 && d.historyCalls >= 2 })
        #expect(f.work == nil)   // the old paddock's work never shows here
    }

    @Test func anEventOfAnotherPaddockIsIgnored() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { d.statusCalls == 1 && d.historyCalls == 1 })
        f.workChanged(paddock: UUID())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(d.statusCalls == 1)
        f.workChanged(paddock: nil)   // a removed work: its paddock is unknown, read again
        #expect(await settle { d.statusCalls == 2 })
        let pasto = WorkFeed(); pasto.call = f.call
        pasto.follow(paddock: nil, name: nil); pasto.workChanged(paddock: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(d.statusCalls == 2)   // the Pasto shows no work: nothing read
    }

    @Test func aBurstIsOneReadInFlight() async {
        let d = FakeDaemon(), f = feed(d)
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { d.statusCalls == 1 && d.historyCalls == 1 })
        d.hold = true
        f.workChanged(paddock: paddock)
        #expect(await settle { d.inFlight == 1 })
        for _ in 0..<50 { f.workChanged(paddock: paddock) }
        let w = work("onda 6", loop: .running); d.works = [w]
        d.hold = false
        #expect(await settle { f.work?.id == w.id && d.inFlight == 0 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(d.maxInFlight == 1)
        #expect(d.statusCalls == 3)   // the first, the one held, one for the whole burst
    }

    @Test func aFailingDaemonLeavesItEmpty() async {
        let d = FakeDaemon(), f = feed(d)
        d.works = [work("onda 6", loop: .running)]; d.closed = [("1", "fechado")]
        f.follow(paddock: paddock, name: "collie")
        #expect(await settle { f.work != nil && f.history.count == 1 })
        d.fail = true
        f.workChanged(paddock: paddock)
        #expect(await settle { f.work == nil && f.history.isEmpty })
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
        #expect(await settle { d.statusCalls == 1 && d.historyCalls == 1 })
        client.apply(.work(id, paddock: p))
        #expect(await settle { d.statusCalls == 2 })
    }
}
