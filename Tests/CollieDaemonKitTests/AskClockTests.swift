import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M11.1: the ask's time limits come from `AskLimits` (the daemon: `.production`); a test injects ~100 ms ones and
/// the ask still ends on the same path (turn timeout, held cap, lost hook). Bounds are multiples of the injected
/// limit, never tight absolutes: the loop runs these under load.
private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/fake-agent.sh").path

private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil) async throws -> Term {
    let s = try await spawn(d, p, name, preset: preset, command: command)
    #expect(s.resp.ok, "spawn \(name): \(s.resp)")
    return Term(id: s.id, token: try await tokenOf(d, s.id, echo: command == nil))
}

private func connect(_ d: Daemon, _ p: Paths, _ a: String, _ b: String) async throws {
    let r = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string(a), "b": .string(b)]))
    #expect(r.ok)
}

private func ask(_ p: Paths, _ from: Term, _ target: String, _ prompt: String, timeout: Double) async throws -> Response {
    try await send(p, Request(id: "a", terminalId: from.id, token: from.token, command: "ask",
                              args: ["target": .string(target), "prompt": .string(prompt), "timeout": .number(timeout)]),
                   timeoutSeconds: timeout + 10)
}

private func output(_ r: Response) -> String? {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { return s } else { return nil }
}
private func source(_ r: Response) -> String? {
    if case .object(let o)? = r.result, case .string(let s)? = o["source"] { return s } else { return nil }
}

/// Reports each `<<COLLIE_FAKE_STOP:…>>` the fake agent prints through `turn.completed` (its Stop hook).
private func hookWatcher(_ d: Daemon, _ p: Paths, _ t: Term) -> Task<Void, Never> {
    Task {
        var seen = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            let msgs = await d.scrollbackText(UUID(uuidString: t.id)!).matches(of: /<<COLLIE_FAKE_STOP:(.*?)>>/).map { String($0.output.1) }
            for m in msgs.dropFirst(seen) {
                _ = try? await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                               args: ["message": .string(m), "source": .string("generic")]))
            }
            seen = max(seen, msgs.count)
        }
    }
}

private let limit = 0.1   // the injected limit, seconds
/// Generous ceiling for "ended by the injected limit, not a production one": still far under any production limit.
private let ceiling: Duration = .seconds(limit * 80)

@Suite(.serialized) struct AskClockTests {
    @Test func productionLimitsAreTodaysNumbers() {
        let p = AskLimits.production
        #expect(p.idleQuiet == .seconds(2) && p.heldMax == .seconds(600) && p.captureHold == .seconds(120))
        #expect(p.readyQuiet == .milliseconds(300) && p.readyMax == .seconds(10) && p.submitConfirm == .seconds(8))
        #expect(p.minTimeoutSeconds == 1 && p.replyQuiet == .seconds(2) && p.replyQuiet == StreamHub.workingWindow)
        // the defaults (no injection) are those same numbers, through every entry point
        #expect(AskCoordinator(idleQuietSeconds: 2).limits == p)
        let c = DaemonConfig(paths: Paths(root: URL(fileURLWithPath: "/nonexistent")),
                             collieExecutable: URL(fileURLWithPath: "/usr/bin/true"), workspaceId: UUID())
        #expect(c.idleQuietSeconds == 2 && c.heldMaxSeconds == 600 && c.captureHoldSeconds == 120)
        #expect(c.askReadyQuiet == p.readyQuiet && c.askReadyMax == p.readyMax && c.askMinTimeoutSeconds == p.minTimeoutSeconds
                && c.askReplyQuiet == p.replyQuiet)
    }

    /// Turn timeout: a target that never answers ends the ask on the injected 100 ms timeout.
    @Test func injectedTurnTimeoutExpires() async throws {
        try await withDaemon(configure: { $0.askReadyQuiet = .milliseconds(50); $0.askMinTimeoutSeconds = 0.05 }) { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "B", preset: "claude", command: "echo up; exec sleep 999")
            try await connect(d, p, "A", "B")
            let t0 = ContinuousClock.now
            let r = try await ask(p, a, "B", "hi", timeout: limit)
            #expect(r.error?.code == .timeout, "\(r)")
            #expect(ContinuousClock.now - t0 < ceiling)
        }
    }

    /// Held cap: a delivered turn that timed out keeps the slot only until the injected cap, then the next ask is typed.
    @Test func injectedHeldCapFreesTheSlot() async throws {
        try await withDaemon(configure: { $0.heldMaxSeconds = limit; $0.askReadyQuiet = .milliseconds(50); $0.askMinTimeoutSeconds = 0.05 }) { d, p in
            let a = try await term(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "claude", command: "echo up; exec sleep 999")
            try await connect(d, p, "A", "B")
            let bid = try #require(UUID(uuidString: b.id))
            let first = try await ask(p, a, "B", "first-prompt", timeout: 2)   // delivered, never answered: held
            #expect(first.error?.code == .timeout, "\(first)")
            #expect(await d.scrollbackText(bid).contains("first-prompt"))
            let t0 = ContinuousClock.now
            #expect(await waitFor(5) { !(await d.askBusy(bid)) })   // the 100 ms cap freed it, not the 600 s default
            #expect(ContinuousClock.now - t0 < ceiling)
            _ = try await ask(p, a, "B", "second-prompt", timeout: limit * 5)
            #expect(await waitFor(5) { await d.scrollbackText(bid).contains("second-prompt") })
        }
    }

    /// Lost hook: a hook-capable target skips one turn's hook; that ask times out, its turn is held until the
    /// injected cap, and the asks after it get their own answers again (at most one more lost).
    @Test func injectedCapRecoversFromALostHook() async throws {
        try await withDaemon(configure: { $0.heldMaxSeconds = limit; $0.idleQuietSeconds = 15; $0.askReadyQuiet = .milliseconds(50); $0.askMinTimeoutSeconds = 0.05 }) { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_THINK=0.05 COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_SKIP=2 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            let q1 = try await ask(p, a, "B", "q1", timeout: 10)
            #expect(output(q1) == "answer:q1" && source(q1) == "hook", "\(q1)")
            let q2 = try await ask(p, a, "B", "q2", timeout: limit * 5)   // its hook never comes: idle is 15 s away
            #expect(q2.error?.code == .timeout, "\(q2)")
            var failures = 0
            for n in 3...5 {
                let r = try await ask(p, a, "B", "q\(n)", timeout: 2)   // a turn ≈ 0.1 s; the lost one costs this
                if r.error != nil { failures += 1; continue }
                #expect(output(r) == "answer:q\(n)", "ask \(n): \(r)")
            }
            #expect(failures <= 1)
        }
    }

    /// The fake agent with a short think time still follows the real rule: no hook, so the injected idle window ends it.
    @Test func fakeWithShortLimitsEndsByIdle() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 0.3; $0.askReadyQuiet = .milliseconds(50); $0.askMinTimeoutSeconds = 0.05 }) { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", preset: "shell", command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_THINK=0.05 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let t0 = ContinuousClock.now
            let r = try await ask(p, a, "B", "hello", timeout: 10)
            #expect(output(r)?.contains("answer:hello") == true && source(r) == "idle", "\(r)")
            #expect(ContinuousClock.now - t0 < ceiling)
        }
    }
}
