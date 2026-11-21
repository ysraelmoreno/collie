import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A terminal in a turn for the hub: output never stops, so its badge is `working` (the hub's own rule, not a fake).
private let busy = "echo T=$COLLIE_TOKEN; while :; do echo tick; sleep 0.1; done"

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawn(_ d: Daemon, _ p: Paths, _ args: [String: JSONValue], echo: Bool) async throws -> Term {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: echo))
}

private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}

/// Until `cond` holds or the bound runs out (yields only: the daemon's own hops, no clock).
private func until(_ cond: () async -> Bool) async -> Bool {
    for _ in 0..<1_000_000 { if await cond() { return true }; await Task.yield() }
    return await cond()
}

/// M3d.2 (review 3c, finding 3): the real seam, end to end. `RouterLoopHost.anyoneWorking` → `loopAnyoneWorking` →
/// `loopOthersWorking` → `targetBusy`, with the Shepherd's badge `working` and its `work.wait` parked on the work the
/// loop runs (the same key both use: the starter's active work).
@Suite(.timeLimit(.minutes(3))) struct ShepherdWaitIntegrationTests {
    /// A Shepherd in paddock `feat` whose badge is `working`, its active work, and the loop's host as `work.run` makes it.
    private struct Rig {
        let d: Daemon, p: Paths, shepherd: Term, work: UUID, version: Int, paddock: Paddock, host: RouterLoopHost
        var router: CommandRouter { d.router }
        var waitArgs: [String: JSONValue] { ["since": .number(Double(version)), "timeout": .number(3600)] }
        func parked(_ n: Int) async -> Bool {
            await until {
                let waits = await router.ownWorkWaits[shepherd.uuid]?[work] ?? 0
                return await router.work.changeWaiterCount == n && waits == n
            }
        }
        func clean() async -> Bool {
            await until {
                let open = await router.openRequests[shepherd.uuid], own = await router.ownWorkWaits[shepherd.uuid]
                return open == nil && own == nil
            }
        }
        func change() async throws { try await router.work.update(work) { $0.notes.append(WorkNote(text: "changed")) } }
    }

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await withDaemon { d, p in
            let m = try await spawn(d, p, ["name": "M", "preset": "shell", "cwd": .string(repo.path), "shepherd": true], echo: true)
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).ok)
            let s = try await spawn(d, p, ["name": "Shepherd", "preset": "custom", "command": .string(busy), "paddock": "feat", "shepherd": true], echo: false)
            #expect(try await call(p, s, "work.start", ["title": "Loop work"]).ok)
            let w = try #require(try await d.router.work.active(terminal: s.uuid)), v = try #require(w.version)
            let pad = try #require(await d.router.ws.paddocks.first { $0.name == "feat" })
            // as `work.run` builds it: the starter's active work, the paddock's worktree
            let host = RouterLoopHost(router: d.router, starter: s.uuid, root: p.root, work: w.id, paddock: pad.id,
                                      dir: URL(fileURLWithPath: pad.path), sandbox: nil)
            let working = await waitFor(20) { await d.badge(s.uuid) == .working }
            #expect(working, "the Shepherd's badge is working")
            try await body(Rig(d: d, p: p, shepherd: s, work: w.id, version: v, paddock: pad, host: host))
        }
    }

    @Test func aShepherdParkedInWorkWaitIsNotWorkingEvenWithItsBadgeWorking() async throws {
        try await withRig { r in
            let before = await r.host.anyoneWorking()
            #expect(before == "Shepherd", "no wait: its working badge counts")
            let wait = Task { try await call(r.p, r.shepherd, "work.wait", r.waitArgs) }
            let parked = await r.parked(1)
            #expect(parked)
            // the key: the wait is counted under the work the loop's host asks about
            let key = await r.router.ownWorkWaits[r.shepherd.uuid]?[r.host.work]
            #expect(key == 1, "work.wait and RouterLoopHost use the same work")
            let badge = await r.d.badge(r.shepherd.uuid)
            #expect(badge == .working)
            let during = await r.host.anyoneWorking()
            #expect(during == nil, "only waiting on the loop's work: not working, badge or not")
            let others = await r.host.othersWorking()
            #expect(others == nil)
            try await r.change()
            let done = try await wait.value
            #expect(done.ok, "\(done)")
            let clean = await r.clean()
            #expect(clean)
            let after = await r.host.anyoneWorking()
            #expect(after == "Shepherd", "the wait over: the badge counts again")
        }
    }

    @Test func aSecondOpenRequestOfTheShepherdCountsItAgain() async throws {
        try await withRig { r in
            let wait = Task { try await call(r.p, r.shepherd, "work.wait", r.waitArgs) }
            let parked = await r.parked(1)
            #expect(parked)
            let quiet = await r.host.anyoneWorking()
            #expect(quiet == nil)
            await r.router.requestBegan(r.shepherd.uuid)   // a second request of the Shepherd's open (an ask)
            let second = await r.host.anyoneWorking()
            #expect(second == "Shepherd", "another request beside the wait: working")
            await r.router.requestEnded(r.shepherd.uuid)
            let back = await r.host.anyoneWorking()
            #expect(back == nil)
            try await r.change()
            let done = try await wait.value
            #expect(done.ok, "\(done)")
            let clean = await r.clean()
            #expect(clean)
        }
    }

    @Test func anotherTerminalOfThePaddockAlwaysCounts() async throws {
        try await withRig { r in
            let o = try await spawn(r.d, r.p, ["name": "Helper", "preset": "custom", "command": .string(busy), "paddock": "feat"], echo: false)
            let working = await waitFor(20) { await r.d.badge(o.uuid) == .working }
            #expect(working)
            let wait = Task { try await call(r.p, r.shepherd, "work.wait", r.waitArgs) }
            let parked = await r.parked(1)
            #expect(parked)
            let who = await r.host.anyoneWorking()
            #expect(who == "Helper", "the Shepherd only waits; the other terminal in a turn still counts")
            let others = await r.host.othersWorking()
            #expect(others == "Helper")
            try await r.change()
            let done = try await wait.value
            #expect(done.ok, "\(done)")
        }
    }
}
