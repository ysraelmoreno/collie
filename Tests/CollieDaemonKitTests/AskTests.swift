import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/fake-agent.sh").path

/// Command line for a fake agent; prints its own token first so the test can authenticate as it.
private func fakeAgent(hook: Bool) -> String {
    "echo T=$COLLIE_TOKEN; \(hook ? "COLLIE_FAKE_HOOK=1 " : "")exec sh '\(fixture)'"
}

private struct Term { var id: String; var token: String }

/// Spawns a terminal and returns its id and token. Shells get their token via `echo`;
/// commands must print `T=$COLLIE_TOKEN` themselves.
private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil) async throws -> Term {
    let s = try await spawn(d, p, name, preset: preset, command: command)
    #expect(s.resp.ok, "spawn \(name): \(s.resp)")
    return Term(id: s.id, token: try await tokenOf(d, s.id, echo: command == nil))
}

private func connect(_ d: Daemon, _ p: Paths, _ a: String, _ b: String) async throws {
    let r = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string(a), "b": .string(b)]))
    #expect(r.ok)
}

private func ask(_ p: Paths, _ from: Term, _ target: String, _ prompt: String, timeout: Int? = nil) async throws -> Response {
    var args: [String: JSONValue] = ["target": .string(target), "prompt": .string(prompt)]
    if let timeout { args["timeout"] = .number(Double(timeout)) }
    // client waits past the daemon's own timeout so the typed .timeout (not the socket's) is what tests see
    return try await send(p, Request(id: "a", terminalId: from.id, token: from.token, command: "ask", args: args),
                          timeoutSeconds: Double(timeout ?? 5) + 10)
}

private func result(_ r: Response) -> (output: String, source: String?, truncated: Bool?) {
    guard case .object(let o)? = r.result, case .string(let out)? = o["output"] else { return ("<no result: \(r)>", nil, nil) }
    var src: String?; if case .string(let s)? = o["source"] { src = s }
    var tr: Bool?; if case .bool(let b)? = o["truncated"] { tr = b }
    return (out, src, tr)
}

/// Off-screen hooks (`COLLIE_FAKE_HOOK=file`): each new line of `file` is reported through `turn.completed`.
private func fileHookWatcher(_ p: Paths, _ t: Term, _ file: URL) -> Task<Void, Never> {
    Task {
        var seen = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            for m in lines.dropFirst(seen) {
                _ = try? await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                               args: ["message": .string(m), "source": .string("generic")]))
            }
            seen = max(seen, lines.count)
        }
    }
}

/// Hooks a watcher has handed to the daemon (`turn.completed` returns once the coordinator processed it).
private final class Delivered: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func add() { l.withLock { n += 1 } }
    var count: Int { l.withLock { n } }
}

/// Watches a fake agent's scrollback for stop markers and reports each through `turn.completed`
/// with that terminal's own credentials (end-to-end hook path).
private func hookWatcher(_ d: Daemon, _ p: Paths, _ t: Term, delivered: Delivered? = nil) -> Task<Void, Never> {
    Task {
        var seen = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let text = await d.scrollbackText(UUID(uuidString: t.id)!)
            let msgs = text.matches(of: /<<COLLIE_FAKE_STOP:(.*?)>>/).map { String($0.output.1) }
            for m in msgs.dropFirst(seen) {
                _ = try? await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                               args: ["message": .string(m), "source": .string("generic")]))
                delivered?.add()
            }
            seen = max(seen, msgs.count)
        }
    }
}

/// Tests about the hook path: the idle fallback (2 s quiet in production) races the test's hook round trip
/// (scrollback poll + socket), which a loaded machine can stretch past 2 s. 15 s takes idle out of that race.
private func withHookDaemon(_ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.idleQuietSeconds = 15 }, body)
}

/// `ask --no-wait`: the ask id from the immediate reply.
private func askNoWait(_ p: Paths, _ from: Term, _ target: String, _ prompt: String, timeout: Int? = nil) async throws -> (id: String, resp: Response) {
    var args: [String: JSONValue] = ["target": .string(target), "prompt": .string(prompt), "no-wait": .bool(true)]
    if let timeout { args["timeout"] = .number(Double(timeout)) }
    let r = try await send(p, Request(id: "nw", terminalId: from.id, token: from.token, command: "ask", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["askId"] else { return ("", r) }
    return (id, r)
}

private func askResult(_ p: Paths, _ from: Term, _ id: String) async throws -> Response {
    try await send(p, Request(id: "ar", terminalId: from.id, token: from.token, command: "ask.result", args: ["id": .string(id)]))
}

private func field(_ r: Response, _ k: String) -> String? {
    if case .object(let o)? = r.result, case .string(let s)? = o[k] { return s } else { return nil }
}

/// The target's turn ends with `message` (its Stop hook), once an ask is in flight on it.
private func hook(_ d: Daemon, _ p: Paths, _ t: Term, _ message: String) async throws {
    #expect(await waitFor(10) { await d.askBusy(UUID(uuidString: t.id)!) })
    _ = try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                  args: ["message": .string(message), "source": .string("claude")]))
}

/// An agent asker that reads what is typed and prints nothing (the tty's echo shows it once).
private let quietAgent = "echo T=$COLLIE_TOKEN; exec cat >/dev/null"
private let silentTarget = "echo T=$COLLIE_TOKEN; exec sleep 999"

@Suite(.serialized) struct AskTests {
    @Test func askViaHook() async throws {
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom", command: fakeAgent(hook: true))
            try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            let r = try await ask(p, a, "B", "hello", timeout: 15)
            let res = result(r)
            #expect(res.output == "answer:hello")
            #expect(res.source == "hook")
            #expect(res.truncated == false)
        }
    }

    /// A slow-starting agent that drops typeahead (tcflush, like a shell resetting its tty during init):
    /// an ask sent right after spawn must wait for the target's first output instead of being lost.
    @Test func askRightAfterSpawnIsDelivered() async throws {
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A")
            let flush = "perl -MPOSIX -e 'POSIX::tcflush(0, POSIX::TCIFLUSH)'"
            let s = try await spawn(d, p, "B", preset: "custom",
                                    command: "sleep 1; \(flush); echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let t0 = ContinuousClock.now
            let pending = Task { try await ask(p, a, "B", "hello", timeout: 20) }
            let b = Term(id: s.id, token: try await tokenOf(d, s.id, echo: false))
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            let r = try await pending.value
            #expect(result(r).output == "answer:hello", "\(r)")
            #expect(result(r).source == "hook")
            #expect(ContinuousClock.now - t0 < .seconds(15))   // delivered, not lost until the 20 s timeout
        }
    }

    /// Hook arrives 3 s after the answer, past the 2 s idle window: turn 1 always completes by idle, and its
    /// late hook must not complete ask 2 (which would shift every later answer by one turn).
    /// 3 s, not more: ask 2 is injected when idle fires (answer + 2 s) and its echo alone would idle-complete
    /// it 2 s later (answer + 4 s), so turn 1's hook must land before that. 3 s leaves 1 s margin both ways.
    @Test func hookCapableTerminalNeverShiftsAnswers() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_DELAY=3 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            for n in 1...5 {
                let prompt = "q\(n)-\(UUID().uuidString.prefix(6))"
                // a turn takes ~3.5 s; ask 2 also waits ~1 s for turn 1's hook. 20 s: room for a loaded machine
                let res = result(try await ask(p, a, "B", prompt, timeout: 20))
                if n == 1 {
                    #expect(res.source == "idle", "ask 1 must exercise the swallow path: \(res)")
                    // idle output is the raw screen (echo, "thinking...", answer); the answer is its last line
                    let last = res.output.split(whereSeparator: \.isNewline).last.map(String.init)
                    #expect(last == "answer:\(prompt)", "ask \(n): \(res)")
                } else {
                    #expect(res.output == "answer:\(prompt)", "ask \(n): \(res)")
                    #expect(res.source == "hook", "ask \(n): \(res)")
                }
            }
        }
    }

    /// An ask that times out while its turn is still running must not hand that turn's late hook to the
    /// next ask (every later answer would be shifted by one turn).
    @Test func timedOutTurnDoesNotShiftNextAnswer() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_DELAY=3 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            _ = try await ask(p, a, "B", "warm", timeout: 20)           // idle-completed; latches hookCapable later
            let slow = try await ask(p, a, "B", "slow", timeout: 1)     // turn takes ~3.5 s
            #expect(slow.error?.code == .timeout, "\(slow)")
            // waits out the slow turn's late hook (~3 s) plus its own ~3.5 s turn: 20 s leaves room for load
            let next = result(try await ask(p, a, "B", "next", timeout: 20))
            #expect(next.output == "answer:next", "\(next)")
        }
    }

    /// A turn whose hook never comes (interrupted) is held until the cap; afterwards later asks still get their
    /// own answers — the expired turn costs at most one ask, never a chain.
    @Test func heldCapExpiryCostsAtMostOneAsk() async throws {
        try await withDaemon(configure: { $0.heldMaxSeconds = 2 }) { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_SKIP=2 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let hooks = Delivered()
            let w = hookWatcher(d, p, b, delivered: hooks); defer { w.cancel() }
            // q1 only latches hook-only mode. Its hook may land after idle completed it under load (then it is
            // swallowed as that idle turn's late hook): same state either way once the hook was processed.
            let q1 = result(try await ask(p, a, "B", "q1", timeout: 20))
            #expect(q1.output.split(whereSeparator: \.isNewline).last == "answer:q1", "\(q1)")
            #expect(await waitFor(20) { hooks.count >= 1 })
            #expect(try await ask(p, a, "B", "q2", timeout: 1).error?.code == .timeout)   // hook lost: held, then cap
            try await Task.sleep(for: .seconds(2.5))
            var failures = 0
            for n in 3...5 {
                let r = try await ask(p, a, "B", "q\(n)", timeout: 15)
                if r.error != nil { failures += 1; continue }
                #expect(result(r).output == "answer:q\(n)", "ask \(n): \(r)")
            }
            #expect(failures <= 1)
        }
    }

    /// The idle turn's late hook carries a message that differs from its screen text (markdown etc.): it must
    /// still be swallowed, not handed to the next ask.
    @Test func decoratedLateHookDoesNotShift() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let hooks = p.root.appendingPathComponent("hooks-b.txt")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=file COLLIE_FAKE_HOOK_FILE='\(hooks.path)' COLLIE_FAKE_HOOK_DELAY=3 COLLIE_FAKE_HOOK_DECOR='**' exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = fileHookWatcher(p, b, hooks); defer { w.cancel() }
            #expect(result(try await ask(p, a, "B", "q1", timeout: 20)).source == "idle")
            for n in 2...3 {
                let r = result(try await ask(p, a, "B", "q\(n)", timeout: 20))
                #expect(r.output == "**answer:q\(n)**", "ask \(n): \(r)")
            }
        }
    }

    /// The next prompt quotes the previous answer: its echo must not make the idle turn's late hook look like
    /// the current turn's own.
    @Test func promptQuotingLastAnswerDoesNotShift() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let hooks = p.root.appendingPathComponent("hooks-b.txt")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=file COLLIE_FAKE_HOOK_FILE='\(hooks.path)' COLLIE_FAKE_HOOK_DELAY=3 COLLIE_FAKE_HOOK_DECOR='**' exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = fileHookWatcher(p, b, hooks); defer { w.cancel() }
            #expect(result(try await ask(p, a, "B", "q1", timeout: 20)).source == "idle")
            let quoting = "re: **answer:q1**"
            let r = result(try await ask(p, a, "B", quoting, timeout: 20))
            #expect(r.output == "**answer:\(quoting)**", "\(r)")
        }
    }

    /// Three hookless turns finish by idle, then the target starts sending hooks: only the first hooked
    /// turn's hook is mistaken for an idle turn's late hook, so at most one ask times out.
    @Test func lostHookCostsAtMostOneAsk() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "custom",
                                   command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_FROM=4 exec sh '\(fixture)'")
            try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            var timeouts = 0
            for n in 1...6 {
                let prompt = "q\(n)"
                let r = try await ask(p, a, "B", prompt, timeout: 12)   // idle turn ≈ 2.5 s; margin for load
                let res = result(r)
                if n <= 3 {
                    #expect(res.source == "idle", "ask \(n): \(r)")
                } else if r.error?.code == .timeout {
                    timeouts += 1
                } else {
                    #expect(res.output == "answer:\(prompt)" && res.source == "hook", "ask \(n): \(r)")
                }
            }
            #expect(timeouts <= 1)
        }
    }

    @Test func askViaIdleFallback() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", preset: "shell", command: fakeAgent(hook: false))
            try await connect(d, p, "A", "B")
            let res = result(try await ask(p, a, "B", "hello", timeout: 15))
            #expect(res.output.contains("answer:hello"))
            #expect(res.source == "idle")
        }
    }

    @Test func bracketedPasteOnlyWhenEnabled() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", preset: "shell", command: fakeAgent(hook: false))
            try await connect(d, p, "A", "B")
            let res = result(try await ask(p, a, "B", "hello", timeout: 15))
            let lines = res.output.split(separator: "\n").map(String.init)
            #expect(lines.contains("answer:hello"), "\(res.output)")
            #expect(!res.output.contains("\u{1B}") && !res.output.contains("200~") && !res.output.contains("201~"), "\(res.output)")
        }
    }

    @Test func askRejectsUnconnected() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "C")
            let r = try await ask(p, a, "C", "hi")
            #expect(r.error?.code == .notConnected)
        }
    }

    @Test func askDetectsDeadlock() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: "echo T=$COLLIE_TOKEN; exec sleep 999")
            try await connect(d, p, "A", "B")
            let pending = Task { try await ask(p, a, "B", "never answered", timeout: 30) }
            let bid = try #require(UUID(uuidString: b.id))
            #expect(await waitFor(10) { await d.askBusy(bid) })   // A's ask is in flight on B
            let t0 = ContinuousClock.now
            let r = try await ask(p, b, "A", "back", timeout: 30)
            #expect(ContinuousClock.now - t0 < .seconds(10))   // refused up front, well before the 30 s timeout
            #expect(r.error?.code == .deadlock)
            #expect(r.error?.message == "Deadlock: 'A' is already waiting on 'B'; 'B' cannot ask 'A'")
            _ = try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("B")]))
            let first = try await pending.value
            #expect(first.error?.code == .notRunning)
        }
    }

    @Test func askTimesOut() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "B", preset: "claude", command: "sleep 999")
            try await connect(d, p, "A", "B")
            let t0 = ContinuousClock.now
            let r = try await ask(p, a, "B", "hi", timeout: 1)
            #expect(r.error?.code == .timeout)
            #expect(ContinuousClock.now - t0 < .seconds(10))   // B never answers: only the 1 s timeout ends it
        }
    }

    /// Readiness gate never opened (target silent): the timeout must say the prompt was never delivered.
    @Test func timeoutBeforeReadySaysNotDelivered() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "B", preset: "custom", command: "sh -c 'sleep 30'")
            try await connect(d, p, "A", "B")
            let r = try await ask(p, a, "B", "hi", timeout: 2)
            #expect(r.error == ProtocolError(code: .timeout, message: "'B' produced no output yet; prompt not delivered"), "\(r)")
        }
    }

    @Test func exitBeforeReadyFailsFast() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let t0 = ContinuousClock.now   // B exits ~1 s after spawn; < 20 s is well under the ask's 60 s timeout
            let b = try await spawn(d, p, "B", preset: "custom", command: #"sh -c "sleep 1; exit 0""#)
            try await connect(d, p, "A", "B")
            let r = try await ask(p, a, "B", "hi", timeout: 60)
            #expect(r.error?.code == .notRunning, "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(20))
            #expect(await d.process(UUID(uuidString: b.id)!)?.isRunning == false)
        }
    }

    @Test func askFailsFastWhenTargetExits() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "claude", command: #"sh -c "echo up; read x; exit 0""#)
            try await connect(d, p, "A", "B")
            // t0 after B's first output: the budget covers the readiness gate's quiet window, not B's startup
            #expect(await waitFor(5) { await d.scrollbackText(UUID(uuidString: b.id)!).contains("up") })
            let t0 = ContinuousClock.now
            let r = try await ask(p, a, "B", "bye", timeout: 30)
            #expect(r.error?.code == .notRunning)
            #expect(ContinuousClock.now - t0 < .seconds(10))   // fails on exit, well before the 30 s timeout
        }
    }

    @Test func asksToSameTargetAreSerialized() async throws {
        try await withHookDaemon { d, p in
            let b = try await term(d, p, "B", preset: "custom", command: fakeAgent(hook: true))
            var callers: [Term] = []
            for n in ["A", "C", "D"] { callers.append(try await term(d, p, n)); try await connect(d, p, n, "B") }
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            let results = try await withThrowingTaskGroup(of: (String, Response).self) { g in
                for (i, c) in callers.enumerated() {
                    g.addTask { ("p\(i)", try await ask(p, c, "B", "p\(i)", timeout: 20)) }
                }
                var out: [(String, Response)] = []
                for try await x in g { out.append(x) }
                return out
            }
            #expect(results.count == 3)
            for (prompt, r) in results {
                #expect(result(r).output == "answer:\(prompt)", "\(r)")
            }
        }
    }

    /// 1.5 MB (> the 1 MB cap) without newlines: `yes` output grew 1.5x on the wire via onlcr, and the
    /// PTY moves ~2.5 MB/s with spill in debug, which ate most of a 6 s budget under suite load (now 30 s).
    @Test func askMarksTruncated() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "B", preset: "custom", command: "echo up; read x; head -c 1572864 /dev/zero | tr '\\0' x; exec sleep 999")
            try await connect(d, p, "A", "B")
            let res = result(try await ask(p, a, "B", "go", timeout: 30))
            #expect(res.source == "idle", "\(res.output.prefix(300))")
            #expect(res.truncated == true)
        }
    }

    @Test func rejectsOutOfRangeNumbers() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await spawn(d, p, "B")
            try await connect(d, p, "A", "B")
            let r1 = try await send(p, Request(id: "1", terminalId: a.id, token: a.token, command: "ask",
                                               args: ["target": .string("B"), "prompt": .string("x"), "timeout": .number(1e30)]))
            #expect(r1.error?.code == .invalidArgs && r1.error?.message.contains("timeout") == true, "\(r1)")
            let r2 = try await send(p, Request(id: "2", terminalId: a.id, token: a.token, command: "check",
                                               args: ["target": .string("B"), "lines": .number(1e20)]))
            #expect(r2.error?.code == .invalidArgs && r2.error?.message.contains("lines") == true, "\(r2)")
            let l = try await send(p, Request(id: "3", terminalId: a.id, token: a.token, command: "list"))
            #expect(l.ok)
        }
    }

    /// The write stall is injected at 10 s (production: 2 s) so the bound on B's answer can be generous under load
    /// and still catch an actor blocked for the stall. Idle at 15 s: see `withHookDaemon`.
    @Test func writeStallDoesNotBlockOtherAsks() async throws {
        try await withDaemon(configure: { $0.writeStall = .seconds(10); $0.idleQuietSeconds = 15 }) { d, p in
            let a = try await term(d, p, "A")
            let xs = try await spawn(d, p, "X", preset: "claude", command: "echo up; exec sleep 60")
            let b = try await term(d, p, "B", preset: "custom", command: fakeAgent(hook: true))
            try await connect(d, p, "A", "X"); try await connect(d, p, "A", "B")
            let w = hookWatcher(d, p, b); defer { w.cancel() }
            // newline-separated so the canonical input queue fills and the PTY stops accepting bytes
            let big = String(repeating: "0123456789abcde\n", count: 5000)
            let stalled = Task { try await ask(p, a, "X", big, timeout: 30) }
            #expect(await waitFor(20) { await d.askBusy(UUID(uuidString: xs.id)!) })   // X's write is under way
            try await Task.sleep(for: .milliseconds(100))
            let t0 = ContinuousClock.now
            let r = try await ask(p, a, "B", "hello", timeout: 20)
            #expect(result(r).output == "answer:hello", "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(6))   // answer takes ~0.6 s; a 10 s actor stall fails this
            let x = try await stalled.value
            #expect(x.error == ProtocolError(code: .timeout, message: "target 'X' is not accepting input"), "\(x)")
        }
    }

    /// A timed-out turn that is still running keeps the slot: the next queued ask is not typed into the busy
    /// agent (its late hook would complete that ask) and fails with a clear "still busy" error.
    @Test func timedOutTurnHoldsSlotForNextQueued() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "claude", command: "echo up; exec sleep 999")
            try await connect(d, p, "A", "B")
            let bid = UUID(uuidString: b.id)!
            let first = Task { try await ask(p, a, "B", "first-prompt", timeout: 2) }
            #expect(await waitFor(15) { await d.scrollbackText(bid).contains("first-prompt") })   // delivered
            let second = Task { try await ask(p, a, "B", "second-prompt", timeout: 4) }
            #expect(try await first.value.error?.code == .timeout)   // held: B is still on that turn
            let r = try await second.value
            #expect(r.error?.code == .timeout)
            #expect(r.error?.message.contains("still busy") == true, "\(r)")
            #expect(!(await d.scrollbackText(bid).contains("second-prompt")))
        }
    }

    @Test func queuedAsksFailOnExit() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "claude", command: #"sh -c "echo up; read x; sleep 0.3; exit 0""#)
            try await connect(d, p, "A", "B")
            // t0 after B's first output: the budget covers the readiness gate's quiet window, not B's startup
            #expect(await waitFor(5) { await d.scrollbackText(UUID(uuidString: b.id)!).contains("up") })
            let t0 = ContinuousClock.now
            async let r1 = ask(p, a, "B", "one", timeout: 30)
            async let r2 = ask(p, a, "B", "two", timeout: 30)
            let (x, y) = try await (r1, r2)
            #expect(x.error?.code == .notRunning && y.error?.code == .notRunning, "\(x) \(y)")
            #expect(ContinuousClock.now - t0 < .seconds(10))   // both fail on exit, well before the 30 s timeout
        }
    }

    @Test func checkReturnsTail() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "custom", command: #"printf 'one\ntwo\nlast\n'; exec sleep 999"#)
            try await connect(d, p, "A", "B")
            #expect(await waitFor(20) { await d.scrollbackText(UUID(uuidString: b.id)!).contains("last") })
            let r = try await send(p, Request(id: "k", terminalId: a.id, token: a.token, command: "check",
                                              args: ["target": .string("B"), "lines": .number(1)]))
            let res = result(r)
            #expect(res.output == "last")
            #expect(res.truncated == false)
        }
    }
}

@Suite struct PasteModeTrackerTests {
    @Test func tracksLatestStateAcrossSplitReads() {
        let t = PasteModeTracker()
        t.feed(Data("x\u{1B}[?20".utf8)); #expect(!t.enabled)
        t.feed(Data("04hy".utf8)); #expect(t.enabled)
        t.feed(Data("\u{1B}[?2004l\u{1B}[?2004h".utf8)); #expect(t.enabled)
        t.feed(Data("\u{1B}[?2004".utf8)); t.feed(Data("l".utf8)); #expect(!t.enabled)
    }
}

@Suite struct SoakCompanionTests {
    /// In-process companion to the soak test (memoryBytes is invisible from outside the daemon): 5 agents x 20 asks.
    @Test func scrollbackMemoryStaysBounded() async throws {
        try await withHookDaemon { d, p in
            let ms = try await send(p, Request(id: "m", token: d.adminToken, command: "admin.spawn", args: [
                "name": .string("M"), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(true)]))
            guard case .object(let mo)? = ms.result, case .string(let mid)? = mo["id"] else { Issue.record("spawn \(ms)"); return }
            let m = Term(id: mid, token: try await tokenOf(d, mid))
            var agents: [Term] = [], watchers: [Task<Void, Never>] = []
            defer { watchers.forEach { $0.cancel() } }
            for i in 0..<5 {
                let t = try await term(d, p, "a\(i)", preset: "custom", command: fakeAgent(hook: true))
                try await connect(d, p, "M", "a\(i)")   // a Shepherd reaches only leashed terminals
                agents.append(t); watchers.append(hookWatcher(d, p, t))
            }
            await withTaskGroup(of: Void.self) { g in
                for i in 0..<5 { g.addTask {
                    for n in 0..<20 {
                        // try?, not try!: one slow ask under load must fail this test, not crash the whole run
                        let r = (try? await ask(p, m, "a\(i)", "q\(n)", timeout: 30)).map(result)?.output
                        #expect(r == "answer:q\(n)")
                    }
                } }
            }
            for a in agents {
                let mem = await d.scrollbackMemoryBytes(UUID(uuidString: a.id)!)
                #expect(mem > 0 && mem <= 1_048_576)
            }
        }
    }
}

// MARK: - ask --no-wait (plan 2X)

extension AskTests {

    @Test func noWaitReturnsImmediately() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            let t0 = ContinuousClock.now
            let (id, r) = try await askNoWait(p, a, "B", "work on it", timeout: 30)
            #expect(ContinuousClock.now - t0 < .milliseconds(500), "\(r)")
            #expect(id.count == 8 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(field(r, "target") == "B")
            #expect(field(try await askResult(p, a, id), "status") == "pending")
        }
    }

    @Test func noWaitDeliversReplyToAsker() async throws {
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A", preset: "claude", command: quietAgent)
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            let (id, _) = try await askNoWait(p, a, "B", "hello", timeout: 30)
            try await hook(d, p, b, "done")
            let head = "[collie] Reply from B (ask \(id)):"
            let aid = UUID(uuidString: a.id)!
            #expect(await waitFor(10) { await d.scrollbackText(aid).contains(head) })
            try await Task.sleep(for: .milliseconds(500))
            let text = await d.scrollbackText(aid)
            #expect(text.components(separatedBy: head).count == 2)   // typed once
            #expect(text[text.range(of: head)!.upperBound...].contains("done"))
            let res = try await askResult(p, a, id)
            #expect(field(res, "status") == "done" && field(res, "output") == "done")
        }
    }

    @Test func noWaitNotTypedMidTurn() async throws {
        try await withHookDaemon { d, p in
            // prints for ~5 s (a turn in progress), then reads quietly
            let busy = "echo T=$COLLIE_TOKEN; i=0; while [ $i -lt 50 ]; do echo tick; sleep 0.1; i=$((i+1)); done; exec cat >/dev/null"
            let a = try await term(d, p, "A", preset: "claude", command: busy)
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            let (id, _) = try await askNoWait(p, a, "B", "hello", timeout: 30)
            try await hook(d, p, b, "done")
            #expect(await waitFor(10) { (try? await askResult(p, a, id)).flatMap { field($0, "status") } == "done" })
            let aid = UUID(uuidString: a.id)!
            #expect(await waitFor(20) { await d.scrollbackText(aid).contains("[collie] Reply from B") })
            let text = await d.scrollbackText(aid)
            #expect(text.range(of: "tick", options: .backwards)!.lowerBound < text.range(of: "[collie] Reply from B")!.lowerBound)
        }
    }

    @Test func noWaitNotDeadlockEdge() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", preset: "claude", command: silentTarget)
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            _ = try await askNoWait(p, a, "B", "never answered", timeout: 30)
            #expect(await waitFor(10) { await d.askBusy(UUID(uuidString: b.id)!) })
            let r = try await ask(p, b, "A", "back", timeout: 1)
            #expect(r.error?.code != .deadlock, "\(r)")
        }
    }

    @Test func noWaitFailureDelivered() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", preset: "claude", command: quietAgent)
            _ = try await spawn(d, p, "B", preset: "claude", command: "sleep 999")
            try await connect(d, p, "A", "B")
            let (id, _) = try await askNoWait(p, a, "B", "hi", timeout: 1)
            let aid = UUID(uuidString: a.id)!
            #expect(await waitFor(10) { await d.scrollbackText(aid).contains("[collie] Ask \(id) to B failed: ") })
            let res = try await askResult(p, a, id)
            #expect(field(res, "status") == "failed" && field(res, "error") != nil)
        }
    }

    @Test func noWaitShellAskerNotTyped() async throws {
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            let (id, _) = try await askNoWait(p, a, "B", "hello", timeout: 30)
            try await hook(d, p, b, "done")
            #expect(await waitFor(10) { (try? await askResult(p, a, id)).flatMap { field($0, "status") } == "done" })
            try await Task.sleep(for: .seconds(3))   // past the quiet window a delivery waits for
            #expect(!(await d.scrollbackText(UUID(uuidString: a.id)!).contains("[collie]")))
            #expect(field(try await askResult(p, a, id), "output") == "done")
        }
    }

    @Test func longReplyCut() async throws {
        let long = String(repeating: String(repeating: "x", count: 49) + "\n", count: 100)   // 5000 chars
        let e = AskInbox.Entry(id: "ab12cd34", target: "B", status: .done, output: long)
        let m = AskInbox.message(e)
        let head = "[collie] Reply from B (ask ab12cd34):\n", cut = "\n[cut — full reply: collie ask result ab12cd34]"
        #expect(m.hasPrefix(head) && m.hasSuffix(cut) && m.count == head.count + 3000 + cut.count)
        #expect(AskInbox.message(AskInbox.Entry(id: "ab12cd34", target: "B", status: .done, output: "ok")) == head + "ok")
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A", preset: "claude", command: quietAgent)
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            let (id, _) = try await askNoWait(p, a, "B", "long", timeout: 30)
            try await hook(d, p, b, long)
            let aid = UUID(uuidString: a.id)!
            #expect(await waitFor(10) { await d.scrollbackText(aid).contains("[cut — full reply: collie ask result \(id)]") })
            #expect(field(try await askResult(p, a, id), "output")?.count == 5000)
        }
    }

    @Test func resultOnlyForAsker() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A"), c = try await term(d, p, "C")
            _ = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B"); try await connect(d, p, "C", "B")
            let (id, _) = try await askNoWait(p, a, "B", "hi", timeout: 30)
            #expect(try await askResult(p, c, id).error?.code == .notFound)
            #expect(try await askResult(p, a, id).ok)
        }
    }

    @Test func inboxKeepsTwenty() async {
        let inbox = AskInbox(), me = UUID(), other = UUID()
        var ids: [String] = []
        for _ in 0..<21 { ids.append(await inbox.open(from: me, target: "B")) }
        #expect(Set(ids).count == 21)
        #expect(await inbox.get(id: ids[0], from: me) == nil)
        #expect(await inbox.recent(from: me).map(\.id) == Array(ids.dropFirst().reversed()))
        #expect(await inbox.get(id: ids[1], from: other) == nil)
        await inbox.drop(terminal: me)
        #expect(await inbox.close(id: ids[1], .success(AskResult(output: "x", source: .hook, truncated: false))) == nil)
    }

    /// Review Focus 4: the asker is closed before the reply: nothing typed, no crash, the target goes on.
    @Test func askerRemovedDropsInbox() async throws {
        try await withHookDaemon { d, p in
            let a = try await term(d, p, "A", preset: "claude", command: quietAgent)
            let b = try await term(d, p, "B", preset: "claude", command: silentTarget)
            try await connect(d, p, "A", "B")
            _ = try await askNoWait(p, a, "B", "hello", timeout: 30)
            #expect(await waitFor(10) { await d.askBusy(UUID(uuidString: b.id)!) })
            let k = try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("A")]))
            #expect(k.ok)
            try await hook(d, p, b, "done")
            #expect(await waitFor(10) { !(await d.askBusy(UUID(uuidString: b.id)!)) })
            let l = try await send(p, Request(id: "l", terminalId: b.id, token: b.token, command: "list", args: [:]))
            #expect(l.ok)
        }
    }
}
