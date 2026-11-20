import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private typealias M = AttemptMachine

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// A loop on `r`'s store and host whose effects answer with `events` (the interpreter's seam).
private func loop(_ r: LoopRig, _ events: @escaping @Sendable (M.Effect) -> M.Event?) -> WorkLoop {
    WorkLoop(store: r.store, host: r.host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50), events: events)
}

/// A work with a loop, as JSON the test can bend: `bend` edits the `loop` object.
private func work(loop: WorkLoopState, _ bend: (inout [String: Any]) -> Void) throws -> Work {
    var w = Work(title: "W", terminalId: UUID()); w.loop = loop
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any])
    var l = try #require(json["loop"] as? [String: Any])
    bend(&l); json["loop"] = l
    return try JSONDecoder().decode(Work.self, from: JSONSerialization.data(withJSONObject: json))
}

/// A stopped loop with a journal of three events.
private func stopped() -> WorkLoopState {
    var l = WorkLoopState(state: .stopped, task: "a", attempt: 2, used: 3, phase: .check, startedAt: Date(timeIntervalSinceReferenceDate: 10))
    l.stopReason = .init(.maxReached)
    for (i, k) in [LoopEvent.Kind.attemptStarted, .verdict, .stopped].enumerated() {
        l.record(LoopEvent(at: Date(timeIntervalSinceReferenceDate: Double(i)), kind: k, task: "a", attempt: 1))
    }
    return l
}

/// M1b.1: an event out of its phase never leaves a task stuck `inProgress`; a malformed newer subfield never erases
/// the work's whole `loop`.
@Suite struct LoopRobustnessTests {
    // MARK: the interpreter's safety net

    @Test func anEventOutOfItsPhaseReopensTheTaskAndStopsTheLoop() async throws {
        let r = try await LoopRig([task("a", "true"), task("b", "true")]); defer { r.cleanup() }
        // the summon answers with a gate's end: never a `summoning` event
        let l = loop(r) { $0 == .summon ? .gateDone(status: 0, broken: nil) : nil }
        #expect(await l.run(work: r.work, dir: r.repo) == .stopped)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.open, .open] && w.tasks[0].tries == nil)   // reopened, the attempt not counted on it
        #expect(w.jobs.map(\.id) == ["loop-a-1"] && w.jobs[0].state == .finished && w.jobs[0].result == "loop: estado inesperado do motor")
        #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.internal) && w.loop?.phase == nil && w.loop?.task == nil)
        // its own note (the pair), then the summary
        #expect(w.notes.contains { $0.text.hasPrefix("[loop] estado inesperado do motor (summoning × gateDone) em \"Task a\"") }, "\(w.notes.map(\.text))")
        #expect(w.notes.last?.text == "[loop] laço parado: estado inesperado do motor (bug); a tarefa foi reaberta")
        // the loop stopped: no next task, no terminal, no check
        #expect(await r.host.summoned.isEmpty)
        #expect(await r.host.checks == 0)
    }

    @Test func theNetDismissesATerminalStillOpen() async throws {
        let r = try await LoopRig([task("a", "true"), task("b", "true")]); defer { r.cleanup() }
        let l = loop(r) { $0 == .ask ? .started : nil }   // the turn answers with the attempt's start
        #expect(await l.run(work: r.work, dir: r.repo) == .stopped)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.open, .open])
        #expect(w.jobs.allSatisfy { $0.state == .finished } && w.loop?.stopReason?.code == .internal)
        #expect(await r.host.summoned == ["loop-a-1"])
        #expect(await r.host.dismissed == ["loop-a-1"])
    }

    @Test func theNormalPathDoesNotPassThroughTheNet() async throws {
        let r = try await LoopRig([task("a", "true"), task("b", "false")], tries: 1); defer { r.cleanup() }
        for n in ["loop-a-1", "loop-b-1"] { await r.host.set(n, LoopScript(act: { try await commit("\(UUID().uuidString.prefix(6)).txt", "x\n", in: $0) })) }
        let l = loop(r) { _ in nil }   // the seam answers nothing: every effect is carried out
        #expect(await l.run(work: r.work, dir: r.repo) == .finished)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .deferred] && w.loop?.stopReason == nil)
        #expect(!w.notes.contains { $0.text.contains("estado inesperado") }, "\(w.notes.map(\.text))")
        #expect(w.jobs.map(\.result) != ["loop: estado inesperado do motor"])
    }

    @Test func internalIsAStopCodeWithItsLabel() throws {
        typealias Stop = WorkLoopState.Stop
        #expect(Stop(.internal).label == "estado inesperado do motor (bug); a tarefa foi reaberta")
        #expect(try JSONDecoder().decode(Stop.self, from: JSONEncoder().encode(Stop(.internal))) == Stop(.internal))
        #expect(Stop.Code.internal.rawValue == "internal")
    }

    // MARK: reduce

    @Test func invalidPairsFaultAndChangeNothing() {
        let agent = UUID()
        let m = M.Event.measured(.init(committed: true, dirty: false, judged: "c1"))
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: true, before: "c0")
        var pairs: [(M.State, M.Event, String)] = []
        func add(_ strays: [M.Event]) { pairs += strays.map { (s, $0, String(describing: $0).prefix { $0 != "(" }.description) } }
        // summoning; `measured` with no failure before: nothing was ever asked to measure
        add([.turnTimedOut, .gateDone(status: 0, broken: nil), .decided(.pass), .commitSeen("c1"), .waitExpired, m, .gateClear])
        s = M.reduce(s, .started).0; s = M.reduce(s, .summoned(agent)).0
        #expect(s.phase == .turn)
        add([.started, .summoned(UUID()), .checkDone(status: 0, broken: nil), .settled(moved: false, reset: false), m])
        s = M.reduce(s, .turnEnded(source: .hook)).0
        #expect(s.phase == .waitingCommit && s.agent != nil)
        add([.started, .turnTimedOut, m, .measured(nil), .blocked(nil)])   // measured with the terminal still open
        s = M.reduce(s, .commitSeen("c1")).0
        add([.commitSeen("c2"), .waitExpired, .measured(nil)])   // the terminal is gone; nothing failed, so nil measures nothing
        s = M.reduce(s, m).0
        #expect(s.phase == .checking)
        add([.started, .gateDone(status: 0, broken: nil), .decided(.pass), .turnTimedOut, m])
        for (state, event, name) in pairs {
            let (next, fx) = M.reduce(state, event)
            #expect(next == state, "\(state.phase), \(event)")
            #expect(fx == [.fault("\(state.phase) × \(name)")], "\(state.phase), \(event): \(fx)")
            #expect(fx.allSatisfy { !$0.answers })
        }
    }

    @Test func aFinishedMachineStillTakesNoEventAndFaultsNothing() {
        let s = M.reduce(M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0"), .cancelled).0
        #expect(s.phase == .finished)
        for e: M.Event in [.started, .gateClear, .decided(.pass)] {
            let (next, fx) = M.reduce(s, e)
            #expect(next == s && fx.isEmpty, "\(e)")
        }
    }

    // MARK: tolerant decoding

    @Test func aMalformedNewerSubfieldDoesNotEraseTheLoop() throws {
        let l = stopped()
        var plain = l; plain.stopReason = nil
        #expect(try work(loop: l) { $0["stopReason"] = "maxReached" }.loop == plain)   // a string, not an object
        var noPhase = l; noPhase.phase = nil
        #expect(try work(loop: l) { $0["phase"] = "dreaming" }.loop == noPhase)
        #expect(try work(loop: l) { $0["phase"] = 3 }.loop == noPhase)
        var noEvents = l; noEvents.events = nil
        #expect(try work(loop: l) { $0["events"] = ["attemptStarted": 1] }.loop == noEvents)   // an object, not a list
        #expect(try work(loop: l) { $0["events"] = "none" }.loop == noEvents)
    }

    @Test func onlyTheMalformedEventIsDropped() throws {
        let l = stopped()
        func bent(_ i: Int, _ bend: @escaping (inout [String: Any]) -> Void) throws -> [LoopEvent.Kind]? {
            try work(loop: l) { loop in
                guard var es = loop["events"] as? [[String: Any]] else { return }
                bend(&es[i]); loop["events"] = es
            }.loop?.events?.map(\.kind)
        }
        #expect(try bent(1) { $0["at"] = nil } == [.attemptStarted, .stopped])          // no `at`
        #expect(try bent(0) { $0["attempt"] = "one" } == [.verdict, .stopped])          // `attempt` as a string
        #expect(try bent(2) { $0["kind"] = 7 } == [.attemptStarted, .verdict])
        #expect(try bent(1) { $0["kind"] = "fromANewerDaemon" } == [.attemptStarted, .unknown, .stopped])   // the reserve, kept
        // an element that is not even an object
        #expect(try work(loop: l) { $0["events"] = [1, "x"] }.loop?.events == [])
        // everything else of the loop is intact
        var one = l; one.events?.remove(at: 1)
        #expect(try work(loop: l) { loop in
            guard var es = loop["events"] as? [[String: Any]] else { return }
            es[1]["at"] = nil; loop["events"] = es
        }.loop == one)
    }

    @Test func aLoopOfThePreviousDaemonDecodesAsBefore() throws {
        // what a daemon without `phase`, `stopReason` and `events` wrote
        let old = #"{"state":"running","task":"a","attempt":1,"tries":3,"timeout":3600,"max":5,"used":2,"gate":"make lint","tasks":["a","b"],"startedAt":10}"#
        let l = try JSONDecoder().decode(WorkLoopState.self, from: Data(old.utf8))
        #expect(l == WorkLoopState(task: "a", attempt: 1, max: 5, used: 2, tasks: ["a", "b"], gate: "make lint", startedAt: Date(timeIntervalSinceReferenceDate: 10)))
        #expect(l.phase == nil && l.stopReason == nil && l.events == nil)
        // inside a work too
        #expect(try work(loop: l) { _ in }.loop == l)
    }

    @Test func theOlderFieldsStayRequiredAndStrict() throws {
        let l = stopped()
        for key in ["state", "attempt", "tries", "timeout", "used", "startedAt"] {
            #expect(try work(loop: l) { $0[key] = nil }.loop == nil, "\(key)")   // as before: no loop
        }
        #expect(try work(loop: l) { $0["tasks"] = "all" }.loop == nil)   // a wrong `tasks` never widens what was approved
        #expect(try work(loop: l) { $0["budget"] = "1h" }.loop == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkLoopState.self, from: Data(#"{"state":"running"}"#.utf8)) }
    }

    @Test func whatIsWrittenDoesNotChange() throws {
        let l = stopped()
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: data) == l)
        let keys = Set(try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        #expect(keys == ["state", "task", "attempt", "tries", "timeout", "used", "phase", "stopReason", "events", "startedAt"])
    }
}
