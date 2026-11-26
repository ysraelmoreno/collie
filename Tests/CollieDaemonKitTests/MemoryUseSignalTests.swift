import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// ma2 4e: an implicit use only from the user's own next prompt or a loop task passed on its 1st try.
@Suite(.serialized) struct MemoryUseSignalTests {
    private let t = UUID(), prompt = "postgres pool sizing"

    private func setup(_ recs: [MemoryRecord]) async throws -> (MemoryService, URL) {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        for r in recs { _ = try await store.run { try $0.store.save(r) } }
        await mem.noteSession(t, transcript: "/x/s1.jsonl")
        return (mem, repo)
    }
    private func x() -> MemoryRecord { MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres pool", body: "postgres pool sizing") }
    private func used(_ mem: MemoryService) -> [MemoryEvent] {
        mem.events.flush()
        return mem.events.read(since: Date().addingTimeInterval(-60)).filter { $0.type == .used }
    }

    @Test func userPromptWithoutCorrectionCountsUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: false, user: true, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
        #expect(used(mem).map(\.ids) == [[r.id]])
    }

    @Test func machinePromptCountsNoUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: false, user: false, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.isEmpty ?? true)
        #expect(await mem.lifecycle.takePending(session: "s1").isEmpty)   // consumed, not left for a later prompt
        let es = used(mem)
        #expect(es.count == 1 && es[0].reason == "machine" && es[0].ids == [] && es[0].hits == 1)
        #expect(MemoryObservability.precision(es).used == 0)
    }

    @Test func userCorrectionStillCountsAsCorrection() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.resolvePending(for: t, correction: true, user: true, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.isEmpty ?? true)
        let es = used(mem)
        #expect(es.count == 1 && es[0].reason == "correction")
        #expect(MemoryObservability.precision(es).corrected == 1)
    }

    @Test func loopTaskPassedOnFirstTryCountsUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.endSession(t)   // the loop dismisses its agent before the verdict
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.isEmpty ?? true)
        await mem.settleParked(t, firstTryPassed: true, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
        await mem.settleParked(t, firstTryPassed: true, now: Date())   // settled once
        #expect(used(mem).map(\.ids) == [[r.id]])
    }

    @Test func loopTaskPassedOnSecondTryCountsNoUse() async throws {
        let r = x()
        let (mem, repo) = try await setup([r])
        _ = await mem.relevant(for: t, cwd: repo.path, prompt: prompt)
        await mem.endSession(t)
        await mem.settleParked(t, firstTryPassed: false, now: Date())
        #expect(await mem.lifecycle.entry(r.id)?.usefulUses.isEmpty ?? true)
        let es = used(mem)
        #expect(es.count == 1 && es[0].reason == "loop" && es[0].ids == [])
    }

    @Test func parkedSessionsAreCapped() async throws {
        let (mem, _) = try await setup([])
        var ts: [UUID] = []
        for _ in 0...MemoryService.parkedCap {
            let u = UUID(); ts.append(u)
            await mem.noteSession(u, transcript: "/x/\(u).jsonl")
            await mem.lifecycle.setPending(session: u.uuidString, ids: [UUID()])
            await mem.endSession(u)
        }
        await mem.settleParked(UUID(), firstTryPassed: false)   // unknown: nothing
        await mem.settleParked(ts[0], firstTryPassed: false)   // the oldest, dropped past the cap: nothing
        #expect(used(mem).isEmpty)
        await mem.settleParked(ts[ts.count - 1], firstTryPassed: false)
        #expect(used(mem).map(\.session) == [ts[ts.count - 1].uuidString])
    }

    // the loop's wiring: `markDone` says whether it was the 1st try, `markOpenOrDeferred` never counts
    @Test func loopTellsFirstTryPass() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(await r.host.verdicts == ["w-task-a-t1 true"])
    }

    @Test func loopTellsSecondTryPassAndFailures() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("wrong.txt", "bad\n", in: $0) }))
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(await r.host.verdicts == ["w-task-a-t1 false", "w-task-a-t2 false"])
    }

    @Test func loopTellsDeferral() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "false")], tries: 2); defer { r.cleanup() }
        for n in 1...2 { await r.host.set("w-task-a-t\(n)", LoopScript(act: { try await commit("f\(n).txt", "x\n", in: $0) })) }
        _ = await r.run()
        #expect(await r.host.verdicts == ["w-task-a-t1 false", "w-task-a-t2 false"])
    }

    // the router's real path: who wrote the prompt comes from `asks.provenance.submit`
    @Test func routerCountsOnlyTheUsersPrompt() async throws {
        let repo = try await makeRepo(), r = x()
        try await withDaemon { d, p in
            let sp = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
                "name": .string("A"), "preset": .string("shell"), "cwd": .string(repo.path)]), to: p.socket, timeoutSeconds: 60)
            guard case .object(let o)? = sp.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(sp)") }
            let token = try await tokenOf(d, id), u = UUID(uuidString: id)!
            _ = await d.router.asks.provenance.take(u, prompt: "")   // tokenOf typed `echo` into the shell: start clean
            let mem = d.router.memory
            _ = try await mem.repo(for: repo.path).run { try $0.store.save(r) }
            await mem.noteSession(u, transcript: "/x/s1.jsonl")
            func hook(_ text: String) async throws {
                let res = try await UnixSocketClient.send(Request(id: "m", terminalId: id, token: token, command: "memory.hookRelevant",
                                                                  args: ["prompt": .string(text)]), to: p.socket, timeoutSeconds: 60)
                #expect(res.ok, "\(res)")
            }
            try await hook(prompt)   // injects r: pending
            #expect(await mem.lifecycle.pending(session: "s1") == [r.id])
            await d.router.asks.provenance.taint(u)   // a machine write (an ask) before the next prompt
            try await hook("continue com a próxima etapa")
            #expect(await mem.lifecycle.entry(r.id)?.usefulUses.isEmpty ?? true)
            await mem.lifecycle.setPending(session: "s1", ids: [r.id])
            let mine = "segue com a próxima etapa"
            await d.router.asks.provenance.typed(u, Data((mine + "\r").utf8))   // the user's own keystrokes
            try await hook(mine)
            #expect(await mem.lifecycle.entry(r.id)?.usefulUses.count == 1)
        }
    }
}
