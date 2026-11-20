import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// M1.2: the loop's journal (`WorkLoopState.events`), a ring of 100 events that records and never decides.
@Suite struct LoopJournalTests {
    typealias Kind = LoopEvent.Kind

    @Test func aPassingAttemptLeavesItsEventsInOrder() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.map(\.kind) == [.attemptStarted, .agentSummoned, .turnEnded, .commitSeen, .agentDismissed, .checkStarted, .checkFinished, .verdict],
                "\(ev.map(\.kind.rawValue))")
        #expect(ev.allSatisfy { $0.task == "a" && $0.attempt == 1 })
        #expect(ev[1].detail == "w-task-a-t1" && ev[6].detail == "exit 0" && ev[7].detail == "passou")
        #expect(zip(ev, ev.dropFirst()).allSatisfy { $0.at <= $1.at })
    }

    @Test func aGateAddsItsTwoEvents() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], gate: "true"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.map(\.kind) == [.attemptStarted, .agentSummoned, .turnEnded, .commitSeen, .agentDismissed, .checkStarted, .checkFinished,
                                   .gateStarted, .gateFinished, .verdict], "\(ev.map(\.kind.rawValue))")
        #expect(ev[8].detail == "exit 0")
    }

    @Test func aFailedCheckLeavesTheReasonAndTheDiscard() async throws {
        let r = try await LoopRig([task("a", "exit 3")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get(), ev = w.loop?.events ?? []
        #expect(w.tasks[0].state == .deferred)
        #expect(ev.suffix(3).map(\.kind) == [.checkFinished, .verdict, .discarded], "\(ev.map(\.kind.rawValue))")
        #expect(ev.first { $0.kind == .checkFinished }?.detail == "exit 3")
        #expect(ev.first { $0.kind == .verdict }?.detail == "check failed (exit 3)")
        #expect(ev.last?.detail == "a-1.patch")
    }

    /// What the check leaves behind is put back, and the journal says so.
    @Test func aCheckThatEditsTheTreeLeavesATreeReset() async throws {
        let r = try await LoopRig([task("a", "echo junk > made.txt; test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.suffix(3).map(\.kind) == [.checkFinished, .treeReset, .verdict], "\(ev.map(\.kind.rawValue))")
    }

    @Test func turnEndedRecordsItsSource() async throws {
        for source in [AskResult.Source.hook, .idle] {
            let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
            await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }, source: source))
            #expect(await r.run() == .finished)
            let ev = try await r.get().loop?.events ?? []
            #expect(ev.first { $0.kind == .turnEnded }?.detail == source.rawValue)
        }
    }

    /// The agent's text (an ask that failed with it) reaches the journal clean.
    @Test func detailFromTheAgentIsCleanHiddenAndCut() async throws {
        let dirty = "\u{1B}[31mboom\u{1B}[0m\nline token=abc123secret " + String(repeating: "x", count: 500)
        let d = WorkLoop.eventDetail(dirty)
        #expect(!d.contains("\u{1B}") && !d.contains("\n") && !d.contains("abc123secret") && d.contains("[hidden]") && d.hasPrefix("boom line"))
        #expect(d.count <= 200 && WorkLoop.eventDetail(String(repeating: "y", count: 500)).count == 200)

        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(askError: ProtocolError(code: .invalidArgs, message: dirty)))
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        let details = ev.compactMap(\.detail)
        #expect(ev.contains { $0.kind == .turnEnded && $0.detail?.hasPrefix("erro: boom line") == true }, "\(details)")
        #expect(details.allSatisfy { !$0.contains("\u{1B}") && !$0.contains("abc123secret") && $0.count <= 200 }, "\(details)")
        #expect(!ev.contains { $0.kind == .checkStarted })   // the check never ran
    }

    @Test func theRingKeepsTheNewestHundred() {
        var l = WorkLoopState()
        #expect(l.events == nil)   // a new `work run` is a new state: an empty journal
        for i in 0..<130 { l.record(LoopEvent(at: Date(timeIntervalSince1970: Double(i)), kind: .attemptStarted, detail: "\(i)")) }
        #expect(l.events?.count == 100 && l.events?.first?.detail == "30" && l.events?.last?.detail == "129")
        #expect(LoopEvent(kind: .verdict, detail: String(repeating: "x", count: 500)).detail?.count == 200)
    }

    @Test func aStopIsRequestedThenRecorded() async throws {
        let r = try await LoopRig([task("a", "true"), task("b", "true")]); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.set("w-task-a-t1", LoopScript(act: { d in await loop.stop(work: id); try await commit("done.txt", "ok\n", in: d) }))
        #expect(await r.run() == .stopped)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.contains { $0.kind == .stopRequested && $0.task == nil })
        #expect(ev.last?.kind == .stopped && ev.last?.detail == "pedido pelo dono (work stop)")
        // one that was never running records nothing
        await loop.stop(work: id)
        #expect(try await r.get().loop?.events == ev)
    }

    @Test func anotherTerminalWorkingIsNamed() async throws {
        let r = try await LoopRig([task("a", "false")]); defer { r.cleanup() }
        await r.host.setBusy("dev")
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .stopped)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.contains { $0.kind == .othersWaiting && $0.detail == "dev" })
        #expect(!ev.contains { $0.kind == .discarded } && ev.last?.kind == .stopped)
    }

    /// The journal never reaches an agent: the second attempt's prompt carries the failure note, not the events.
    @Test func theJournalIsNotInThePrompt() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let prompt = await r.host.prompts["w-task-a-t2"] ?? ""
        #expect(prompt.contains("tentativa 1/3"))
        for k in Kind.allCases { #expect(!prompt.contains(k.rawValue), "\(k)") }
    }

    @Test func eventsFormatsTheLastLines() {
        let t0 = Date(timeIntervalSince1970: 1_000_000), utc = TimeZone(identifier: "UTC")!   // 13:46:40 UTC
        var l = WorkLoopState()
        #expect(WorkStatusText.events(l, last: 20, timeZone: utc).isEmpty)
        l.record(LoopEvent(at: t0, kind: .attemptStarted, task: "a", attempt: 1))
        l.record(LoopEvent(at: t0 + 1, kind: .turnEnded, task: "a", attempt: 1, detail: "hook"))
        l.record(LoopEvent(at: t0 + 2, kind: .stopped, detail: "pedido pelo dono (work stop)"))
        #expect(WorkStatusText.events(l, last: 20, timeZone: utc)
            == "13:46:40 attemptStarted Ta#1\n13:46:41 turnEnded Ta#1 hook\n13:46:42 stopped pedido pelo dono (work stop)")
        #expect(WorkStatusText.events(l, last: 2, timeZone: utc) == "13:46:41 turnEnded Ta#1 hook\n13:46:42 stopped pedido pelo dono (work stop)")
        #expect(WorkStatusText.events(l, last: 0, timeZone: utc).isEmpty)
    }

    /// `--events` alone is 20; with a number, that number.
    @Test func eventsFlagTakesAnOptionalNumber() throws {
        #expect(try ArgvParser.parse(["work", "status", "--events"]).args["events"] == .number(20))
        #expect(try ArgvParser.parse(["work", "status", "--events", "5"]).args["events"] == .number(5))
        let both = try ArgvParser.parse(["work", "status", "--events", "--all"]).args
        #expect(both["events"] == .number(20) && both["all"] == .bool(true))
        #expect(try ArgvParser.parse(["work", "status"]).args["events"] == nil)
    }

    /// A work written by the daemon before the journal still opens, and one from a newer daemon with a new kind too.
    @Test func decodesAWorkWithoutTheJournal() throws {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(state: .stopped, used: 2)
        let old = try JSONEncoder().encode(w)
        #expect(!String(decoding: old, as: UTF8.self).contains("events"))   // nil is not written: the old shape
        let back = try JSONDecoder().decode(Work.self, from: old)
        #expect(back.loop?.used == 2 && back.loop?.events == nil)
        w.loop?.record(LoopEvent(at: Date(timeIntervalSince1970: 5), kind: .verdict, task: "a", attempt: 1, detail: "passou"))
        #expect(try JSONDecoder().decode(Work.self, from: JSONEncoder().encode(w)) == w)
        #expect(try JSONDecoder().decode(LoopEvent.self, from: Data(#"{"at":0,"kind":"somethingNew"}"#.utf8)).kind == .unknown)
    }

    /// The sweep of a loop a previous daemon left running closes its journal too.
    @Test func theRestartSweepRecordsTheStop() {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        CommandRouter.sweepLeftRunning(&w, now: Date(timeIntervalSince1970: 9))
        #expect(w.loop?.events?.map(\.kind) == [.stopped] && w.loop?.events?.last?.detail == "o daemon reiniciou durante o laço")
    }
}
