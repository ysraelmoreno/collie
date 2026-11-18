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
    private func addTask(_ d: Daemon, _ p: Paths, _ t: Term, _ title: String, check: String?) async throws {
        var a: [String: JSONValue] = ["title": .string(title)]
        if let check { a["check"] = .string(check) }
        let r = try await work(d, p, t, "work.task.add", a)
        #expect(r.ok, "\(r)")
    }
    /// `work.run` (with `--max 3` unless given); `approve`: the owner answers its card Permitir once it shows.
    private func run(_ d: Daemon, _ p: Paths, _ t: Term, _ args: [String: JSONValue] = [:], approve: Bool = true) async throws -> Response {
        var a = args
        if a["max"] == nil { a["max"] = .number(3) }
        let r = try await work(d, p, t, "work.run", a)
        if r.ok && approve { #expect(try await answerCard(d, p, allow: true) != nil, "no approval card") }
        return r
    }
    private func answerCard(_ d: Daemon, _ p: Paths, allow: Bool) async throws -> AppCard? {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let c = await d.router.appCards.first(where: { $0.app == "work-loop" }) {
                let r = try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                                  args: ["id": .string(c.id.uuidString), "allow": .bool(allow)]))
                #expect(r.ok, "\(r)")
                return c
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
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
            try await d.process(busy.uuid)!.write(Data("while true; do echo tick; sleep 0.2; done\n".utf8))
            #expect(await waitFor(20) { await d.badge(busy.uuid) == .working })
            let r = try await run(d, p, x.s, approve: false)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("busy") == true, "\(r)")
        }
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
            #expect(await d.router.ws.terminals.allSatisfy { !$0.name.hasPrefix("loop-") })
            #expect(await waitFor(20) { await d.scrollbackText(x.s.uuid).contains("[collie] Laço de \"Loop work\" terminou: 1 feitas, 0 adiadas") })
        }
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

    /// Finding 7: --max is required and every limit has a hard ceiling.
    @Test func runNeedsMaxAndHardCaps() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await addTask(d, p, x.s, "A", check: "true")
            let none = try await work(d, p, x.s, "work.run")
            #expect(none.error?.code == .invalidArgs && none.error?.message.contains("--max") == true, "\(none)")
            for (k, v) in [("max", 31.0), ("timeout", 14_401), ("budget", 43_201), ("tries", 11)] {
                var a: [String: JSONValue] = ["max": .number(3)]; a[k] = .number(v)
                #expect(try await work(d, p, x.s, "work.run", a).error?.code == .invalidArgs, "\(k)")
            }
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
            #expect(await d.router.ws.terminals.allSatisfy { !$0.name.hasPrefix("loop-") })
            // the reservation is released: a new run asks again
            #expect(try await run(d, p, x.s, [:], approve: false).ok)
            #expect(try await answerCard(d, p, allow: false) != nil)
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
            #expect(await waitFor(20) { await d.router.ws.terminals.filter { $0.name.hasPrefix("loop-") }.count <= 1 })
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
            let left = try await spawnIn(d, p, "loop-a-1", cwd: URL(fileURLWithPath: "/tmp"))
            let other = try await spawnIn(d, p, "loop-zz-9", cwd: URL(fileURLWithPath: "/tmp"))   // not this work's
            let w = try await d.router.work.start(title: "looping", terminal: UUID(), paddockId: nil, branch: nil)
            try await d.router.work.update(w.id) {
                $0.tasks = [WorkTask(id: "a", title: "A", state: .inProgress, check: "true")]
                $0.jobs = [WorkJob(id: "loop-a-1", kind: .loop, label: "A")]
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
                     jobs: [WorkJob(id: "loop-a-1", kind: .loop, label: "A")])
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
}
