import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M3d.1: the starter's `work.wait` counts as "only waiting" while its client lives and the terminal has no turn
/// beyond it (a PostToolUse after the wait began). Real daemon, no sleep: every wait is on the daemon's own state.
@Suite(.timeLimit(.minutes(3))) struct StarterWaitLivenessTests {
    /// A Shepherd with an active work, and a way to call the daemon as it.
    private struct Starter {
        let d: Daemon, p: Paths, id: String, me: UUID, token: String, work: UUID, version: Int
        var router: CommandRouter { d.router }
        func request(_ cmd: String, _ a: [String: JSONValue] = [:]) -> Request {
            Request(id: "w", terminalId: id, token: token, command: cmd, args: a)
        }
        func call(_ cmd: String, _ a: [String: JSONValue] = [:]) async throws -> Response {
            try await send(p, request(cmd, a), timeoutSeconds: 60)
        }
        var waitArgs: [String: JSONValue] { ["since": .number(Double(version)), "timeout": .number(3600)] }
        /// Only waiting: what `loopAnyoneWorking` decides about the starter.
        func waits() async -> Bool { await router.loopStarterOnlyWaits(me, work: work) }
        /// Until `cond` holds or the bound runs out (yields only: the daemon's own hops, no clock).
        func until(_ cond: () async -> Bool) async -> Bool {
            for _ in 0..<1_000_000 { if await cond() { return true }; await Task.yield() }
            return await cond()
        }
        func parked(_ n: Int) async -> Bool {
            await until {
                let waits = await router.ownWorkWaits[me]?[work] ?? 0
                return await router.work.changeWaiterCount == n && waits == n
            }
        }
        func clean() async -> Bool {
            await until {
                let open = await router.openRequests[me], own = await router.ownWorkWaits[me], parked = await router.work.changeWaiterCount
                return open == nil && own == nil && parked == 0
            }
        }
        /// A `work.hook` of Claude's PostToolUse, as `collie hook claude-tool` sends it.
        func toolHook() async throws { #expect(try await call("work.hook", ["hook": .string("tool"), "payload": .string("{}")]).ok) }
        func change() async throws { try await router.work.update(work) { $0.notes.append(WorkNote(text: "changed")) } }
    }

    private func withStarter(_ body: (Starter) async throws -> Void) async throws {
        try await withDaemon { d, p in
            let args: [String: JSONValue] = ["name": .string("Shepherd"), "preset": .string("shell"), "cwd": .string("/tmp")]
            let s = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
            guard case .object(let o)? = s.result, case .string(let id)? = o["id"], let me = UUID(uuidString: id) else { Issue.record("\(s)"); return }
            let token = try await tokenOf(d, id)
            #expect(try await send(p, Request(id: "w", terminalId: id, token: token, command: "work.start", args: ["title": "Feature"])).ok)
            let w = try #require(try await d.router.work.active(terminal: me)), v = try #require(w.version)
            try await body(Starter(d: d, p: p, id: id, me: me, token: token, work: w.id, version: v))
        }
    }

    /// A raw client: the request line written, the socket left open until `close`.
    private func rawClient(_ s: Starter, _ req: Request) throws -> Int32 {
        let fd = makeSocket()
        #expect(fd >= 0)
        try UnixSocketClient.connectSocket(fd, s.p.socket.path) { 10_000 }
        var line = try JSONEncoder().encode(req); line.append(10)
        #expect(writeAll(fd, line, deadline: Date().addingTimeInterval(10)))
        return fd
    }

    @Test func aWaitWhoseClientClosesTheSocketStopsCountingAndIsUndone() async throws {
        try await withStarter { s in
            let fd = try rawClient(s, s.request("work.wait", s.waitArgs))
            #expect(await s.parked(1))
            #expect(await s.waits(), "a live client: only waiting")
            close(fd)   // the Bash timeout, a Ctrl-C: the client is gone
            #expect(await s.clean(), "the handler was cancelled and its count undone")
            #expect(!(await s.waits()))
        }
    }

    @Test func aWaitOfAProcessThatIsGoneDoesNotCount() async throws {
        try await withStarter { s in
            let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try gone.run(); gone.waitUntilExit()
            let dead = gone.processIdentifier
            #expect(kill(dead, 0) != 0)
            // the request as the router sees it: open, and a wait of a client whose pid no longer exists
            await s.router.requestBegan(s.me)
            let tok = await s.router.ownWaitBegan(s.me, on: s.work, pid: dead)
            #expect(!(await s.waits()), "a dead client's wait is not a wait")
            await s.router.ownWaitEnded(s.me, tok)
            await s.router.requestEnded(s.me)
            await s.router.requestBegan(s.me)
            let live = await s.router.ownWaitBegan(s.me, on: s.work, pid: getpid())
            #expect(await s.waits(), "the same wait of a live client is")
            #expect(!(await s.router.loopStarterOnlyWaits(s.me, work: UUID())), "not another work's")
            await s.router.ownWaitEnded(s.me, live)
            await s.router.requestEnded(s.me)
            #expect(await s.clean())
        }
    }

    @Test func aToolCallAfterTheWaitBeganCountsTheStarterAgain() async throws {
        try await withStarter { s in
            try await s.toolHook()   // before the wait: the turn that started it, not one beside it
            let wait = Task { try await s.call("work.wait", s.waitArgs) }
            #expect(await s.parked(1))
            #expect(await s.waits(), "a tool call before the wait does not count")
            try await s.toolHook()   // the wait went to the background and the Shepherd goes on
            #expect(!(await s.waits()), "a turn beyond the wait: working")
            try await s.change()
            #expect(try await wait.value.ok)
            #expect(await s.clean())
            // the next wait starts after that tool call: only waiting again
            let next = Task { try await s.call("work.wait", ["since": .number(Double(s.version + 1)), "timeout": .number(3600)]) }
            #expect(await s.parked(1))
            #expect(await s.waits())
            try await s.change()
            #expect(try await next.value.ok)
            #expect(await s.clean())
        }
    }

    /// M3c.2 regression: the Shepherd blocked in a live, quiet `collie work wait` is not working.
    @Test func aLiveQuietWaitStillDoesNotCount() async throws {
        try await withStarter { s in
            let wait = Task { try await s.call("work.wait", s.waitArgs) }
            #expect(await s.parked(1))
            #expect(await s.waits())
            await s.router.requestBegan(s.me)   // any other request open meanwhile (an ask): working
            #expect(!(await s.waits()))
            await s.router.requestEnded(s.me)
            #expect(await s.waits())
            try await s.change()
            let r = try await wait.value
            #expect(r.ok, "the normal wait still answers: \(r)")
            #expect(await s.clean(), "nothing left counted")
        }
    }

    @Test func disconnectsLeaveNothingCounted() async throws {
        try await withStarter { s in
            let fds = try (0..<3).map { _ in try rawClient(s, s.request("work.wait", s.waitArgs)) }
            #expect(await s.parked(3))
            fds.forEach { close($0) }
            #expect(await s.clean(), "three gone clients, no count left")
            // the daemon still serves the starter's waits afterwards
            let wait = Task { try await s.call("work.wait", s.waitArgs) }
            #expect(await s.parked(1))
            try await s.change()
            #expect(try await wait.value.ok)
            #expect(await s.clean())
        }
    }
}
