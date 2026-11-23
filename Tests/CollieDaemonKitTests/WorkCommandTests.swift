import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func fx(_ n: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-hooks/\(n).json")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
private func term(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let (id, r) = try await spawn(d, p, name)
    #expect(r.ok, "\(r)")
    return Term(id: id, token: try await tokenOf(d, id))
}
private func hook(_ p: Paths, _ t: Term, _ name: String, _ payload: String) async throws -> Response {
    try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "work.hook",
                              args: ["hook": .string(name), "payload": .string(payload)]))
}

@Suite(.serialized) struct WorkCommandTests {
    @Test func hookFeedsActiveWork() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("todowrite-1")).ok)
            #expect(try await hook(p, t, "tool", fx("todowrite-2")).ok)
            let w = try #require(try await d.router.work.active(terminal: t.uuid))
            #expect(w.title.hasPrefix("T — "))
            #expect(w.tasks.map(\.title) == ["Write tests", "Write parser", "Update docs"])
            #expect(w.tasks.map(\.state) == [.inProgress, .done, .abandoned])
            #expect(try await hook(p, t, "precompact", "{}").ok)
            #expect(try await d.router.work.active(terminal: t.uuid)?.notes.map(\.text) == ["Context compacted"])
        }
    }

    @Test func hookNeverFailsTheAgent() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", "not json {").ok)
            #expect(try await hook(p, t, "nonsense", fx("todowrite-1")).ok)
            #expect(try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "work.hook")).ok)
            #expect(try await hook(p, t, "session-end", "{}").ok)   // a note alone opens no work
            #expect(try await d.router.work.list(includeClosed: true).isEmpty)
        }
        // an unreadable store (there before the daemon starts) still answers ok, and is left as it is
        try await withDaemon(configure: { c in
            let dir = c.paths.root.appendingPathComponent("work")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("garbage".utf8).write(to: dir.appendingPathComponent("work.json"))
        }) { d, p in
            let dir = p.root.appendingPathComponent("work")
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("todowrite-1")).ok)
            #expect(try String(contentsOf: dir.appendingPathComponent("work.json"), encoding: .utf8) == "garbage")
        }
    }

    @Test func terminalDeathMarksJobsGone() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("agent-background")).ok)
            #expect(try await d.router.work.active(terminal: t.uuid)?.jobs.map(\.state) == [.running])
            let r = try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("T")]))
            #expect(r.ok, "\(r)")
            let w = try #require(try await d.router.work.list(includeClosed: true).first)
            #expect(w.jobs.map(\.state) == [.gone] && w.jobs.first?.endedAt != nil)
        }
    }

    @Test func silentJobsBecomeUnknown() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("bash-background")).ok)
            let w = try #require(try await d.router.work.active(terminal: t.uuid))
            // a shell whose pid is known and dead is gone at once
            let dead = Process(); dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try dead.run(); dead.waitUntilExit()
            let pid = dead.processIdentifier
            try await d.router.work.update(w.id) { $0.jobs.append(WorkJob(id: "dead", kind: .shell, label: "x", pid: pid)) }
            await d.router.sweepJobs(now: Date().addingTimeInterval(29 * 60))
            var jobs = try await d.router.work.get(w.id)?.jobs ?? []
            #expect(jobs.map(\.state) == [.running, .gone])
            await d.router.sweepJobs(now: Date().addingTimeInterval(31 * 60))
            jobs = try await d.router.work.get(w.id)?.jobs ?? []
            #expect(jobs.map(\.state) == [.unknown, .gone])
        }
    }

    @Test func unknownJobsStillFinish() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("bash-background")).ok)
            #expect(try await hook(p, t, "tool", fx("agent-background")).ok)
            await d.router.sweepJobs(now: Date().addingTimeInterval(31 * 60))
            #expect(try await d.router.work.active(terminal: t.uuid)?.jobs.map(\.state) == [.unknown, .unknown])
            #expect(try await hook(p, t, "tool", fx("bashoutput-done")).ok)
            #expect(try await hook(p, t, "subagent-stop", fx("subagent-stop")).ok)
            let jobs = try await d.router.work.active(terminal: t.uuid)?.jobs ?? []
            #expect(jobs.map(\.state) == [.finished, .finished] && jobs.allSatisfy { $0.endedAt != nil })
        }
    }

    @Test func subagentStopMatchesByAgentId() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            func states() async throws -> [JobState] { try await d.router.work.active(terminal: t.uuid)?.jobs.map(\.state) ?? [] }
            #expect(try await hook(p, t, "tool", fx("agent-background")).ok)   // alias a1b2c3
            // a sync Agent: its SubagentStop (an agent no job carries) comes before its PostToolUse
            #expect(try await hook(p, t, "subagent-stop", fx("subagent-stop-sync")).ok)
            #expect(try await states() == [.running])
            #expect(try await hook(p, t, "tool", fx("agent")).ok)
            #expect(try await states() == [.running, .finished])
            #expect(try await hook(p, t, "subagent-stop", fx("subagent-stop")).ok)
            #expect(try await states() == [.finished, .finished])
        }
    }

    @Test func subagentStopWithoutIdAndTaskStopOnAlias() {
        let now = Date()
        var w = Work(title: "w", terminalId: UUID(), jobs: [
            WorkJob(id: "u1", kind: .subagent, label: "a", startedAt: now.addingTimeInterval(-20), alias: "x1"),
            WorkJob(id: "u2", kind: .subagent, label: "b", startedAt: now.addingTimeInterval(-10), alias: "a1b2c3")])
        func run(_ hook: String, _ name: String) {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/claude-hooks/\(name).json")
            CommandRouter.apply(WorkHookParser.events(hook: hook, json: (try? Data(contentsOf: url)) ?? Data(), now: now), to: &w, now: now)
        }
        run("tool", "taskstop-agent")   // TaskStop names the agent id, not the tool_use_id
        #expect(w.jobs.map(\.state) == [.running, .finished])
        run("subagent-stop", "subagent-stop-noid")   // no agent_id: the oldest running subagent
        #expect(w.jobs.map(\.state) == [.finished, .finished])
    }

    @Test func jobSweepLeavesLoopJobs() async throws {
        try await withDaemon { d, _ in
            // a terminal that has no process: the start sweep would mark its jobs gone
            let w = try await d.router.work.start(title: "loop", terminal: UUID(), paddockId: nil, branch: nil)
            try await d.router.work.update(w.id) { $0.jobs.append(WorkJob(id: "w-t-t1", kind: .loop, label: "t")) }
            await d.router.sweepJobs(now: Date().addingTimeInterval(31 * 60))
            await d.router.jobsGoneWithoutProcess()
            #expect(try await d.router.work.get(w.id)?.jobs.map(\.state) == [.running])
        }
    }

    @Test func runningJobsGoneAfterRestart() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let dir = paths.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = Work(title: "old", terminalId: UUID(), jobs: [WorkJob(id: "a", kind: .subagent, label: "x"),
                                                             WorkJob(id: "b", kind: .shell, label: "y", state: .finished)])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode([w]).write(to: dir.appendingPathComponent("work.json"))
        let d = try Daemon(config: testConfig(paths))
        do { try await d.start() } catch { await d.stop(); throw error }
        let jobs = try await d.router.work.get(w.id)?.jobs ?? []
        await d.stop()
        #expect(jobs.map(\.state) == [.gone, .finished])
    }

    @Test func partialTaskUpdateKeepsState() {
        let now = Date()
        var w = Work(title: "w", terminalId: UUID(), tasks: [WorkTask(id: "7", title: "Old", state: .inProgress, reason: "r")])
        let rename = #"{"tool_name":"TaskUpdate","tool_use_id":"u","tool_input":{"taskId":"7","subject":"New"},"tool_response":"ok"}"#
        CommandRouter.apply(WorkHookParser.events(hook: "tool", json: Data(rename.utf8), now: now), to: &w, now: now)
        #expect(w.tasks.map(\.title) == ["New"] && w.tasks.map(\.state) == [.inProgress] && w.tasks.first?.reason == "r")
        let done = #"{"tool_name":"TaskUpdate","tool_use_id":"u","tool_input":{"taskId":"7","status":"completed"},"tool_response":"ok"}"#
        CommandRouter.apply(WorkHookParser.events(hook: "tool", json: Data(done.utf8), now: now), to: &w, now: now)
        #expect(w.tasks.map(\.title) == ["New"] && w.tasks.map(\.state) == [.done] && w.tasks.first?.reason == nil)
    }

    @Test func crashedTerminalMarksJobsGone() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            #expect(try await hook(p, t, "tool", fx("agent-background")).ok)
            try await d.process(t.uuid)?.write(Data("exit\n".utf8))   // the process ends on its own
            #expect(await waitFor(10) { (try? await d.router.work.active(terminal: t.uuid)?.jobs.map(\.state)) == [.gone] })
        }
    }

    @Test func hooksFileListsNewEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = TerminalRecord(id: UUID(), name: "A", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false)
        _ = try AgentLaunch.launchSpec(for: rec, env: [:], hooksDir: dir, collie: URL(fileURLWithPath: "/opt/collie"), shell: "/bin/zsh")
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: AgentLaunch.settingsFile(rec.id, in: dir))) as! [String: Any]
        let hooks = o["hooks"] as! [String: Any]
        func entry(_ k: String) -> [String: Any]? { (hooks[k] as? [[String: Any]])?.first }
        func command(_ k: String) -> String? { ((entry(k)?["hooks"] as? [[String: Any]])?.first?["command"] as? String) }
        #expect(entry("PostToolUse")?["matcher"] == nil)   // every tool: the chat body follows them all
        for (k, sub) in [("PostToolUse", "claude-tool"), ("SubagentStop", "claude-subagent-stop"),
                         ("PreCompact", "claude-precompact"), ("SessionEnd", "claude-session-end")] {
            #expect(command(k) == "'/opt/collie' hook \(sub)", "\(k)")
            #expect((entry(k)?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == (k == "PostToolUse" ? 8 : 5))
        }
        #expect(command("Stop")?.hasSuffix("hook claude-stop") == true)   // the existing ones stay
    }
}

// MARK: collie work …

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// `t` nil: the app (admin token).
private func work(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: String] = [:], flags: [String] = []) async throws -> Response {
    var a = args.mapValues { JSONValue.string($0) }
    for f in flags { a[f] = .bool(true) }
    return try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: a), timeoutSeconds: 60)
}
private func gitIn(_ dir: URL, _ args: String...) async throws {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
}
/// A repo whose commits are all from an earlier second than a work opened next (commits since the work's second count).
private func freshRepo() async throws -> URL {
    let r = try await makeRepo()
    try await Task.sleep(for: .milliseconds(1100))
    return r
}
private func turnEnd(_ p: Paths, _ t: Term) async throws {
    let r = try await send(p, Request(id: "t", terminalId: t.id, token: t.token, command: "turn.completed", args: ["source": .string("claude")]))
    #expect(r.ok, "\(r)")
}

extension WorkCommandTests {
    @Test func commandsFollowLeashes() async throws {
        try await withDaemon { d, p in
            let tmp = URL(fileURLWithPath: "/tmp")
            let a = try await spawnIn(d, p, "A", cwd: tmp), b = try await spawnIn(d, p, "B", cwd: tmp)
            let m = try await spawnIn(d, p, "M", cwd: tmp, shepherd: true)
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("M"), "b": .string("A")])).ok)
            let s = try await work(d, p, a, "work.start", ["title": "Feature A"])
            guard case .object(let o)? = s.result, case .string(let id)? = o["id"] else { Issue.record("\(s)"); return }
            // B has no leash: A looks exactly like a terminal that does not exist
            let hidden = try await work(d, p, b, "work.status", ["terminal": "A"])
            let missing = try await work(d, p, b, "work.status", ["terminal": "Nobody"])
            #expect(hidden.error?.code == .notFound && missing.error?.code == .notFound)
            #expect(hidden.error?.message == "Terminal 'A' not found" && missing.error?.message == "Terminal 'Nobody' not found")
            #expect(try await work(d, p, b, "work.task.add", ["title": "x", "terminal": "A"]).error?.code == .notFound)
            #expect(try await work(d, p, b, "work.get", ["id": id]).error?.code == .notFound)
            #expect(try await work(d, p, b, "work.done", ["terminal": "A"]).error?.code == .notFound)
            guard case .array(let rows)? = try await work(d, p, b, "work.list", flags: ["closed"]).result else { Issue.record("list"); return }
            #expect(rows.isEmpty)
            // the Shepherd reaches A, not B
            #expect(try await work(d, p, m, "work.task.add", ["title": "Write tests", "terminal": "A"]).ok)
            #expect(try await work(d, p, m, "work.get", ["id": id]).ok)
            #expect(try await work(d, p, m, "work.status", ["terminal": "B"]).error?.message == "Terminal 'B' not found")
            guard case .array(let mrows)? = try await work(d, p, m, "work.list").result else { Issue.record("list"); return }
            #expect(mrows.count == 1)
            // the app reaches everyone; clear-history is the app's alone
            #expect(try await work(d, p, nil, "work.note", ["text": "from the app", "terminal": "B"]).ok)
            #expect(try await work(d, p, nil, "work.done", ["terminal": "A", "reason": "shipped"]).ok)
            #expect(try await work(d, p, a, "work.clear-history").error?.code == .unauthorized)
            let w = try #require(try await d.router.work.get(UUID(uuidString: id)!))
            #expect(w.tasks.map(\.title) == ["Write tests"] && w.closedBy == "app" && w.notes.last?.text == "Done: shipped")
            #expect(try await d.router.work.active(terminal: b.uuid)?.notes.map(\.text) == ["from the app"])
            #expect(try await work(d, p, a, "work.reopen").ok)
            #expect(try await d.router.work.active(terminal: a.uuid)?.id.uuidString.lowercased() == id)
            #expect(try await work(d, p, nil, "work.done", ["terminal": "A"]).ok)
            #expect(try await work(d, p, nil, "work.clear-history").ok)
            #expect(try await d.router.work.get(UUID(uuidString: id)!) == nil)
            // the status text names the work and its open tasks
            #expect(try await work(d, p, b, "work.task.add", ["title": "Ship it"]).ok)
            guard case .object(let st)? = try await work(d, p, b, "work.status").result, case .string(let out)? = st["output"] else { Issue.record("status"); return }
            #expect(out.contains("Ship it") && out.contains("from the app"), "\(out)")
        }
    }

    @Test func deferAndDropNeedReason() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: URL(fileURLWithPath: "/tmp"))
            #expect(try await work(d, p, a, "work.start", ["title": "w"]).ok)
            for t in ["One", "Two", "Three"] { #expect(try await work(d, p, a, "work.task.add", ["title": t]).ok) }
            for c in ["work.task.defer", "work.task.drop"] {
                #expect(try await work(d, p, a, c, ["task": "One"]).error?.code == .invalidArgs)
                #expect(try await work(d, p, a, c, ["task": "One", "reason": "  "]).error?.code == .invalidArgs)
            }
            #expect(try await work(d, p, a, "work.task.defer", ["task": "one", "reason": "waits for the API"]).ok)
            #expect(try await work(d, p, a, "work.task.drop", ["task": "Two", "reason": "not needed"]).ok)
            #expect(try await work(d, p, a, "work.task.done", ["task": "Three"]).ok)
            #expect(try await work(d, p, a, "work.task.done", ["task": "Four"]).error?.code == .notFound)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            #expect(w.tasks.map(\.state) == [.deferred, .abandoned, .done])
            #expect(w.tasks.map(\.reason) == ["waits for the API", "not needed", nil])
        }
    }

    @Test func landClosesPaddockWork() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await work(d, p, m, "paddock.create", ["name": "feat"]).ok)
            let dev = try await spawnIn(d, p, "dev", cwd: repo, paddock: "feat")
            #expect(try await work(d, p, dev, "work.start", ["title": "Feat"]).ok)
            let w = try #require(try await d.router.work.active(terminal: dev.uuid))
            #expect(w.branch == "collie/feat")
            try await commit("g.txt", "two\n", in: repo.appendingPathComponent(".collie/paddocks/feat"))
            let l = try await work(d, p, m, "paddock.land", ["name": "feat"])
            #expect(l.ok, "\(l)")
            let after = try #require(try await d.router.work.get(w.id))
            #expect(after.closedBy == "merge" && after.closedAt != nil)
        }
    }

    @Test func ancestorCheckClosesOnStop() async throws {
        let repo = try await freshRepo()
        try await withDaemon { d, p in
            let t = try await spawnIn(d, p, "T", cwd: repo)
            #expect(try await work(d, p, t, "work.start", ["title": "Side", "branch": "side"]).ok)
            let w = try #require(try await d.router.work.active(terminal: t.uuid))
            try await gitIn(repo, "branch", "side")
            try await turnEnd(p, t)   // the branch has nothing since the work opened: not closed
            try await gitIn(repo, "checkout", "-q", "side")
            try await commit("s.txt", "side\n", in: repo)
            try await gitIn(repo, "checkout", "-q", "main")
            try await commit("m.txt", "main\n", in: repo)   // a commit on HEAD shows the Stop pass ran
            try await turnEnd(p, t)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.commits.count) == 1 })
            #expect(try await d.router.work.get(w.id)?.closedAt == nil)
            try await gitIn(repo, "merge", "-q", "--no-ff", "--no-edit", "side")
            try await turnEnd(p, t)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.closedBy) == "merge" })
        }
    }

    @Test func pastureWorkNeverAutoCloses() async throws {
        let repo = try await freshRepo()
        try await withDaemon { d, p in
            let t = try await spawnIn(d, p, "T", cwd: repo), s = try await spawnIn(d, p, "S", cwd: repo)
            #expect(try await work(d, p, t, "work.start", ["title": "Pasture"]).ok)
            #expect(try await work(d, p, s, "work.start", ["title": "Side", "branch": "side"]).ok)
            let w = try #require(try await d.router.work.active(terminal: t.uuid))
            let side = try #require(try await d.router.work.active(terminal: s.uuid))
            #expect(w.branch == nil)
            try await gitIn(repo, "checkout", "-q", "-b", "side")
            try await commit("x.txt", "x\n", in: repo)
            try await gitIn(repo, "checkout", "-q", "main")
            try await turnEnd(p, s)
            #expect(await waitFor(10) { (try? await d.router.work.get(side.id)?.commits.count) == 1 })
            try await gitIn(repo, "merge", "-q", "--no-ff", "--no-edit", "side")   // a side branch merged under the pasture work
            try await turnEnd(p, t)
            try await turnEnd(p, s)
            #expect(await waitFor(10) { (try? await d.router.work.get(side.id)?.closedBy) == "merge" })
            try await Task.sleep(for: .milliseconds(300))
            let after = try #require(try await d.router.work.get(w.id))
            #expect(after.closedAt == nil && after.commits.isEmpty, "\(after)")   // nothing on the pasture is known to be its own
        }
    }

    @Test func commitsTracked() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await work(d, p, m, "paddock.create", ["name": "feat"]).ok)
            let dev = try await spawnIn(d, p, "dev", cwd: repo, paddock: "feat")
            let paddock = repo.appendingPathComponent(".collie/paddocks/feat")
            #expect(try await work(d, p, dev, "work.start", ["title": "C"]).ok)
            let w = try #require(try await d.router.work.active(terminal: dev.uuid))
            try await commit("a.txt", "a\n", in: paddock)
            try await turnEnd(p, dev)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.commits.count) == 1 })
            try await commit("b.txt", "b\n", in: paddock)
            try await turnEnd(p, dev)
            try await turnEnd(p, dev)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.commits.count) == 2 })
            try await Task.sleep(for: .milliseconds(300))
            let commits = try #require(try await d.router.work.get(w.id)?.commits)
            #expect(commits.count == 2 && commits[0].hasSuffix(" edit a.txt") && commits[1].hasSuffix(" edit b.txt"), "\(commits)")
        }
    }

    @Test func syncedPaddockIsNotMerged() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await work(d, p, m, "paddock.create", ["name": "feat"]).ok)
            let dev = try await spawnIn(d, p, "dev", cwd: repo, paddock: "feat")
            let paddock = repo.appendingPathComponent(".collie/paddocks/feat")
            #expect(try await work(d, p, dev, "work.start", ["title": "Feat"]).ok)
            let w = try #require(try await d.router.work.active(terminal: dev.uuid))
            try await commit("other.txt", "someone else\n", in: repo)   // on main, after the work opened
            try await gitIn(paddock, "merge", "-q", "--ff-only", "main")   // the paddock fast-forwarded to it
            try await turnEnd(p, dev)
            try await commit("mine.txt", "mine\n", in: paddock)   // a later turn's own commit shows the first pass ran
            try await turnEnd(p, dev)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.commits.count) == 1 })
            let now = try #require(try await d.router.work.get(w.id))
            #expect(now.closedAt == nil && now.commits.first?.hasSuffix(" edit mine.txt") == true, "\(now)")
            try await gitIn(repo, "merge", "-q", "--no-ff", "--no-edit", "collie/feat")   // its own commit merged
            try await turnEnd(p, dev)
            #expect(await waitFor(10) { (try? await d.router.work.get(w.id)?.closedBy) == "merge" })
        }
    }

    @Test func removedTerminalClosesItsWork() async throws {
        try await withDaemon { d, p in
            let tmp = URL(fileURLWithPath: "/tmp")
            let a = try await spawnIn(d, p, "A", cwd: tmp), b = try await spawnIn(d, p, "B", cwd: tmp)
            #expect(try await work(d, p, a, "work.start", ["title": "Kept"]).ok)
            let kept = try #require(try await d.router.work.active(terminal: a.uuid))
            // a relaunch (same terminal) keeps it open
            let u = try await send(p, Request(id: "u", token: d.adminToken, command: "admin.update",
                                              args: ["name": .string("A"), "restart": .bool(true)]), timeoutSeconds: 60)
            #expect(u.ok, "\(u)")
            #expect(try await d.router.work.get(kept.id)?.closedAt == nil)
            let k = try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("A")]))
            #expect(k.ok, "\(k)")
            #expect(try await d.router.work.get(kept.id)?.closedBy == "removed")
            // reversible; then closed by id, the app's alone (no terminal reaches it any more)
            let id = kept.id.uuidString.lowercased()
            #expect(try await work(d, p, nil, "work.reopen", ["id": id]).ok)
            #expect(try await work(d, p, b, "work.done", ["id": id]).error?.code == .notFound)
            #expect(try await work(d, p, nil, "work.done", ["id": id, "reason": "orphan"]).ok)
            let w = try #require(try await d.router.work.get(kept.id))
            #expect(w.closedBy == "app" && w.notes.last?.text == "Done: orphan")
            #expect(try await work(d, p, nil, "work.done", ["id": id]).error?.code == .invalidArgs)   // already closed
        }
    }

    @Test func branchIsValidated() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: URL(fileURLWithPath: "/tmp"))
            for bad in ["HEAD", "a..b", "-x", "a b", "@{-1}", "x.lock"] {
                #expect(try await work(d, p, a, "work.start", ["title": "w", "branch": bad]).error?.code == .invalidArgs, "\(bad)")
            }
            #expect(try await work(d, p, a, "work.start", ["title": "w", "branch": "feat/x"]).ok)
        }
    }

    @Test func sessionContextMentionsWorkCommands() async throws {
        try await withDaemon { d, p in
            let t = try await spawnIn(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            let r = try await work(d, p, t, "memory.hookContext")
            guard case .object(let o)? = r.result, case .string(let s)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(s.contains("collie work task defer") && s.contains("collie work done"))
        }
    }
}

/// F2 R1: `work task add --agent --model` and `work run --review --personas --reviewer-model`: recorded, shown, validated.
extension WorkCommandTests {
    @Test func taskAddKeepsItsWorkerAndShowsIt() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: URL(fileURLWithPath: "/tmp"))
            #expect(try await work(d, p, a, "work.task.add", ["title": "T1", "agent": "codex", "model": "gpt-5"]).ok)
            #expect(try await work(d, p, a, "work.task.add", ["title": "T2"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            #expect(w.tasks.map(\.agent) == ["codex", nil] && w.tasks.map(\.model) == ["gpt-5", nil])
            guard case .object(let g)? = try await work(d, p, a, "work.get", ["id": w.id.uuidString]).result,
                  case .array(let ts)? = g["tasks"], case .object(let t1)? = ts.first else { Issue.record("get"); return }
            #expect(t1["agent"] == .string("codex") && t1["model"] == .string("gpt-5"))
            guard case .object(let s)? = try await work(d, p, a, "work.status").result, case .string(let out)? = s["output"] else { Issue.record("status"); return }
            #expect(out.contains("T1 (agente codex, modelo gpt-5) [") && out.contains("  - T2 ["), "\(out)")
            // unknown agent or model: invalidArgs, nothing added
            #expect(try await work(d, p, a, "work.task.add", ["title": "T3", "agent": "gemini"]).error?.code == .invalidArgs)
            #expect(try await work(d, p, a, "work.task.add", ["title": "T3", "model": "no model; rm"]).error?.code == .invalidArgs)
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.count == 2)
        }
    }

    /// F2 X4: `--review` with no persona committed at HEAD is refused at launch, before any agent is spent.
    @Test func runReviewWithoutCatalogIsRefused() async throws {
        let repo = try await makeRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs/fabrica/personas"), withIntermediateDirectories: true)
        try "# Fake\n".write(to: repo.appendingPathComponent("docs/fabrica/personas/correcao.md"), atomically: true, encoding: .utf8)   // not committed
        for personas in [nil, "auto", "correcao"] {
            do {
                _ = try await CommandRouter.loopReview(review: true, personas: personas, reviewerModel: nil, dir: repo)
                Issue.record("accepted \(String(describing: personas))")
            } catch {
                #expect(error.code == .invalidArgs && error.message.contains("sem personas em docs/fabrica/personas"), "\(error)")
            }
        }
        // without --review nothing changes
        #expect(try await CommandRouter.loopReview(review: false, personas: nil, reviewerModel: nil, dir: repo) == (false, nil, nil))
    }

    /// F2 V4: a loop reviewer's sandbox denial raises no card (counted only, as an open terminal's); an ordinary terminal's does.
    @Test func reviewerDenialRaisesNoCard() async throws {
        let repo = try await makeRepo()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("v4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await withDaemon { d, p in
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true)
            let r = Request(id: "loop", terminalId: s.id, command: "summon", args: ["name": .string("w-a-t1-correcao-rev"), "preset": .string("shell")])
            let rev = try await d.router.loopSummon(r, as: s.uuid, scratch: scratch)
            let other = try await spawnIn(d, p, "O", cwd: repo)
            let path = repo.appendingPathComponent("x.txt").path
            await d.router.raiseForTests(SandboxDenial(terminal: rev, op: "write", path: path))
            await d.router.raiseForTests(SandboxDenial(terminal: other.uuid, op: "write", path: path))
            // F4 2: a lane (strict, no reviewer) keeps today's way: its denial is a card too
            let pad = Paddock(id: UUID(), name: "p", repoRoot: repo.path, path: repo.path, branch: "collie/p", baseBranch: "main")
            await d.router.f4AddPaddock(pad)
            let lanePath = scratch.appendingPathComponent("paddocks/lane-v4-a").path
            let lane = TerminalRecord(id: UUID(), name: "w-a-t1", preset: .shell, command: nil, cwd: lanePath, isShepherd: false,
                                      paddockId: pad.id, projectRoot: lanePath)
            await d.router.f4AddTerminal(lane)
            #expect(await d.router.lanePaddock(of: lane) != nil)
            await d.router.raiseForTests(SandboxDenial(terminal: lane.id, op: "write", path: lanePath + "/y.txt"))
            let cards = await d.router.accessCards
            #expect(cards.cards.keys.allSatisfy { $0.terminal != rev }, "the reviewer's denial made a card")
            #expect(cards.silent[rev] == 1)
            // F4 2: fails if `raise` hushed every terminal while a reviewer stands
            #expect(cards.cards.keys.contains { $0.terminal == other.uuid }, "the ordinary terminal's denial made no card")
            #expect(cards.silent[other.uuid] == nil)
            #expect(cards.cards.keys.contains { $0.terminal == lane.id }, "the lane's denial made no card")
            #expect(cards.silent[lane.id] == nil)
            await d.router.loopDismiss(rev)
        }
    }

    /// F4 1: a loop reviewer's `access.request` is not shown (its denials are hushed, V4): `shown: false`, its own message.
    @Test func reviewerAccessRequestIsNotShown() async throws {
        let repo = try await makeRepo()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("f4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await withDaemon { d, p in
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true)
            let r = Request(id: "loop", terminalId: s.id, command: "summon", args: ["name": .string("w-a-t1-correcao-rev"), "preset": .string("shell")])
            let rev = try await d.router.loopSummon(r, as: s.uuid, scratch: scratch)
            let t = Term(id: rev.uuidString, token: try await tokenOf(d, rev.uuidString))
            let res = try await work(d, p, t, "access.request", ["path": repo.appendingPathComponent("x.txt").path], flags: ["write"])
            guard case .object(let o)? = res.result else { Issue.record("\(res)"); return }
            #expect(o["shown"] == .bool(false))
            #expect(o["message"] == .string(CommandRouter.reviewerAccessMessage))
            #expect(await d.router.accessCards.cards.isEmpty)
            await d.router.loopDismiss(rev)
        }
    }

    /// F2 X4: a reviewer is marked inside its summon (before the launch), so it never stands unmarked in the paddock;
    /// a dismiss unmarks it.
    @Test func reviewerIsMarkedByItsSummon() async throws {
        let repo = try await makeRepo()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("x4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await withDaemon { d, p in
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true)
            let r = Request(id: "loop", terminalId: s.id, command: "summon", args: ["name": .string("w-a-t1-correcao-rev"), "preset": .string("shell")])
            let id = try await d.router.loopSummon(r, as: s.uuid, scratch: scratch)
            #expect(await d.router.loopReviewers.contains(id))
            await d.router.loopDismiss(id)
            #expect(await !d.router.loopReviewers.contains(id))
            // a refused summon (the name is taken) leaves no mark behind
            let before = await d.router.loopReviewers
            await #expect(throws: ProtocolError.self) {
                _ = try await d.router.loopSummon(Request(id: "loop", terminalId: s.id, command: "summon", args: ["name": .string("S"), "preset": .string("shell")]),
                                                  as: s.uuid, scratch: scratch)
            }
            #expect(await d.router.loopReviewers == before)
        }
    }

    @Test func runReviewFlagsAreValidatedAgainstTheCommittedPersonas() async throws {
        let repo = try await makeRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs/fabrica/personas"), withIntermediateDirectories: true)
        try await commit("docs/fabrica/personas/correcao.md", "# Correção\n", in: repo)
        try "# Fake\n".write(to: repo.appendingPathComponent("docs/fabrica/personas/fake.md"), atomically: true, encoding: .utf8)   // not committed
        // pure: without --review, off; with it, auto or the names; the worktree's persona is no persona
        #expect(try await CommandRouter.loopReview(review: false, personas: nil, reviewerModel: nil, dir: repo) == (false, nil, nil))
        #expect(try await CommandRouter.loopReview(review: true, personas: nil, reviewerModel: nil, dir: repo) == (true, nil, nil))
        #expect(try await CommandRouter.loopReview(review: true, personas: "auto", reviewerModel: "opus", dir: repo) == (true, nil, "opus"))
        #expect(try await CommandRouter.loopReview(review: true, personas: "correcao", reviewerModel: nil, dir: repo) == (true, ["correcao"], nil))
        for (review, personas, model) in [(false, "auto", nil), (false, nil, "opus"), (true, "fake", nil), (true, "correcao,nope", nil),
                                          (true, "../x", nil), (true, "", nil), (true, nil, "bad model")] as [(Bool, String?, String?)] {
            await #expect(throws: ProtocolError.self, "\(review) \(String(describing: personas)) \(String(describing: model))") {
                _ = try await CommandRouter.loopReview(review: review, personas: personas, reviewerModel: model, dir: repo)
            }
        }
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await work(d, p, m, "paddock.create", ["name": "feat"]).ok)
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
            #expect(try await work(d, p, s, "work.start", ["title": "Loop work"]).ok)
            #expect(try await work(d, p, s, "work.task.add", ["title": "A", "check": "true"]).ok)
            let base = ["max": "3", "command": "true"]
            #expect(try await work(d, p, s, "work.run", base.merging(["personas": "correcao"]) { $1 }).error?.code == .invalidArgs)
            #expect(try await work(d, p, s, "work.run", base.merging(["reviewer-model": "opus"]) { $1 }).error?.code == .invalidArgs)
            #expect(try await work(d, p, s, "work.run", base.merging(["personas": "nope"]) { $1 }, flags: ["review"]).error?.code == .invalidArgs)
            // F2 A3: a test daemon sandboxes no terminal (open mode) and --review runs all the same: it waits for its card
            #expect(try await work(d, p, s, "work.run", base.merging(["personas": "correcao", "reviewer-model": "opus"]) { $1 }, flags: ["review"]).ok)
            // the card's text with the review (what a strict daemon's card shows)
            let w = try #require(try await d.router.work.active(terminal: s.uuid))
            let call = CommandRouter.loopCardText(w, w.tasks, WorkLoopState(state: .running, tries: 3, timeout: 3600, max: 3, used: 0, budget: 14_400,
                                                                            spent: 0, tasks: w.tasks.map(\.id), review: true, personas: ["correcao"], reviewerModel: "opus"),
                                                  paddock: "feat")
            #expect(call?.contains("revisão por personas: «correcao», revisor «opus».") == true, "\(String(describing: call))")
            // what the loop's state holds is what status shows
            let id = w.id
            try await d.router.work.update(id) { $0.loop = WorkLoopState(state: .stopped, tasks: [], review: true, reviewerModel: "opus") }
            guard case .object(let o)? = try await work(d, p, s, "work.status").result, case .string(let out)? = o["output"] else { Issue.record("status"); return }
            #expect(out.contains("revisão: ligada, personas auto, revisor opus"), "\(out)")
            try await d.router.work.update(id) { $0.loop?.personas = ["correcao", "testes"]; $0.loop?.reviewerModel = nil }
            guard case .object(let o2)? = try await work(d, p, s, "work.status").result, case .string(let out2)? = o2["output"] else { Issue.record("status"); return }
            #expect(out2.contains("revisão: ligada, personas correcao, testes\n"), "\(out2)")
        }
    }
}

private extension CommandRouter { func f4AddPaddock(_ p: Paddock) { ws.paddocks.append(p) } func f4AddTerminal(_ t: TerminalRecord) { ws.terminals.append(t) } }
