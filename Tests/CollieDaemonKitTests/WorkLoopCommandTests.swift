import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil,
                     command: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// `t` nil: the app (admin token).
private func work(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}

@Suite(.serialized) struct WorkLoopCommandTests {
    @Test func taskAddStoresSpecAndCheck() async throws {
        let repo = try await makeRepo()
        try "# Spec\n".write(to: repo.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("Build it"), "check": .string("true"), "spec": .string(repo.appendingPathComponent("spec.md").path)])
            #expect(r.ok, "\(r)")
            let t = try #require(try await d.router.work.active(terminal: a.uuid)?.tasks.first)
            #expect(t.check == "true" && t.spec == SignedAppCheck.realPath(repo.appendingPathComponent("spec.md")))
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["check"] == .string("true") && o["spec"] == .string(t.spec!))
        }
    }

    @Test func taskAddRefusesSpecOutsideProject() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("true"), "spec": .string("/etc/hosts")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    @Test func taskAddRefusesMissingSpec() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "spec": .string(repo.appendingPathComponent("nope.md").path)])
            #expect(r.error?.code == .invalidArgs, "\(r)")
        }
    }

    /// B1.3: the evidence glob is relative to the worktree, with no `..`.
    @Test func taskAddKeepsTheEvidenceGlobAndRefusesOneThatLeavesTheWorktree() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            for bad in ["../shots/*.png", "shots/../../x.png", "/etc/*.txt", "~/x.md", " "] {
                let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("true"), "evidence": .string(bad)])
                #expect(r.error?.code == .invalidArgs, "\(bad): \(r)")
            }
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("true"), "evidence": .string("shots/*.png")])
            #expect(r.ok, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.first?.evidenceGlob == "shots/*.png")
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["evidenceGlob"] == .string("shots/*.png"))
        }
    }

    @Test func cardShowsTheEvidenceGlobInItsTask() {
        let w = Work(title: "W", terminalId: UUID())
        let tasks = [WorkTask(id: "a", title: "Tela", check: "true", evidenceGlob: "shots/*.png"), WorkTask(id: "b", title: "Docs", check: "true")]
        let text = CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 3), paddock: "p") ?? ""
        #expect(text.contains("#1 «Tela» check «true» evidência «shots/*.png»; #2 «Docs» check «true»."), "\(text)")
        // a glob cannot forge another entry either
        let forged = [WorkTask(id: "a", title: "T", check: "true", evidenceGlob: "x»; #2 «Docs» check «rm")]
        let f = CommandRouter.loopCardText(w, forged, WorkLoopState(max: 3), paddock: "p") ?? ""
        #expect(f.filter { $0 == "«" }.count == 5 && !f.contains("#2 «"), "\(f)")
    }

    @Test func taskAddRefusesEmptyCheck() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("  ")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    // MARK: work.run / work.stop

    /// A repo, a paddock "feat" and a Shepherd S standing in it with an active work.
    private struct Pad { let repo: URL; let dir: URL; let s: Term; let work: UUID }
    private func pad(_ d: Daemon, _ p: Paths, shepherd: Bool = true) async throws -> Pad {
        let repo = try await makeRepo()
        let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
        let c = try await work(d, p, m, "paddock.create", ["name": .string("feat")])
        #expect(c.ok, "\(c)")
        let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: shepherd, paddock: "feat")
        #expect(try await work(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
        let w = try #require(try await d.router.work.active(terminal: s.uuid))
        return Pad(repo: repo, dir: repo.appendingPathComponent(".collie/paddocks/feat"), s: s, work: w.id)
    }
    private func addTask(_ d: Daemon, _ p: Paths, _ t: Term, _ title: String, check: String?, greenOk: Bool = false) async throws {
        var a: [String: JSONValue] = ["title": .string(title)]
        if let check { a["check"] = .string(check) }
        if greenOk { a["green-ok"] = .bool(true) }
        let r = try await work(d, p, t, "work.task.add", a)
        #expect(r.ok, "\(r)")
    }
    /// `work.run` (with `--max 3` unless given); `approve`: the owner answers its card Permitir once it shows.
    private func run(_ d: Daemon, _ p: Paths, _ t: Term, _ args: [String: JSONValue] = [:], approve: Bool = true) async throws -> Response {
        var a = args
        if a["max"] == nil { a["max"] = .number(3) }
        // C5a: a shell Shepherd's own agent never ends a turn: refused; `cat` (no end of turn either) is a named program
        if a["command"] == nil && a["preset"] == nil { a["command"] = .string("cat") }
        let r = try await work(d, p, t, "work.run", a)
        if r.ok && approve { #expect(try await answerCard(d, p, allow: true) != nil, "no approval card") }
        return r
    }
    private func answerCard(_ d: Daemon, _ p: Paths, allow: Bool, always: Bool = false) async throws -> AppCard? {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let c = await d.router.appCards.first(where: { $0.app == "work-loop" }) {
                let r = try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                                  args: ["id": .string(c.id.uuidString), "allow": .bool(allow), "always": .bool(always)]))
                #expect(r.ok, "\(r)")
                return c
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    /// M3.8: the terminals of `work`'s loop attempts still there, found by the id on their job (never by a name's prefix).
    private func loopAgentsLeft(_ d: Daemon, _ work: UUID) async -> Int {
        guard let w = try? await d.router.work.get(work) else { return 0 }
        return CommandRouter.loopAgents(of: w, in: await d.router.ws.terminals, reviewRoot: WorkLoop.reviewRoot(of: await d.router.config.paths.root)).count
    }
    /// A loop notice typed into the starter's shell (`asks.inject`, `afterQuiet`: after its queue, its quiet window and
    /// a readiness gate). Delivery is fire-and-forget, so there is no event to await: 90 s absorbs a loaded CI runner
    /// (the old 20 s did not, run 45073169794) and costs nothing when it passes; a miss says what S's screen held.
    private func expectNotice(_ d: Daemon, _ s: Term, _ text: String) async {
        let seen = await waitFor(90) { await d.scrollbackText(s.uuid).contains(text) }
        let tail = String((await d.scrollbackText(s.uuid)).suffix(600)), queued = await d.router.asks.queued(s.uuid)
        #expect(seen, "no notice «\(text)» in S's scrollback after 90 s; queued asks: \(queued); tail: \(tail)")
    }
    private func loopEnded(_ d: Daemon, _ id: UUID) async -> Bool {
        await waitFor(60) { (try? await d.router.work.get(id))?.loop.map { $0.state != .running } ?? false }
    }

    @Test func runNeedsAShepherd() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p, shepherd: false)
            try await addTask(d, p, x.s, "A", check: "true")
            #expect(try await run(d, p, x.s, approve: false).error?.code == .notShepherd)
        }
    }

    @Test func runNeedsAPaddock() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await work(d, p, m, "work.start", ["title": .string("W")]).ok)
            try await addTask(d, p, m, "A", check: "true")
            let r = try await run(d, p, m, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("paddock") == true, "\(r)")
        }
    }

    @Test func runNeedsOpenTasks() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("no open task") == true, "\(r)")
        }
    }

    @Test func runNamesTasksWithoutCheck() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Has one", check: "true")
            try await addTask(d, p, x.s, "Lacks one", check: nil)
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("Lacks one") == true
                    && r.error?.message.contains("Has one") == false, "\(r)")
        }
    }

    @Test func runRefusesDirtyWorktree() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            try "dirty\n".write(to: x.dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("f.txt") == true, "\(r)")
        }
    }

    @Test func runRefusesWhileAnotherAgentWorks() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            let busy = try await spawnIn(d, p, "busy", cwd: x.repo, paddock: "feat")
            try await liveProcess(d, busy.uuid).write(Data("while true; do echo tick; sleep 0.2; done\n".utf8))
            #expect(await waitFor(20) { await d.badge(busy.uuid) == .working })
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("busy") == true, "\(r)")
        }
    }

    /// C2/C5c: a check that already passes at the cercado's HEAD does not measure the task: the loop's first phase stops it
    /// with `checkAlreadyGreen`, no attempt, the same words in the note; the paddock is free again.
    @Test func aCheckThatAlreadyPassesStopsTheLoopInItsPreCheck() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Trivial", check: "true")
            try await addTask(d, p, x.s, "Real", check: "false")
            #expect(try await run(d, p, x.s, ["command": .string("cat")]).ok)
            #expect(await loopEnded(d, x.work))
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.loop?.stopReason?.code == .checkAlreadyGreen && w.loop?.used == 0, "\(String(describing: w.loop))")
            let note = try #require(w.notes.first { $0.text.contains("o check já passa antes da tarefa: não mede o que ela muda") })
            #expect(note.text.contains("Trivial") && !note.text.contains("Real") && note.text.contains("--green-ok"), "\(note.text)")
            #expect(await waitFor(20) { await d.router.loopPaddocks.isEmpty })
            // and a corrected run starts
            let fixed = try await work(d, p, x.s, "work.task.drop", ["task": .string("Trivial"), "reason": .string("trivial")])
            #expect(fixed.ok, "\(fixed)")
            let first = try #require(w.loop?.startedAt)
            #expect(try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)]).ok)
            // the new loop (not the first one, still on record until the engine starts) ran and ended
            #expect(await waitFor(60) { (try? await d.router.work.get(x.work))?.loop.map { $0.startedAt > first && $0.state != .running } ?? false })
            let again = try await d.router.work.get(x.work)?.loop
            #expect(again?.stopReason?.code != .checkAlreadyGreen && again?.events?.contains { $0.kind == .attemptStarted } == true, "\(String(describing: again))")
        }
    }

    /// C5c: `work run` never waits for the pre-check: a slow check (20 s) and the reply comes at once, `starting`, the
    /// loop in its pre-check phase; `work stop` then ends it at once and frees the paddock.
    @Test func workRunReturnsBeforeThePreCheckEnds() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Slow", check: "sleep 20; true")
            #expect(try await trust(d, p).ok)
            let t0 = ContinuousClock.now
            let r = try await run(d, p, x.s, ["command": .string("cat")], approve: false)
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["state"] == .string("starting") && ContinuousClock.now - t0 < .seconds(10), "\(r)")
            #expect(await waitFor(20) { (try? await d.router.work.get(x.work))?.loop?.phase == .preCheck })
            let stop = try await work(d, p, x.s, "work.stop")
            #expect(stop.ok, "\(stop)")
            #expect(await loopEnded(d, x.work))
            #expect(ContinuousClock.now - t0 < .seconds(18))
            #expect(try await d.router.work.get(x.work)?.loop?.stopReason?.code == .requested)
            #expect(await waitFor(20) { await d.router.loopPaddocks.isEmpty })
        }
    }

    /// C5c, vetoes of attempt 1: the client gives up while `work run` still holds the paddock's reservation (the
    /// command's `Task` cancelled at a point the test controls): `work run` fails, starts no loop, and the paddock is
    /// free again with no `work stop`. Without the `defer` that frees the reservation, `loopPaddocks` keeps it.
    @Test func aCancelledWorkRunNeverLeavesThePaddockReserved() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Slow", check: "false")
            #expect(try await trust(d, p).ok)
            let (entered, inside) = AsyncStream<Void>.makeStream()
            await d.router.c5cHold { inside.yield(); try? await Task.sleep(for: .seconds(60)) }
            let me = try #require(await d.router.ws.terminals.first { $0.id == x.s.uuid })
            let req = Request(id: "w", terminalId: x.s.id, token: x.s.token, command: "work.run",
                              args: ["max": .number(3), "command": .string("cat")])
            let cmd = Task { try await d.router.workRun(req, caller: me, starter: me) }
            for await _ in entered { break }
            #expect(await !d.router.loopPaddocks.isEmpty, "work run holds the reservation while it is held")
            cmd.cancel()
            let r = await cmd.result
            if case .success(let v) = r { Issue.record("a cancelled work run went on: \(v)") }
            #expect(await d.router.loopPaddocks.isEmpty, "a cancelled work run left the paddock reserved")
            #expect(await d.router.workLoops.isEmpty)
            #expect(try await d.router.work.get(x.work)?.loop == nil)
            // and the paddock takes a new run at once
            await d.router.c5cHold(nil)
            #expect(try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)]).ok)
            #expect(await loopEnded(d, x.work))
            #expect(await waitFor(20) { await d.router.loopPaddocks.isEmpty })
        }
    }

    /// C5c: a reservation with no loop and no card (nothing would free it): `work stop` frees it, `released`.
    @Test func workStopReleasesAReservationWithNoLoop() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            let pid = try #require(await d.router.ws.paddocks.first { $0.name == "feat" }?.id)
            await d.router.c5cReserve(pid)
            let r = try await work(d, p, x.s, "work.stop")
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["state"] == .string("released"), "\(r)")
            #expect(await d.router.loopPaddocks.isEmpty)
            #expect(try await work(d, p, x.s, "work.stop").error?.message.contains("no loop is running") == true)
        }
    }

    /// C3: `--escalate` replaces --preset/--model/--command, and takes only claude|cursor entries; refused before the card.
    @Test func runRefusesABadEscalate() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Real", check: "false")
            for a: [String: JSONValue] in [["escalate": .string("cursor:a"), "model": .string("sonnet")],
                                            ["escalate": .string("cursor:a"), "command": .string("cat")],
                                            ["escalate": .string("codex:x")]] {
                let r = try await run(d, p, x.s, a, approve: false)
                #expect(r.error?.code == .invalidArgs && r.error?.message.contains("escalate") == true, "\(r)")
            }
            #expect(await d.router.appCards.isEmpty)
            #expect(try await d.router.work.get(x.work)?.loop == nil)
        }
    }

    @Test func cardShowsTheEscalation() {
        let w = Work(title: "W", terminalId: UUID())
        let l = WorkLoopState(escalate: ["cursor:a", "claude:b"])
        #expect(CommandRouter.loopCardText(w, [], l, paddock: "p")?.contains("escalada de modelo por tentativa: «cursor:a, claude:b»") == true)
    }

    /// C2: `--green-ok` on the task: it goes to the card, marked.
    @Test func runAcceptsAGreenCheckMarkedGreenOk() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            let a = try await work(d, p, x.s, "work.task.add", ["title": .string("Refactor"), "check": .string("true"), "green-ok": .bool(true)])
            #expect(a.ok, "\(a)")
            #expect(try await d.router.work.get(x.work)?.tasks.first?.greenOk == true)
            let r = try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)], approve: false)
            #expect(r.ok, "\(r)")
            let card = try #require(try await answerCard(d, p, allow: false))
            #expect(card.call?.contains("check «true» --green-ok") == true, "\(String(describing: card.call))")
        }
    }

    /// C2: red at the start (the check fails, or cannot run) is what a check should be: the run goes on.
    @Test func runGoesOnWhenTheCheckIsRedAtTheStart() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Red", check: "false")
            try await addTask(d, p, x.s, "Missing", check: "python3 -c 'import nope_slug'")
            let r = try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)], approve: false)
            #expect(r.ok, "\(r)")
            #expect(try await answerCard(d, p, allow: false) != nil)
        }
    }

    @Test func cardMarksGreenOkBesideTheCheck() {
        let tasks = [WorkTask(id: "a", title: "A", check: "true", greenOk: true), WorkTask(id: "b", title: "B", check: "false")]
        let card = CommandRouter.loopCardText(Work(title: "W", terminalId: UUID()), tasks, WorkLoopState(max: 3), paddock: "feat") ?? ""
        #expect(card.contains("#1 «A» check «true» --green-ok") && !card.contains("check «false» --green-ok"), "\(card)")
    }

    @Test func runPassesATaskEndToEnd() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Write done", check: "test -f done.txt")
            let agent = "bash -c 'read l; echo ok > done.txt; git add done.txt; git commit -qm done; cat'"
            let r = try await run(d, p, x.s, ["command": .string(agent), "timeout": .number(60)])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["state"] == .string("awaiting approval") && o["tasks"] == .number(1))
            #expect(await loopEnded(d, x.work))
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.tasks.first?.state == .done && w.loop?.state == .finished, "\(w.tasks) \(String(describing: w.loop)) \(w.notes.map(\.text))")
            #expect(await loopAgentsLeft(d, x.work) == 0)
            await expectNotice(d, x.s, "[collie] Laço de \"Loop work\" terminou: 1 feitas, 0 adiadas")
            // a `work.task.done` that lands after the approval does not take the evidence away
            let done = try await work(d, p, x.s, "work.task.done", ["task": .string("Write done")])
            #expect(done.ok, "\(done)")
            let t = try #require(try await d.router.work.get(x.work)?.tasks.first)
            #expect(t.state == .done && t.tries == 1 && t.evidence?.commits.count == 1, "\(t)")
        }
    }

    @Test func endNoticeNamesATaskDoneByHand() {
        let e = TaskEvidence(commits: ["abc1234 feat: x"], shortstat: "1 file changed", checkTail: "ok", seconds: 9, attempt: 1)
        var w = Work(title: "Loop work", terminalId: UUID(), tasks: [
            WorkTask(id: "a", title: "By the loop", state: .done, evidence: e),
            WorkTask(id: "b", title: "By\nhand", state: .done)])
        w.loop = WorkLoopState(state: .finished, tasks: ["a", "b"])
        #expect(WorkStatusText.loopEnded(w) == """
            [collie] Laço de "Loop work" terminou: 2 feitas, 0 adiadas. · estado: collie work status
            ✓ By the loop · tentativa 1 · 1 commit · 1 file changed
            ✓ By hand · marcada à mão, sem check
            """)
    }

    @Test func endNoticeHasOneLinePerLoopTask() {
        let e = TaskEvidence(commits: ["abc1234 feat: x", "abc1235 fix: y"], shortstat: "3 files changed, 10 insertions(+)",
                             checkTail: "ok", seconds: 9, attempt: 2)
        var w = Work(title: "Loop work", terminalId: UUID(), tasks: [
            WorkTask(id: "a", title: "Write done", state: .done, evidence: e),
            WorkTask(id: "b", title: "Flaky one", state: .deferred, reason: "loop: check failed\n(exit 1)"),
            WorkTask(id: "old", title: "Done before the loop", state: .done)])
        w.loop = WorkLoopState(state: .finished, tasks: ["a", "b"])
        #expect(WorkStatusText.loopEnded(w) == """
            [collie] Laço de "Loop work" terminou: 1 feitas, 1 adiadas. · estado: collie work status
            ✓ Write done · tentativa 2 · 2 commits · 3 files changed, 10 insertions(+)
            – Flaky one · adiada: loop: check failed (exit 1)
            """)
    }

    @Test func endNoticeIsBounded() {
        var w = Work(title: "Big", terminalId: UUID(), tasks: (0..<60).map {
            WorkTask(id: "\($0)", title: String(repeating: "x", count: 100) + " \($0)", state: .deferred, reason: "loop: no commit")
        })
        w.loop = WorkLoopState(state: .finished)
        let s = WorkStatusText.loopEnded(w), lines = s.split(separator: "\n")
        #expect(s.count <= RerailText.limit && s.hasPrefix("[collie] Laço de \"Big\" terminou: 0 feitas, 60 adiadas"))
        #expect(lines.last == "… e mais \(60 - (lines.count - 2))", "\(lines.last ?? "")")
    }

    @Test func secondRunIsRefused() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "false")
            #expect(try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)]).ok)
            let r = try await run(d, p, x.s, ["command": .string("cat")], approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("already") == true, "\(r)")
            #expect(await loopEnded(d, x.work))
        }
    }

    /// C5a: a shell Shepherd with no --preset (nor --command) would run its attempts in a zsh that never ends a turn:
    /// refused, no card; --preset claude on the same Shepherd passes (to its card).
    @Test func aShellShepherdsLoopNeedsAnAgentWithAnEndOfTurn() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true", greenOk: true)
            let shell = try await work(d, p, x.s, "work.run", ["max": .number(3)])
            #expect(shell.error?.code == .invalidArgs && shell.error?.message == CommandRouter.loopAgentRefusal, "\(shell)")
            let given = try await work(d, p, x.s, "work.run", ["max": .number(3), "preset": .string("shell")])
            #expect(given.error?.message == CommandRouter.loopAgentRefusal, "\(given)")
            #expect(await d.router.appCards.isEmpty)
            let claude = try await run(d, p, x.s, ["preset": .string("claude")], approve: false)
            #expect(claude.ok, "\(claude)")
        }
    }

    /// Finding 7: --max is required and every limit has a hard ceiling.
    @Test func runNeedsMaxAndHardCaps() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            let none = try await work(d, p, x.s, "work.run")
            #expect(none.error?.code == .invalidArgs && none.error?.message.contains("--max") == true, "\(none)")
            for (k, v) in [("max", 31.0), ("timeout", 14_401), ("budget", 43_201), ("tries", 11), ("parallel", 5), ("parallel", 0)] {
                var a: [String: JSONValue] = ["max": .number(3)]; a[k] = .number(v)
                #expect(try await work(d, p, x.s, "work.run", a).error?.code == .invalidArgs, "\(k)")
            }
            // M3.5: lanes run only sandboxed, and this daemon sandboxes no terminal
            let lanes = try await work(d, p, x.s, "work.run", ["command": .string("cat"), "max": .number(3), "parallel": .number(2)])
            #expect(lanes.error?.code == .invalidArgs && lanes.error?.message.contains("--parallel") == true, "\(lanes)")
            #expect(await d.router.appCards.isEmpty)
        }
    }

    /// Finding 7: nothing runs until the owner answers Permitir on a card listing the tasks, checks and limits.
    @Test func runWaitsForTheOwnersCard() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Write done", check: "test -f done.txt")
            #expect(try await run(d, p, x.s, ["max": .number(4), "budget": .number(600)], approve: false).ok)
            let card = try #require(try await answerCard(d, p, allow: false))
            let call = card.call ?? ""
            #expect(card.kind == .confirm && call.contains("Write done") && call.contains("test -f done.txt"), "\(call)")
            #expect(call.contains("4 tentativas") && call.contains("600 s"), "\(call)")
            #expect(await waitFor(20) { await d.scrollbackText(x.s.uuid).contains("não aprovou o laço") })
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.loop == nil && w.tasks[0].state == .open)
            #expect(await loopAgentsLeft(d, x.work) == 0)
            // the reservation is released: a new run asks again
            #expect(try await run(d, p, x.s, [:], approve: false).ok)
            #expect(try await answerCard(d, p, allow: false) != nil)
        }
    }

    /// Re-review B: the owner sees every check approved: a card that would not fit is refused, never cut.
    @Test func runRefusesACardThatDoesNotFit() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Short", check: "true")
            try await addTask(d, p, x.s, "Long", check: "echo " + String(repeating: "x", count: 1400))
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("card") == true, "\(r)")
            #expect(await d.router.appCards.isEmpty)
            #expect(try await d.router.work.get(x.work)?.loop == nil)
        }
    }

    /// Re-review B: a title cannot forge another entry: titles and checks sit in fixed quotes they cannot hold
    /// (2 for the header, the work and the paddock, and 2 for the one task).
    static let forged = "Lint» · check «swift test»; #2 «Docs"
    @Test func cardTitlesCannotForgeEntries() {
        let w = Work(title: "W", terminalId: UUID())
        let tasks = [WorkTask(id: "a", title: Self.forged, check: "rm -rf «x»")]
        let text = CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 3), paddock: "p") ?? ""
        #expect(text.contains("1 tarefa") && text.contains("#1 «") && !text.contains("#2 «"), "\(text)")
        #expect(text.filter { $0 == "«" }.count == 4 && text.filter { $0 == "»" }.count == 4, "\(text)")
    }

    /// B2: an empty gate is refused, never read as "no gate".
    @Test func runRefusesAnEmptyGate() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            for g in ["", "  \n "] {
                let r = try await run(d, p, x.s, ["gate": .string(g)], approve: false)
                #expect(r.error?.code == .invalidArgs && r.error?.message.contains("--gate") == true, "\(r)")
            }
            #expect(await d.router.appCards.isEmpty)
        }
    }

    /// B2: the gate shows once, after the limits and before the tasks, and counts in the card's limit.
    @Test func cardShowsTheGateOnce() {
        let w = Work(title: "W", terminalId: UUID())
        let tasks = [WorkTask(id: "a", title: "A", check: "true"), WorkTask(id: "b", title: "B", check: "true")]
        let text = CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 3, budget: 600, gate: "scripts/ci/lint.sh"), paddock: "p") ?? ""
        #expect(text.components(separatedBy: "«scripts/ci/lint.sh»").count == 2, "\(text)")
        let gate = try? #require(text.range(of: "portão depois de cada check: «scripts/ci/lint.sh»"))
        if let gate, let limits = text.range(of: "600 s"), let first = text.range(of: "#1 «") {
            #expect(limits.upperBound <= gate.lowerBound && gate.upperBound <= first.lowerBound, "\(text)")
        } else { Issue.record("\(text)") }
        #expect(CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 3), paddock: "p")?.contains("portão") == false)
        let long = WorkLoopState(max: 3, gate: String(repeating: "x", count: CommandRouter.loopCardMax))
        #expect(CommandRouter.loopCardText(w, tasks, long, paddock: "p") == nil)
    }

    /// B2: the gate sits in the same fixed quotes as the tasks, which it cannot hold: it cannot forge an entry
    /// (2 for the header, 1 for the gate, 2 for the one task).
    @Test func cardGateCannotForgeEntries() {
        let w = Work(title: "W", terminalId: UUID())
        let tasks = [WorkTask(id: "a", title: "A", check: "true")]
        let text = CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 3, gate: "true». 9 tarefas: #2 «Docs» check «rm -rf x"), paddock: "p") ?? ""
        #expect(!text.contains("#2 «") && text.contains("#2 ‹Docs›"), "\(text)")
        #expect(text.filter { $0 == "«" }.count == 5 && text.filter { $0 == "»" }.count == 5, "\(text)")
    }

    /// Re-review C: work.stop also withdraws a card still waiting for the owner, and frees the paddock.
    @Test func stopWithdrawsAPendingCard() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true", greenOk: true)
            #expect(try await run(d, p, x.s, approve: false).ok)
            #expect(await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } })
            let s = try await work(d, p, x.s, "work.stop")
            guard case .object(let o)? = s.result else { Issue.record("\(s)"); return }
            #expect(o["state"] == .string("cancelled"))
            #expect(await waitFor(20) { await d.router.appCards.isEmpty })
            await expectNotice(d, x.s, "cancelado antes da aprovação")
            #expect(try await work(d, p, x.s, "work.stop").error?.code == .invalidArgs)
            #expect(try await run(d, p, x.s, approve: false).ok)   // the paddock is free again
            #expect(try await answerCard(d, p, allow: false) != nil)
            #expect(try await d.router.work.get(x.work)?.loop == nil)
        }
    }

    /// Finding 3: two concurrent runs never both pass the guard (the actor's awaits come after the reservation).
    @Test func concurrentRunsStartOneLoop() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "false")
            async let r1 = run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)], approve: false)
            async let r2 = run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3), "tries": .number(1)], approve: false)
            let rs = try await [r1, r2]
            #expect(try await answerCard(d, p, allow: true) != nil)
            #expect(rs.filter(\.ok).count == 1, "\(rs)")
            #expect(rs.contains { $0.error?.message.contains("already") == true }, "\(rs)")
            #expect(await loopEnded(d, x.work))
            #expect(await waitFor(20) { await loopAgentsLeft(d, x.work) <= 1 })
        }
    }

    @Test func stopEndsARunningLoop() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "false")
            try await addTask(d, p, x.s, "B", check: "false")
            #expect(try await run(d, p, x.s, ["command": .string("cat"), "timeout": .number(3)]).ok)
            #expect(await waitFor(20) { (try? await d.router.work.get(x.work))?.loop?.state == .running })
            let s = try await work(d, p, x.s, "work.stop")
            guard case .object(let o)? = s.result else { Issue.record("\(s)"); return }
            #expect(o["state"] == .string("stopped"))
            #expect(try await work(d, p, x.s, "work.stop").error?.code == .invalidArgs)
            #expect(await loopEnded(d, x.work))
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.loop?.state == .stopped && w.tasks.map(\.state) == [.open, .open] && w.loop?.used == 1)
            #expect(try await work(d, p, x.s, "work.stop").error?.code == .invalidArgs)
        }
    }

    /// Finding 5: a loop's agents left by a dead daemon are removed by the start sweep.
    @Test func restartSweepRemovesLeftAgents() async throws {
        try await withDaemon { d, p in
            let left = try await spawnIn(d, p, "w-a-t1", cwd: URL(fileURLWithPath: "/tmp"))
            let other = try await spawnIn(d, p, "w-zz-t9", cwd: URL(fileURLWithPath: "/tmp"))   // not this work's
            let w = try await d.router.work.start(title: "looping", terminal: UUID(), paddockId: nil, branch: nil)
            try await d.router.work.update(w.id) {
                $0.tasks = [WorkTask(id: "a", title: "A", state: .inProgress, check: "true")]
                $0.jobs = [WorkJob(id: "w-a-t1", kind: .loop, label: "A")]
                $0.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
            }
            await d.router.stopLoopsLeftRunning()
            let names = await d.router.ws.terminals.map(\.id)
            #expect(!names.contains(left.uuid) && names.contains(other.uuid))
        }
    }

    @Test func restartLeavesNoRunningLoop() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let dir = paths.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var w = Work(title: "looping", terminalId: UUID(), paddockId: UUID(),
                     tasks: [WorkTask(id: "a", title: "A", state: .inProgress, check: "true"), WorkTask(id: "b", title: "B", state: .done)],
                     jobs: [WorkJob(id: "w-a-t1", kind: .loop, label: "A")])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode([w]).write(to: dir.appendingPathComponent("work.json"))
        let d = try Daemon(config: testConfig(paths))
        do { try await d.start() } catch { await d.stop(); throw error }
        let after = try await d.router.work.get(w.id)
        await d.stop()
        #expect(after?.loop?.state == .stopped && after?.loop?.endedAt != nil && after?.loop?.task == nil)
        #expect(after?.tasks.map(\.state) == [.open, .done])
        #expect(after?.jobs.first?.state == .gone && after?.jobs.first?.endedAt != nil)
    }

    @Test func workListCarriesTheLoopLine() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let dir = paths.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var looped = Work(title: "looped", terminalId: UUID(), tasks: [WorkTask(id: "a", title: "A", state: .deferred, check: "false")])
        looped.loop = WorkLoopState(state: .stopped, used: 2)
        let plain = Work(title: "plain", terminalId: UUID(), tasks: [WorkTask(id: "b", title: "B")])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode([looped, plain]).write(to: dir.appendingPathComponent("work.json"))
        let d = try Daemon(config: testConfig(paths))
        do { try await d.start() } catch { await d.stop(); throw error }
        let r = try await work(d, paths, nil, "work.list")
        await d.stop()
        guard case .array(let a)? = r.result else { Issue.record("\(r)"); return }
        func entry(_ id: UUID) -> [String: JSONValue]? {
            a.lazy.compactMap { if case .object(let o) = $0, o["id"] == .string(id.uuidString.lowercased()) { return o } else { return nil } }.first
        }
        #expect(entry(looped.id)?["loop"] == .string("laço parado (2 tentativas)"), "\(a)")
        #expect(entry(plain.id) != nil && entry(plain.id)?["loop"] == nil, "\(a)")
    }

    // MARK: B6.1 loops trusted per paddock

    /// The owner's "Sempre neste cercado" (only the app: the admin token outside a terminal).
    private func trust(_ d: Daemon, _ p: Paths, on: Bool = true) async throws -> Response {
        let id = try #require(await d.router.ws.paddocks.first { $0.name == "feat" }?.id)
        return try await work(d, p, nil, "admin.paddock.trust-loops", ["paddock": .string(id.uuidString), "on": .bool(on)])
    }
    private func trusted(_ d: Daemon) async -> Bool? { await d.router.ws.paddocks.first { $0.name == "feat" }?.trustLoops }

    /// Not trusted: the card, and nothing runs before Permitir. Trusted: no card, the loop starts, the Shepherd is told.
    @Test func trustedPaddockRunsWithoutTheCard() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Write done", check: "test -f done.txt")
            let agent = "bash -c 'read l; echo ok > done.txt; git add done.txt; git commit -qm done; cat'"
            let args: [String: JSONValue] = ["command": .string(agent), "timeout": .number(60)]
            let asked = try await run(d, p, x.s, args, approve: false)
            guard case .object(let a)? = asked.result else { Issue.record("\(asked)"); return }
            #expect(a["state"] == .string("awaiting approval"))
            #expect(await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } })
            #expect(try await d.router.work.get(x.work)?.loop == nil)
            #expect(try await answerCard(d, p, allow: false) != nil)
            #expect(await waitFor(20) { await d.scrollbackText(x.s.uuid).contains("não aprovou o laço") })
            #expect(try await d.router.work.get(x.work)?.loop == nil)

            let t = try await trust(d, p)
            guard case .object(let o)? = t.result else { Issue.record("\(t)"); return }
            #expect(o["trustLoops"] == .bool(true) && o["name"] == .string("feat"), "\(o)")
            let r = try await run(d, p, x.s, args, approve: false)
            guard case .object(let ran)? = r.result else { Issue.record("\(r)"); return }
            #expect(ran["state"] == .string("starting") && ran["tasks"] == .number(1))
            #expect(try await d.router.work.get(x.work)?.loop != nil)   // started before the reply, no card in between
            #expect(await d.router.appCards.isEmpty)
            #expect(await loopEnded(d, x.work))
            #expect(await d.router.appCards.isEmpty)
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.tasks.first?.state == .done && w.loop?.state == .finished, "\(w.tasks) \(String(describing: w.loop))")
            #expect(await waitFor(20) { await d.scrollbackText(x.s.uuid).contains("Laço iniciado sem cartão") })
        }
    }

    /// Trust drops only the card: --max, the hard caps, the card's size limit and the clean tree still refuse.
    @Test func trustedPaddockKeepsTheLimitsAndTheCleanTree() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            #expect(try await trust(d, p).ok)
            let none = try await work(d, p, x.s, "work.run")
            #expect(none.error?.code == .invalidArgs && none.error?.message.contains("--max") == true, "\(none)")
            for (k, v) in [("max", 31.0), ("timeout", 14_401), ("budget", 43_201), ("tries", 11)] {
                var a: [String: JSONValue] = ["max": .number(3)]; a[k] = .number(v)
                #expect(try await work(d, p, x.s, "work.run", a).error?.code == .invalidArgs, "\(k)")
            }
            try await addTask(d, p, x.s, "Long", check: "echo " + String(repeating: "x", count: 1400))
            let big = try await run(d, p, x.s, approve: false)
            #expect(big.error?.code == .invalidArgs && big.error?.message.contains("card") == true, "\(big)")
            #expect(try await work(d, p, x.s, "work.task.drop", ["task": .string("Long"), "reason": .string("too long")]).ok)
            try "dirty\n".write(to: x.dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            let dirty = try await run(d, p, x.s, approve: false)
            #expect(dirty.error?.code == .invalidArgs && dirty.error?.message.contains("f.txt") == true, "\(dirty)")
            #expect(try await d.router.work.get(x.work)?.loop == nil)
            #expect(await d.router.appCards.isEmpty)
        }
    }

    @Test func trustedPaddockStillRefusesWhileAnotherAgentWorks() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            #expect(try await trust(d, p).ok)
            let busy = try await spawnIn(d, p, "busy", cwd: x.repo, paddock: "feat")
            try await liveProcess(d, busy.uuid).write(Data("while true; do echo tick; sleep 0.2; done\n".utf8))
            #expect(await waitFor(20) { await d.badge(busy.uuid) == .working })
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("busy") == true, "\(r)")
            #expect(try await d.router.work.get(x.work)?.loop == nil)
        }
    }

    /// Only the app turns trust on and off: an agent (the Shepherd too) is refused, and no agent command carries it.
    @Test func onlyTheAppTrustsAPaddock() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            let id = try #require(await d.router.ws.paddocks.first { $0.name == "feat" }?.id)
            let agent = try await work(d, p, x.s, "admin.paddock.trust-loops", ["paddock": .string(id.uuidString), "on": .bool(true)])
            #expect(agent.error?.code == .unauthorized, "\(agent)")
            #expect(await trusted(d) == nil)
            #expect(try await work(d, p, x.s, "paddock.status", ["name": .string("feat"), "status": .string("review"), "trustLoops": .bool(true)]).ok)
            #expect(await trusted(d) == nil)
            #expect(try await work(d, p, nil, "admin.paddock.trust-loops", ["paddock": .string(UUID().uuidString), "on": .bool(true)]).error?.code == .notFound)

            #expect(try await trust(d, p).result == .object(["paddock": .string(id.uuidString), "name": .string("feat"), "trustLoops": .bool(true)]))
            #expect(await trusted(d) == true)
            // `collie paddock status feat` shows it; setting the status keeps it
            let shown = try await work(d, p, x.s, "paddock.status", ["name": .string("feat")])
            guard case .object(let o)? = shown.result else { Issue.record("\(shown)"); return }
            #expect(o["loops"] == .string("laços sem cartão: sim") && o["status"] == .string("review"), "\(o)")
            #expect(try await work(d, p, x.s, "paddock.status", ["name": .string("feat"), "status": .string("working")]).ok)
            #expect(await trusted(d) == true)

            #expect(try await trust(d, p, on: false).result == .object(["paddock": .string(id.uuidString), "name": .string("feat"), "trustLoops": .bool(false)]))
            #expect(await trusted(d) == nil)
            guard case .object(let off)? = try await work(d, p, x.s, "paddock.status", ["name": .string("feat")]).result else { Issue.record("no paddock"); return }
            #expect(off["loops"] == nil)
        }
    }

    // MARK: B6.2 the card's "Sempre neste cercado"

    /// Permitir + always on the loop card: this loop runs and the paddock is trusted, so the next one shows no card.
    @Test func alwaysOnTheLoopCardTrustsThePaddock() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "Write done", check: "test -f done.txt")
            let agent = "bash -c 'read l; echo ok >> done.txt; git add done.txt; git commit -qm done; cat'"   // appends: the second loop commits too
            let args: [String: JSONValue] = ["command": .string(agent), "timeout": .number(60)]
            #expect(try await run(d, p, x.s, args, approve: false).ok)
            #expect(await trusted(d) == nil)
            #expect(try await answerCard(d, p, allow: true, always: true) != nil)
            #expect(await trusted(d) == true)
            #expect(await loopEnded(d, x.work))
            let w = try #require(try await d.router.work.get(x.work))
            #expect(w.tasks.first?.state == .done && w.loop?.state == .finished, "\(w.tasks) \(String(describing: w.loop))")

            try await addTask(d, p, x.s, "Again", check: "true", greenOk: true)
            let r = try await run(d, p, x.s, args, approve: false)
            guard case .object(let ran)? = r.result else { Issue.record("\(r)"); return }
            #expect(ran["state"] == .string("starting"), "\(ran)")
            #expect(await d.router.appCards.isEmpty)
            #expect(await loopEnded(d, x.work))
        }
    }

    /// Negar with always trusts nothing and nothing runs.
    @Test func alwaysWithoutAllowTrustsNothing() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true", greenOk: true)
            #expect(try await run(d, p, x.s, approve: false).ok)
            #expect(try await answerCard(d, p, allow: false, always: true) != nil)
            #expect(await waitFor(20) { await d.scrollbackText(x.s.uuid).contains("não aprovou o laço") })
            #expect(await trusted(d) == nil)
            #expect(try await d.router.work.get(x.work)?.loop == nil)
        }
    }

    /// always belongs to the loop card: on an app's card it is refused, the card stays and no paddock is trusted.
    @Test func alwaysOnAnAppCardIsRefused() async throws {
        try await withDaemon { d, p in
            _ = try await pad(d, p)
            let pid = try #require(await d.router.ws.paddocks.first { $0.name == "feat" }?.id)
            let card = AppCard(kind: .confirm, paddock: pid, paddockName: "feat", app: "notes", name: "Notas", base: nil, call: "notes.wipe", command: "wipe", by: nil)
            let answer = Task { await d.router.confirmCard(card, wait: 60) }
            #expect(await waitFor(20) { await d.router.appCards.contains { $0.id == card.id } })
            let id: JSONValue = .string(card.id.uuidString)
            let r = try await work(d, p, nil, "admin.app.answer", ["id": id, "allow": .bool(true), "always": .bool(true)])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(await d.router.appCards.contains { $0.id == card.id })
            #expect(await trusted(d) == nil)
            #expect(try await work(d, p, nil, "admin.app.answer", ["id": id, "always": .bool(true)]).error?.code == .invalidArgs)
            #expect(try await work(d, p, nil, "admin.app.answer", ["id": id, "allow": .bool(true)]).ok)
            #expect(await answer.value)
            #expect(await trusted(d) == nil)
        }
    }

    /// A record from before the field decodes (not trusted); the field survives a save.
    @Test func paddockWithoutTheTrustFieldDecodes() throws {
        let old = #"{"id":"6F1265AC-B57A-46EC-B119-51FF67B0D7A9","name":"feat","repoRoot":"/r","path":"/r/.collie/paddocks/feat","branch":"collie/feat","baseBranch":"main","status":"working"}"#
        var f = try JSONDecoder().decode(Paddock.self, from: Data(old.utf8))
        #expect(f.trustLoops == nil && f.name == "feat")
        #expect(!String(decoding: try JSONEncoder().encode(f), as: UTF8.self).contains("trustLoops"))
        f.trustLoops = true
        #expect(try JSONDecoder().decode(Paddock.self, from: try JSONEncoder().encode(f)).trustLoops == true)
        let odd = old.replacingOccurrences(of: #""status""#, with: #""trustLoops":"yes","status""#)
        #expect(try JSONDecoder().decode(Paddock.self, from: Data(odd.utf8)).trustLoops == nil)   // unreadable: the card shows
    }

    @Test func trustedNoticeListsTheTasksAndIsBounded() {
        let tasks = [WorkTask(id: "a", title: "Tela\nnova", check: "true"), WorkTask(id: "b", title: "Docs", check: "swift test")]
        #expect(WorkStatusText.loopTrusted(paddock: "feat", tasks, WorkLoopState(max: 4, budget: 600)) == """
            [collie] Laço iniciado sem cartão (cercado «feat» é confiável): 2 tarefas, --max 4, orçamento 600 s. Parar: collie work stop.
            #1 «Tela nova» check «true»
            #2 «Docs» check «swift test»
            """)
        let many = (0..<60).map { WorkTask(id: "\($0)", title: String(repeating: "x", count: 100) + " \($0)", check: "true") }
        let s = WorkStatusText.loopTrusted(paddock: "feat", many, WorkLoopState(max: 30, budget: 600)), lines = s.split(separator: "\n")
        #expect(s.count <= RerailText.limit && s.hasPrefix("[collie] Laço iniciado sem cartão (cercado «feat» é confiável): 60 tarefas"))
        #expect(lines.last == "… e mais \(60 - (lines.count - 2))", "\(lines.last ?? "")")
    }

    /// Only a terminal that can edit the loop's worktree blocks its reset.
    @Test func onlyTerminalsInTheWorktreeBlockTheLoop() {
        let dir = URL(fileURLWithPath: "/tmp/collie-wt/collie")
        func t(_ cwd: String) -> TerminalRecord { TerminalRecord(id: UUID(), name: "x", preset: .shell, command: nil, cwd: cwd, isShepherd: false) }
        #expect(CommandRouter.loopSharesWorktree(t("/tmp/collie-wt/collie"), dir))
        #expect(CommandRouter.loopSharesWorktree(t("/tmp/collie-wt/collie/Sources"), dir))
        #expect(CommandRouter.loopSharesWorktree(t("/tmp/collie-wt"), dir))   // above it: can reach it
        #expect(CommandRouter.loopSharesWorktree(t(""), dir))   // unknown: counted
        #expect(!CommandRouter.loopSharesWorktree(t("/tmp/slides"), dir))
        #expect(!CommandRouter.loopSharesWorktree(t("/tmp/collie-wt/collie-other"), dir))   // a prefix of the name is not inside
    }
}

private extension CommandRouter {
    func c5cReserve(_ p: UUID) { loopPaddocks.insert(p) }
    func c5cHold(_ h: (@Sendable () async -> Void)?) { workRunHeld = h }
}
