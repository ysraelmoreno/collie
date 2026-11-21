import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M5.1: `--notify end` is the default for a new loop, and what the loop still sends to its Shepherd inside 60 s goes
/// as one line with the counts (a fake clock: `LoopFakeHost.advance`, `LoopNotices.offer(at:)`; no sleep, no timer).
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

@Suite(.timeLimit(.minutes(3))) struct LoopNoticePolicyTests {
    @Test func aNewLoopWithoutTheFlagIsEndAndTaskStaysAsAsked() throws {
        #expect(try CommandRouter.loopNotify(nil) == .end)
        #expect(try CommandRouter.loopNotify("task") == .task)
        #expect(try CommandRouter.loopNotify("end") == .end)
        for bad in ["", "tasks", "END"] {
            #expect(throws: ProtocolError.self) { try CommandRouter.loopNotify(bad) }
        }
        let spec = try #require(Commands.spec("work.run")?.params.first { $0.name == "notify" })
        #expect(spec.help.contains("default end"), "\(spec.help)")
    }

    @Test func aNewLoopDoesNotNoticeADoneTask() {
        var w = Work(title: "W", terminalId: UUID())
        var done = task("a", "true"); done.state = .done
        w.tasks = [done]
        w.loop = WorkLoopState(tasks: ["a"], notify: try? CommandRouter.loopNotify(nil))
        #expect(WorkLoop.endNotice(w, "a") == nil)
        w.loop?.notify = .task
        #expect(WorkLoop.endNotice(w, "a")?.contains("✓ Task a") == true)
    }

    @Test func deferredStopAndEndAlwaysNotice() {
        var w = Work(title: "W", terminalId: UUID())
        var deferred = task("b", "false"); deferred.state = .deferred; deferred.reason = "loop: falhou"
        w.tasks = [deferred]
        for notify in [WorkLoopState.Notify.end, .task] {
            w.loop = WorkLoopState(state: .stopped, tasks: ["b"], notify: notify)
            #expect(WorkLoop.endNotice(w, "b")?.contains("adiada: loop: falhou") == true)
            w.loop?.stopReason = .init(.requested)
            #expect(WorkStatusText.loopEnded(w).contains("parou ("), "\(notify)")
            w.loop?.stopReason = nil; w.loop?.state = .finished
            #expect(WorkStatusText.loopEnded(w).contains("terminou: 0 feitas, 1 adiadas"))
        }
    }

    @Test func noticesInsideTheWindowGoAsOneWithCounts() async {
        let n = LoopNotices(), t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(await n.offer("first", done: true, at: t0) == "first")
        #expect(await n.offer("x", done: true, at: t0 + 10) == nil)
        #expect(await n.offer("y", done: true, at: t0 + 30) == nil)
        #expect(await n.offer("z", done: false, at: t0 + 59) == nil)
        #expect(await n.held == 3)
        // past the window: what was held goes with this one, as one line
        let batch = await n.offer("w", done: true, at: t0 + 61)
        #expect(batch == "[collie] Laço: 3 tarefas feitas · 1 adiada" + WorkStatusText.stateHint, "\(String(describing: batch))")
        #expect(await n.held == 0)
        // alone past the window: its own line
        #expect(await n.offer("alone", done: false, at: t0 + 200) == "alone")
        #expect(WorkStatusText.noticeBatch(done: 0, deferred: 2) == "[collie] Laço: 2 tarefas adiadas" + WorkStatusText.stateHint)
        #expect(WorkStatusText.noticeBatch(done: 1, deferred: 0) == "[collie] Laço: 1 tarefa feita" + WorkStatusText.stateHint)
    }

    @Test func theLoopGroupsByTheHostClockAndTheEndNoticeCarriesWhatWasHeld() async throws {
        let r = try await LoopRig([task("a", "test -f a.txt"), task("b", "test -f b.txt"), task("c", "false")], tries: 1,
                                  noticeWindow: LoopNotices.window)
        defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.notify = .task }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.txt", "ok\n", in: $0) }))
        await r.host.set("w-task-b-t1", LoopScript(act: { try await commit("b.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        // all three ended inside one minute of the fake clock: only the first went, the other two wait
        await r.host.endedArrivals.wait(for: 1)
        #expect(await r.loop.notices.held == 2)
        // the loop's end notice is never held: it goes at once and names every task, the held ones too
        let w = try await r.get()
        let end = WorkStatusText.loopEnded(w)
        #expect(end.contains("terminou: 2 feitas, 1 adiadas") && end.contains("Task b") && end.contains("– Task c · adiada"), "\(end)")
        // past the window on the host's clock, the next notice takes the held ones with it
        r.host.advance(61)
        let line = await r.loop.reportEnd(r.work, "a")
        #expect(line == "[collie] Laço: 2 tarefas feitas · 1 adiada" + WorkStatusText.stateHint, "\(String(describing: line))")
        let sent = await { await r.host.endedArrivals.wait(for: 2); return await r.host.ended }()
        #expect(sent.count == 2 && sent[0].hasPrefix("[collie] Laço, tarefa terminada: ✓ Task a"), "\(sent)")
    }

    @Test func aLoopFromBeforeTheUpdateKeepsTask() throws {
        // a state written before M3c.4 has no `notify`: it decodes as nil, read as `task`
        let old = try JSONDecoder().decode(WorkLoopState.self, from: JSONEncoder().encode(WorkLoopState(state: .running, tasks: ["a"])))
        #expect(old.notify == nil)
        var w = Work(title: "W", terminalId: UUID())
        var done = task("a", "true"); done.state = .done
        w.tasks = [done]; w.loop = old
        #expect(WorkLoop.endNotice(w, "a")?.contains("✓ Task a") == true, "a loop already running keeps a notice per task")
    }

    @Test func theOrientationSaysPerTaskNoticesAreOffWithinTheCap() {
        #expect(LoopCommand.body.contains("off by default") && LoopCommand.body.contains("--notify task"))
        #expect(CollieOrientation.loopNotify.contains("off by default") && CollieOrientation.loopNotify.contains("work wait"))
        let t = CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], agent: "codex")
        #expect(t.count <= 1500 && t.contains(CollieOrientation.loopNotify), "\(t.count)\n\(t)")
        for agent in ["claude", "cursor", "codex"] {
            for (term, peers) in [("Ana", ["Bob"]), ("Collie Main", ["Bob", "A very long peer name that goes on and on"])] {
                for shared in [[], ["x"]] {
                    for shepherd in [true, false] {
                        let x = CollieOrientation.text(terminal: term, isShepherd: shepherd, paddock: "collie", peers: peers, panels: [("Home", "design")],
                                                       paddockPanels: [("Draft", "design")], morePanels: true, agent: agent, sharedFolder: shared,
                                                       memoryTask: true, candidates: 3)
                        #expect(x.count <= 1500, "\(agent) \(shepherd) \(x.count)")
                    }
                }
            }
        }
    }
}
