import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M3c.4, `work run --notify task|end`: `end` spares the Shepherd a turn per task done; what it must hear still comes.
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// The notices are fire-and-forget (`reportEnd`): the `n` that must come, counted by the fake host (no clock). That no
/// other one comes is `reportEnd`'s answer, read before its `Task` (M3d.2).
private func notices(_ h: LoopFakeHost, atLeast n: Int) async -> [String] {
    await h.endedArrivals.wait(for: n)
    return await h.ended
}

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}

private func call(_ d: Daemon, _ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}

@Suite(.timeLimit(.minutes(3))) struct LoopNotifyTests {
    @Test func taskByDefaultNotifiesEveryTaskAsBefore() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt"), task("b", "false")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ended = await notices(r.host, atLeast: 2)
        #expect(ended.count == 2, "\(ended)")
        #expect(ended.contains { $0.hasPrefix("[collie] Laço, tarefa terminada: ✓ Task a") }, "\(ended)")
        #expect(ended.contains { $0.hasPrefix("[collie] Laço, tarefa terminada: – Task b · adiada:") }, "\(ended)")
        #expect(try await r.get().loop?.notify == nil)
        // the decision itself, read before its `Task`: both go, and each one sent is one more `taskEnded`
        let a = await r.loop.reportEnd(r.work, "a"), b = await r.loop.reportEnd(r.work, "b")
        #expect(a?.hasPrefix("[collie] Laço, tarefa terminada: ✓ Task a") == true, "\(String(describing: a))")
        #expect(b?.hasPrefix("[collie] Laço, tarefa terminada: – Task b · adiada:") == true, "\(String(describing: b))")
        let all = await notices(r.host, atLeast: 4)
        #expect(all.count == 4, "\(all)")
    }

    /// M3d.2: the rule, with no loop and no clock: only a task done under `--notify end` waits for the loop's end.
    @Test func theNoticeDecisionPerStateAndChoice() {
        var w = Work(title: "W", terminalId: UUID())
        var done = task("a", "true"); done.state = .done
        var deferred = task("b", "false"); deferred.state = .deferred; deferred.reason = "loop: falhou"
        w.tasks = [done, deferred]
        for (notify, state) in [(WorkLoopState.Notify?.none, WorkLoopState.State.running), (.task, .running), (.end, .running),
                                (.end, .stopped), (.end, .finished)] {
            w.loop = WorkLoopState(state: state, tasks: ["a", "b"], notify: notify)
            let a = WorkLoop.endNotice(w, "a"), b = WorkLoop.endNotice(w, "b")
            if notify == .end { #expect(a == nil, "\(state): a done task waits for the end") }
            else { #expect(a?.contains("✓ Task a") == true, "\(String(describing: notify))") }
            #expect(b?.contains("– Task b · adiada: loop: falhou") == true, "\(String(describing: notify)) \(state): a deferred one goes now")
        }
        #expect(WorkLoop.endNotice(w, "gone") == nil)
    }

    @Test func endSkipsTheDoneNoticeButNotTheDeferredOneNorTheEnd() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt"), task("b", "false")], tries: 1); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.notify = .end }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ended = await notices(r.host, atLeast: 1)
        #expect(ended.allSatisfy { !$0.contains("✓ Task a") } && ended.contains { $0.hasPrefix("[collie] Laço, tarefa terminada: – Task b · adiada:") }, "\(ended)")
        // the proof that the done one never goes: `reportEnd`'s own answer, decided before any `Task` (no clock)
        #expect(await r.loop.reportEnd(r.work, "a") == nil, "--notify end: the done task waits for the loop's end")
        #expect(await r.loop.reportEnd(r.work, "b")?.contains("– Task b · adiada:") == true)
        // the loop's end notice (the daemon's, not the host's) still names the done task
        let w = try await r.get()
        let end = WorkStatusText.loopEnded(w)
        #expect(end.contains("terminou: 1 feitas, 1 adiadas") && end.contains("✓ Task a"), "\(end)")
    }

    @Test func endStillSaysWhyALoopStopped() {
        var w = Work(title: "W", terminalId: UUID())
        w.tasks = [task("a", "true")]
        w.loop = WorkLoopState(state: .stopped, tasks: ["a"], notify: .end)
        for code in WorkLoopState.Stop.Code.allCases {
            w.loop?.stopReason = .init(code)
            #expect(WorkStatusText.loopEnded(w).contains("parou (\(RerailText.clean(WorkLoopState.Stop(code).label)))"), "\(code)")
        }
    }

    @Test func anOldStateWithoutTheFieldDecodesAsTask() throws {
        let l = WorkLoopState(tasks: ["a"])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        #expect(json["notify"] == nil)   // `task` is never written: a file of today reads as before
        let old = try JSONDecoder().decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.notify == nil && (old.notify ?? .task) == .task)
        json["notify"] = "weekly"   // a value this daemon cannot read: no notify, the loop survives
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: json)).notify == nil)
        json["notify"] = "end"
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: json)).notify == .end)
    }

    @Test func theCommandTakesNotifyAndRefusesAnInvalidValue() async throws {
        let spec = try #require(Commands.spec("work.run")?.params.first { $0.name == "notify" })
        #expect(spec.kind == .string && spec.help.contains("task|end"))
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
            #expect(try await call(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
            #expect(try await call(d, p, s, "work.task.add", ["title": .string("x"), "check": .string("true")]).ok)
            for bad in ["", "tasks", "END", "none"] {
                let r = try await call(d, p, s, "work.run", ["max": .number(1), "notify": .string(bad)])
                #expect(r.error?.code == .invalidArgs && r.error?.message.contains("--notify") == true, "\(bad): \(r)")
            }
            #expect(try await d.router.work.active(terminal: s.uuid)?.loop == nil)
        }
    }

    @Test func statusCardAndTrustedNoticeShowTheChoice() {
        var w = Work(title: "W", terminalId: UUID())
        w.tasks = [task("a", "true")]
        w.loop = WorkLoopState(max: 3, tasks: ["a"])
        #expect(WorkStatusText.notifyLine(w) == nil)
        w.loop?.notify = .task
        #expect(WorkStatusText.notifyLine(w) == nil)
        #expect(CommandRouter.loopCardText(w, w.tasks, w.loop!, paddock: "p")?.contains("avisos") == false)
        w.loop?.notify = .end
        #expect(WorkStatusText.notifyLine(w) == "avisos: só no fim")
        #expect(CommandRouter.loopCardText(w, w.tasks, w.loop!, paddock: "p")?.contains("avisos: só no fim (--notify end).") == true)
        #expect(WorkStatusText.loopTrusted(paddock: "p", w.tasks, w.loop!).contains("avisos: só no fim"))
    }

    @Test func theOrientationAndTheLoopCommandTeachItWithinTheCap() {
        // M5.1: `end` is the default now: the texts name `--notify task`, the way back to a notice per task
        #expect(LoopCommand.body.contains("collie work run --notify task"))
        let t = CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], agent: "codex")
        #expect(t.count <= 1500 && t.contains(CollieOrientation.loopNotify), "\(t.count)\n\(t)")
        for agent in ["claude", "cursor", "codex"] {
            for (term, peers) in [("Ana", ["Bob"]), ("Collie Main", ["Bob", "A very long peer name that goes on and on"])] {
                for shared in [[], ["x"]] {
                    let x = CollieOrientation.text(terminal: term, isShepherd: true, paddock: "collie", peers: peers, panels: [("Home", "design")],
                                                   paddockPanels: [("Draft", "design")], morePanels: true, agent: agent, sharedFolder: shared,
                                                   memoryTask: true, candidates: 3)
                    #expect(x.count <= 1500 && x.components(separatedBy: "--notify end").count <= 2, "\(agent) \(x.count)")
                }
            }
        }
    }
}
