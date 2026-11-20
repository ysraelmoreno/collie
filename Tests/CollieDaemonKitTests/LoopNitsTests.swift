import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ d: Daemon, _ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}

/// M1b.3: the review's loose ends: `cancelled` reaches the disk at the daemon's stop, `discarded` names a patch only
/// when one was written, and `events: false` in `work status` is no journal (not an error).
@Suite(.serialized) struct LoopNitsTests {
    // MARK: 1. `cancelled` reaches the disk

    @Test func cancelLoopsWaitsForTheLoopToWriteCancelled() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
            #expect(try await call(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
            let id = try #require(try await d.router.work.active(terminal: s.uuid)).id
            #expect(try await call(d, p, s, "work.task.add", ["title": .string("A"), "check": .string("true")]).ok)
            // an agent that never ends its turn nor commits: the loop is in the attempt when the daemon stops
            let run = try await call(d, p, s, "work.run", ["max": .number(3), "command": .string("bash -c 'read l; cat'"), "timeout": .number(600)])
            #expect(run.ok, "\(run)")
            let card = await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } }
            let c = try #require(card ? await d.router.appCards.first { $0.app == "work-loop" } : nil)
            #expect(try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                              args: ["id": .string(c.id.uuidString), "allow": .bool(true)])).ok)
            let asked = await waitFor(60) { (try? await d.router.work.get(id))?.loop?.events?.contains { $0.kind == .agentSummoned } ?? false }
            #expect(asked)

            // M2b.2: the event is the loop's own `Task` ending (it ends once `cancelled` is written), not the stop's
            // 2 s: under load a real terminal's attempt can take longer to unwind. That the stop waits for a loop
            // that ends in time, and gives up one that does not, is in LoopCancelWaitTests (injected wait, no PTY).
            let loop = try #require(await d.router.workLoops[id]?.task)
            await d.router.cancelLoops()   // the daemon's stop
            await loop.value
            let w = try #require(try await d.router.work.get(id))
            #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.cancelled), "\(String(describing: w.loop)) \(w.notes.map(\.text))")
            #expect(w.loop?.events?.last?.kind == .stopped && w.notes.last?.text.hasPrefix("[loop] laço parado:") == true)
            // no verdict: the task is open again and the attempt was not counted
            #expect(w.tasks.first?.state == .open && w.tasks.first?.tries == nil && w.loop?.used == 0)
            #expect(await d.router.workLoops.isEmpty)
        }
    }

    // MARK: 2. `discarded` only names a patch that exists

    @Test func withoutAPatchTheEventSaysThereWereNoChanges() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        // the agent changes nothing: no commit, an empty diff
        #expect(await r.run() == .finished)
        let w = try await r.get(), ev = w.loop?.events ?? []
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit")   // the decision is the same
        #expect(ev.last { $0.kind == .discarded }?.detail == "sem alterações", "\(ev.map { "\($0.kind.rawValue) \($0.detail ?? "")" })")
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(r.work).appendingPathComponent("a-1.patch").path))
    }

    @Test func withAPatchTheEventNamesItsFile() async throws {
        let r = try await LoopRig([task("a", "exit 3")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        #expect(ev.last { $0.kind == .discarded }?.detail == "a-1.patch")
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("wrong.txt"))
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("wrong.txt").path))   // discarded all the same
    }

    // MARK: 3. `events` as a boolean in `work status` (MCP/JSON)

    @Test func eventsFalseIsNoJournalAndTrueIsTheDefault() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            #expect(try await call(d, p, a, "work.start", ["title": .string("W")]).ok)
            let id = try #require(try await d.router.work.active(terminal: a.uuid)).id
            // a loop that ended, with a journal of 30 events
            try await d.router.work.update(id) { w in
                var l = WorkLoopState(state: .stopped, used: 1)
                for i in 0..<30 { l.record(LoopEvent(at: Date(timeIntervalSinceReferenceDate: Double(i)), kind: .verdict, detail: "\(i)")) }
                w.loop = l
            }
            func status(_ events: JSONValue?) async throws -> Response { try await call(d, p, a, "work.status", events.map { ["events": $0] } ?? [:]) }
            func journal(_ r: Response) -> [JSONValue]? {
                guard case .object(let o)? = r.result, case .object(let e)? = o["events"], case .array(let list)? = e[id.uuidString.lowercased()] else { return nil }
                return list
            }
            func text(_ r: Response) -> String { if case .object(let o)? = r.result, case .string(let s)? = o["output"] { s } else { "" } }

            let absent = try await status(nil), off = try await status(.bool(false))
            #expect(off.ok && journal(off) == nil && !text(off).contains("Diário do laço"), "\(off)")
            #expect(text(off) == text(absent))   // `false` is the same as absent
            let on = try await status(.bool(true))
            #expect(on.ok && journal(on)?.count == 20 && text(on).contains("Diário do laço"), "\(on)")
            #expect(journal(try await status(.number(5)))?.count == 5)
            for bad in [0.0, 101.0] {
                #expect(try await status(.number(bad)).error?.code == .invalidArgs, "\(bad)")
            }
        }
    }
}
