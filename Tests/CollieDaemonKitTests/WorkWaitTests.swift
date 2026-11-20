import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp")]
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }

/// A flag a waiting task raises when it returns: the test reads it without a clock.
private actor Flag {
    private(set) var up = 0
    func raise() { up += 1 }
}

/// Lets other tasks run until `done` holds (bounded: a wait that never parks fails the test instead of hanging it).
private func until(_ done: () async -> Bool) async -> Bool {
    for _ in 0..<100_000 { if await done() { return true }; await Task.yield() }
    return false
}

/// M2.3: the work's version, the wait on it (`WorkStore.changed`, `work.wait`) and the loop's line with its times.
@Suite struct WorkWaitTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-wait-\(UUID().uuidString.prefix(8))") }
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-20 14:03:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_795_183_380)

    // MARK: the store's version

    @Test func versionRisesWithEachChangeAndOnlyThen() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        let other = try await s.start(title: "B", terminal: UUID(), paddockId: nil, branch: nil)
        #expect(try await s.version(w.id) == 1)
        try await s.update(w.id) { $0.notes.append(WorkNote(text: "one")) }
        #expect(try await s.version(w.id) == 2)
        try await s.update(w.id) { _ in }   // nothing changes
        try await s.update(w.id) { $0.title = "A" }   // the same value
        #expect(try await s.version(w.id) == 2)
        try await s.update(w.id) { $0.loop = WorkLoopState(task: "a", attempt: 1) }
        try await s.update(w.id) { $0.loop?.record(LoopEvent(kind: .attemptStarted, task: "a", attempt: 1)) }
        #expect(try await s.version(w.id) == 4)
        #expect(try await s.version(other.id) == 1, "another work's change is not this one's")
        #expect(try await s.version(UUID()) == nil)
        // kept on disk: a new store (a daemon restart) goes on from it
        let again = WorkStore(dir: dir)
        #expect(try await again.version(w.id) == 4)
        try await again.update(w.id) { $0.notes.append(WorkNote(text: "two")) }
        #expect(try await again.version(w.id) == 5)
        #expect(try await again.get(w.id)?.version == 5)
    }

    @Test func aWorkWrittenBeforeVersionsDecodesAndCountsFromZero() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let json = #"{"id":"\#(UUID().uuidString)","title":"old","terminalId":"\#(UUID().uuidString)","openedAt":"2026-11-20T14:03:00Z","tasks":[],"jobs":[],"notes":[],"commits":[],"loop":{"state":"running","attempt":1,"tries":3,"timeout":60,"used":1,"phase":"agent","startedAt":"2026-11-20T14:03:00Z"}}"#
        let w = try d.decode(Work.self, from: Data(json.utf8))
        #expect(w.version == nil && w.loop?.phase == .agent && w.loop?.phaseSince == nil)
        var bad = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        bad["version"] = "many"
        var loop = try #require(bad["loop"] as? [String: Any]); loop["phaseSince"] = 7.5; bad["loop"] = loop
        let b = try d.decode(Work.self, from: JSONSerialization.data(withJSONObject: bad))
        #expect(b.version == nil && b.loop != nil && b.loop?.phaseSince == nil, "a malformed new field is nil, the loop survives")
    }

    @Test func waitingOnTheCurrentVersionBlocksUntilTheNextUpdate() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        let other = try await s.start(title: "B", terminal: UUID(), paddockId: nil, branch: nil)
        let back = Flag()
        let wait = Task { let v = try await s.changed(w.id, since: 1); await back.raise(); return v }
        #expect(await until { await s.changeWaiterCount == 1 }, "the wait parks")
        try await s.update(other.id) { $0.notes.append(WorkNote(text: "not this work")) }
        try await s.update(w.id) { _ in }   // no change: nobody wakes
        for _ in 0..<50 { await Task.yield() }
        let returned = await back.up, parked = await s.changeWaiterCount
        #expect(returned == 0 && parked == 1, "still waiting")
        try await s.update(w.id) { $0.notes.append(WorkNote(text: "woke")) }
        #expect(try await wait.value == 2)
        #expect(await s.changeWaiterCount == 0)
    }

    @Test func waitingOnAnOldVersionReturnsAtOnce() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) { $0.notes.append(WorkNote(text: "one")) }
        #expect(try await s.changed(w.id, since: 0) == 2)
        #expect(try await s.changed(w.id, since: 1) == 2)
        #expect(try await s.changed(UUID(), since: 0) == nil, "no such work: nothing to wait for")
        #expect(await s.changeWaiterCount == 0)
    }

    @Test func everyWaiterWakes() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        let waits = (0..<5).map { _ in Task { try await s.changed(w.id, since: 1) } }
        #expect(await until { await s.changeWaiterCount == 5 })
        try await s.update(w.id) { $0.tasks.append(WorkTask(id: "1", title: "x")) }
        for t in waits { #expect(try await t.value == 2) }
        #expect(await s.changeWaiterCount == 0)
    }

    @Test func aWorkThatGoesAwayWakesItsWaiters() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.close(w.id, by: "app")
        let wait = Task { try await s.changed(w.id, since: 2) }
        #expect(await until { await s.changeWaiterCount == 1 })
        try await s.clearHistory()
        #expect(try await wait.value == nil)
    }

    @Test func aCancelledWaitLeavesNoContinuation() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), paddockId: nil, branch: nil)
        let wait = Task { try await s.changed(w.id, since: 1) }
        #expect(await until { await s.changeWaiterCount == 1 })
        wait.cancel()
        #expect(try await wait.value == 1, "cancelled: it returns the version it has, unchanged")
        #expect(await s.changeWaiterCount == 0)
        // cancelled before it ever parks: the same
        let early = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await s.changed(w.id, since: 1)
        }
        #expect(try await early.value == 1)
        #expect(await s.changeWaiterCount == 0)
        // and a later update finds nobody to resume twice
        try await s.update(w.id) { $0.notes.append(WorkNote(text: "after")) }
        #expect(try await s.version(w.id) == 2)
    }

    // MARK: work.wait

    @Test func waitWithoutSinceAnswersAtOnceWithTheStatusAndTheVersion() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            #expect(try await call(p, a, "work.wait").error?.code == .notFound, "no active work")
            #expect(try await call(p, a, "work.start", ["title": "Feature"]).ok)
            #expect(try await call(p, a, "work.task.add", ["title": "Ship it"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            let r = try await call(p, a, "work.wait")
            let o = obj(r)
            let v = try #require(w.version)
            #expect(r.ok && o["version"] == .number(Double(v)) && o["timedOut"] == .bool(false) && o["ended"] == .bool(false))
            // the same JSON as work status
            let st = obj(try await call(p, a, "work.status"))
            #expect(o["works"] == st["works"] && o["works"] != nil)
            guard case .string(let out)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(out == "sem laço: Feature\nversão \(w.version ?? -1)")
            for bad: JSONValue in [.number(-1), .number(1.5), .string("soon"), .bool(true)] {
                #expect(try await call(p, a, "work.wait", ["since": bad]).error?.code == .invalidArgs, "\(bad)")
            }
            #expect(try await call(p, a, "work.wait", ["timeout": .number(3601)]).error?.code == .invalidArgs)
        }
    }

    @Test func waitAnswersWhenTheWorkChangesPastSince() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            #expect(try await call(p, a, "work.start", ["title": "Feature"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid)), v = try #require(w.version)
            let store = d.router.work
            // an old --since: at once
            #expect(obj(try await call(p, a, "work.wait", ["since": .number(0)]))["version"] == .number(Double(v)))
            // the current one: parked until the next change (no clock: the update wakes it)
            let wait = Task { try await call(p, a, "work.wait", ["since": .number(Double(v)), "timeout": .number(3600)]) }
            #expect(await until { await store.changeWaiterCount == 1 })
            try await store.update(w.id) { $0.notes.append(WorkNote(text: "changed")) }
            let o = obj(try await wait.value)
            #expect(o["version"] == .number(Double(v + 1)) && o["timedOut"] == .bool(false) && o["ended"] == .bool(false))
            #expect(await store.changeWaiterCount == 0)
            // a string version (a CLI that sends words) is a version too
            #expect(obj(try await call(p, a, "work.wait", ["since": .string("\(v)")]))["version"] == .number(Double(v + 1)))
        }
    }

    @Test func waitTimesOutWithTimedOutAndTheSameVersion() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            #expect(try await call(p, a, "work.start", ["title": "Feature"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid)), v = try #require(w.version)
            try await d.router.work.update(w.id) { x in
                x.tasks.append(WorkTask(id: "a", title: "Task a", state: .inProgress))
                x.loop = WorkLoopState(task: "a", attempt: 1); x.loop?.show(.check)
            }
            let r = try await call(p, a, "work.wait", ["since": .number(Double(v + 1)), "timeout": .number(1)])
            let o = obj(r)
            #expect(r.ok && o["timedOut"] == .bool(true) && o["ended"] == .bool(false) && o["version"] == .number(Double(v + 1)))
            guard case .string(let out)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(out.hasPrefix("em laço: Task a (tentativa 1/3) · rodando o check · desde ")
                    && out.hasSuffix("\nversão \(v + 1) · tempo esgotado sem mudança (timedOut)"), "\(out)")
            #expect(await d.router.work.changeWaiterCount == 0)
        }
    }

    @Test func aLoopThatEndedAnswersAtOnceWithEnded() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            #expect(try await call(p, a, "work.start", ["title": "Feature"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            let store = d.router.work
            try await store.update(w.id) { $0.loop = WorkLoopState(state: .running, task: "a", attempt: 1) }
            let v = try #require(try await store.version(w.id))
            // waiting on a running loop: its end wakes the wait
            let wait = Task { try await call(p, a, "work.wait", ["since": .number(Double(v)), "timeout": .number(3600)]) }
            #expect(await until { await store.changeWaiterCount == 1 })
            try await store.update(w.id) { $0.loop?.state = .stopped; $0.loop?.stopReason = .init(.maxReached) }
            let o = obj(try await wait.value)
            #expect(o["ended"] == .bool(true) && o["timedOut"] == .bool(false) && o["version"] == .number(Double(v + 1)))
            // already over: at once, even on the current version (a long timeout would hang the test otherwise)
            for state in [WorkLoopState.State.stopped, .finished] {
                try await store.update(w.id) { $0.loop?.state = state }
                let cur = try #require(try await store.version(w.id))
                let r = try await call(p, a, "work.wait", ["since": .number(Double(cur)), "timeout": .number(3600)])
                #expect(obj(r)["ended"] == .bool(true) && obj(r)["timedOut"] == .bool(false) && obj(r)["version"] == .number(Double(cur)), "\(state)")
                guard case .string(let out)? = obj(r)["output"] else { Issue.record("\(r)"); return }
                #expect(out.hasSuffix("\nversão \(cur) · laço terminou (ended)"), "\(out)")
            }
        }
    }

    // MARK: the loop's line with its times

    private func running(_ phase: WorkLoopState.Phase?, since: Date?, timeout: Int = 3600) -> Work {
        var w = Work(title: "Feature", terminalId: UUID())
        w.tasks = [WorkTask(id: "a", title: "Task a", state: .inProgress)]
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 2, tries: 3, timeout: timeout, phase: phase)
        w.loop?.phaseSince = since
        return w
    }

    @Test func runningLoopSaysSinceWhenAndTheNextLimit() {
        let w = running(.agent, since: t0)
        // 4 min 59 s in: the minutes elapsed round down, the minutes left round up
        #expect(WorkStatusText.loopLine(w, now: t0.addingTimeInterval(299), timeZone: utc)
                == "em laço: Task a (tentativa 2/3) · agente trabalhando · desde 14:03 (4 min) · próximo limite: turno vence em 56 min")
        #expect(WorkStatusText.times(w.loop!, now: t0, timeZone: utc) == "desde 14:03 (0 min) · próximo limite: turno vence em 60 min")
        #expect(WorkStatusText.times(w.loop!, now: t0.addingTimeInterval(3599), timeZone: utc) == "desde 14:03 (59 min) · próximo limite: turno vence em 1 min")
        #expect(WorkStatusText.times(w.loop!, now: t0.addingTimeInterval(3600), timeZone: utc) == "desde 14:03 (60 min) · próximo limite: turno vence agora")
        #expect(WorkStatusText.times(w.loop!, now: t0.addingTimeInterval(-30), timeZone: utc) == "desde 14:03 (0 min) · próximo limite: turno vence em 60 min",
                "a clock that went back never shows a negative time")
        #expect(WorkStatusText.times(running(.agent, since: t0, timeout: 90).loop!, now: t0.addingTimeInterval(31), timeZone: utc)
                == "desde 14:03 (0 min) · próximo limite: turno vence em 1 min")
        // the check and the gate have no turn to expire
        #expect(WorkStatusText.loopLine(running(.check, since: t0), now: t0.addingTimeInterval(125), timeZone: utc)
                == "em laço: Task a (tentativa 2/3) · rodando o check · desde 14:03 (2 min)")
        #expect(WorkStatusText.loopLine(running(.gate, since: t0), now: t0.addingTimeInterval(60), timeZone: utc)
                == "em laço: Task a (tentativa 2/3) · rodando o portão · desde 14:03 (1 min)")
        // the daemon's local time
        #expect(WorkStatusText.times(w.loop!, now: t0, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)?.hasPrefix("desde 11:03 ") == true)
    }

    @Test func theLineIsAsBeforeWithoutARunningPhaseOrWithoutNow() {
        let now = t0.addingTimeInterval(600)
        // no `now` (work list, the recall, the panel's badge): as always
        #expect(WorkStatusText.loopLine(running(.agent, since: t0)) == "em laço: Task a (tentativa 2/3) · agente trabalhando")
        // a loop written before `phaseSince`, and one between phases
        #expect(WorkStatusText.loopLine(running(.agent, since: nil), now: now, timeZone: utc) == "em laço: Task a (tentativa 2/3) · agente trabalhando")
        #expect(WorkStatusText.loopLine(running(nil, since: nil), now: now, timeZone: utc) == "em laço: Task a (tentativa 2/3)")
        // not running: its line does not change
        var stopped = running(.check, since: t0)
        stopped.loop?.state = .stopped; stopped.loop?.used = 3; stopped.loop?.stopReason = .init(.maxReached)
        #expect(WorkStatusText.loopLine(stopped, now: now, timeZone: utc) == WorkStatusText.loopLine(stopped))
        #expect(WorkStatusText.loopLine(stopped, now: now, timeZone: utc) == "laço parado (3 tentativas) · limite de tentativas (--max) atingido")
        var finished = running(.agent, since: t0); finished.loop?.state = .finished; finished.loop?.used = 2
        #expect(WorkStatusText.loopLine(finished, now: now, timeZone: utc) == "laço terminou (2 tentativas)")
        // no loop: no line
        #expect(WorkStatusText.loopLine(Work(title: "plain", terminalId: UUID()), now: now, timeZone: utc) == nil)
    }

    @Test func showRecordsWhenThePhaseChanged() {
        var l = WorkLoopState()
        l.show(.agent, at: t0)
        #expect(l.phase == .agent && l.phaseSince == t0)
        l.show(.agent, at: t0.addingTimeInterval(50))   // the same phase again (a nudge's turn): its time stays
        #expect(l.phaseSince == t0)
        l.show(.check, at: t0.addingTimeInterval(100))
        #expect(l.phase == .check && l.phaseSince == t0.addingTimeInterval(100))
        l.show(nil, at: t0.addingTimeInterval(200))
        #expect(l.phase == nil && l.phaseSince == nil)
    }

    @Test func statusShowsTheTimesOnlyOnTheLoopLine() async throws {
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A")
            #expect(try await call(p, a, "work.start", ["title": "Feature"]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            func status() async throws -> [String] {
                guard case .string(let out)? = obj(try await call(p, a, "work.status"))["output"] else { return [] }
                return out.components(separatedBy: "\n")
            }
            let plain = try await status()
            try await d.router.work.update(w.id) { x in
                x.tasks.append(WorkTask(id: "a", title: "Task a", state: .inProgress))
                x.loop = WorkLoopState(task: "a", attempt: 1, tries: 3, timeout: 600); x.loop?.show(.agent, at: Date().addingTimeInterval(-125))
            }
            let lines = try await status()
            let loop = try #require(lines.first { $0.hasPrefix("em laço: ") })
            #expect(loop.hasPrefix("em laço: Task a (tentativa 1/3) · agente trabalhando · desde ")
                    && loop.hasSuffix(" (2 min) · próximo limite: turno vence em 8 min"), "\(loop)")
            #expect(lines.first == plain.first && lines.filter { $0.contains("desde ") }.count == 1, "\(lines)")
        }
    }

    // MARK: the schema

    @Test func workWaitIsDeclaredForTheCLIAndMCP() throws {
        let spec = try #require(Commands.spec("work.wait"))
        #expect(spec.mcpName == "work_wait" && spec.exposedToMCP && !spec.shepherdOnly)
        #expect(spec.params.map(\.name) == ["since", "timeout", "terminal"])
        for shepherd in [false, true] {
            let names = MCPSchema.tools(shepherd: shepherd).compactMap { t -> String? in
                if case .object(let o) = t, case .string(let n)? = o["name"] { n } else { nil }
            }
            #expect(names.contains("work_wait"), "shepherd \(shepherd)")
            #expect(names.firstIndex(of: "work_wait") == names.firstIndex(of: "work_status").map { $0 + 1 })
        }
        let full = try ArgvParser.parse(["work", "wait", "--since", "7", "--timeout", "900"])
        #expect(full.command == "work.wait" && full.args == ["since": .number(7), "timeout": .number(900)])
        #expect(try ArgvParser.parse(["work", "wait"]).args.isEmpty)
        #expect(throws: ProtocolError.self) { try ArgvParser.parse(["work", "wait", "--since", "soon"]) }
        #expect(ArgvParser.help(["work", "wait", "--help"])?.hasPrefix("usage: collie work wait [--since <since>] [--timeout <timeout>] [--terminal <terminal>]") == true)
    }
}
