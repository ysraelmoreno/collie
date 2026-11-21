import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// M2.0: a Claude prompt written and not submitted (no UserPromptSubmit, the agent quiet) has its Enter sent again,
/// once, before the ask fails with "did not submit". Never while the agent prints, shows an approval, or has no hooks.
@Suite struct AskSubmitRetryTests {
    private final class Log<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock(); private var all: [T] = []
        func add(_ x: T) { lock.withLock { all.append(x) } }
        var items: [T] { lock.withLock { all } }
    }

    private static let enter = Data("\r".utf8)
    /// A Claude TUI that enabled bracketed paste, takes what is typed and never submits by itself.
    private static let quiet = "printf '\\033[?2004h'; exec cat"

    /// A coordinator (short `submitConfirm`) with one Claude target running `script`: what was written to it and the
    /// ask events emitted.
    private func start(script: String = quiet, hooked: Bool = true) async throws -> (asks: AskCoordinator, id: UUID, writes: Log<Data>, events: Log<MemoryEvent>) {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let events = Log<MemoryEvent>()
        asks.askEvents.set { events.add($0) }
        let rec = TerminalRecord(id: UUID(), name: "w", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", script], environment: [:], cwd: "/tmp"), scrollback: sb)
        await asks.attach(rec, process: p, scrollback: sb)
        let writes = Log<Data>(), prev = p.onWrite
        p.onWrite = { o, d in writes.add(d); prev?(o, d) }
        if hooked { await asks.sessionHooked(rec.id) }
        return (asks, rec.id, writes, events)
    }

    private func enters(_ w: Log<Data>) -> Int { w.items.filter { $0 == Self.enter }.count }
    private func retries(_ e: Log<MemoryEvent>) -> [MemoryEvent] { e.items.filter { $0.type == .submitRetried } }

    /// (a) quiet and no UserPromptSubmit: one more Enter (the prompt is not typed again); the hook that follows it
    /// delivers the prompt as usual.
    @Test func quietUnsubmittedPromptGetsOneMoreEnterAndGoesOn() async throws {
        let (asks, id, w, events) = try await start()
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        #expect(await waitFor(10) { enters(w) == 2 })
        #expect(w.items.count == 3, "the prompt is written once: \(w.items.map { String(decoding: $0, as: UTF8.self) })")
        #expect(await asks.submitRetried(id))
        await asks.promptSubmitted(id)
        try await t.value   // delivered, not "did not submit"
        #expect(await asks.isBusy(id))
        #expect(enters(w) == 2 && retries(events).count == 1)
    }

    /// (b) still nothing after the retry: fails as before, after exactly one retry; (d) the retry is an event that
    /// names the terminal and the ask.
    @Test func stillUnsubmittedAfterTheRetryFailsWithOneRetryOnly() async throws {
        let (asks, id, w, events) = try await start()
        do { try await asks.inject(to: id, prompt: "hi"); Issue.record("delivered") }
        catch { #expect(error.code == .unavailable && error.message.contains("did not submit"), "\(error)") }
        #expect(!(await asks.isBusy(id)))
        #expect(enters(w) == 2 && w.items.count == 3)
        let r = retries(events)
        #expect(r.count == 1 && r.first?.terminal == id && r.first?.ask != nil)
    }

    /// (c) an agent that prints is working (it may have queued the prompt): no Enter, no failure.
    @Test func printingAgentGetsNoRetry() async throws {
        let (asks, id, w, events) = try await start(script: "printf '\\033[?2004h'; read x; while :; do printf .; sleep 0.2; done")
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        defer { t.cancel() }
        #expect(await waitFor(10) { enters(w) == 1 })
        // M2b.2: kept at 3 s. The absence is only proved past `StreamHub.workingWindow` (2 s, shared with the
        // terminals' status, not a parameter of the coordinator): before it the prompt's own echo counts as printing
        // and a quiet agent gets no Enter either. A shorter window would race this shell's 0.2 s prints against the
        // scheduler, and fail under load; this sleep cannot (load only delays an Enter that must not come).
        try await Task.sleep(for: .seconds(3))   // well past submitConfirm and a working window
        #expect(enters(w) == 1 && retries(events).isEmpty)
        #expect(await asks.isBusy(id))
        #expect(!(await asks.submitRetried(id)))
    }

    /// (c) an approval shown after the prompt was written: an Enter would answer it. As before: delivered as written.
    @Test func pendingApprovalGetsNoRetry() async throws {
        let (asks, id, w, events) = try await start()
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        #expect(await waitFor(10) { enters(w) == 1 })
        await asks.hookPermission(id, message: "Claude needs your permission to use Bash")
        try await t.value
        #expect(await asks.hasPendingApproval(id))
        #expect(enters(w) == 1 && retries(events).isEmpty)
    }

    /// (c) no SessionStart seen: this Claude's hooks may not work, nothing proves the prompt is stuck. As before.
    @Test func sessionWithoutHooksGetsNoRetry() async throws {
        let (asks, id, w, events) = try await start(hooked: false)
        try await asks.inject(to: id, prompt: "hi")
        #expect(await asks.isBusy(id))
        // M2b.2: no sleep. A Claude prompt's inject returns only when `confirmSubmit` (the one sender of the second
        // Enter) has decided and returned, as in `pendingApprovalGetsNoRetry`: nothing is left that could send one.
        #expect(enters(w) == 1 && retries(events).isEmpty)
    }

    // MARK: - the loop's journal

    private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

    /// (d) the loop's ask went through a retry: its journal says so, with the terminal's name.
    @Test func loopJournalsTheRetry() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.setResubmitted("w-task-a-t1")
        #expect(await r.run() == .finished)
        let ev = try await r.get().loop?.events ?? []
        let i = try #require(ev.firstIndex { $0.kind == .resubmitted })
        #expect(ev[i].detail == "w-task-a-t1" && ev[i].task == "a" && ev[i].attempt == 1)
        #expect(ev.filter { $0.kind == .resubmitted }.count == 1)
        #expect(ev[..<i].contains { $0.kind == .agentSummoned } && ev[i...].contains { $0.kind == .turnEnded || $0.kind == .commitSeen })
    }

    @Test func loopWithoutRetryJournalsNone() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(!(try await r.get().loop?.events ?? []).contains { $0.kind == .resubmitted })
    }

    /// The new kind round-trips, and one this daemon does not know still decodes (as `unknown`).
    @Test func resubmittedKindDecodesTolerantly() throws {
        let e = LoopEvent(at: Date(timeIntervalSince1970: 1), kind: .resubmitted, task: "a", attempt: 1, detail: "w-task-a-t1")
        #expect(try JSONDecoder().decode(LoopEvent.self, from: JSONEncoder().encode(e)) == e)
        #expect(try JSONDecoder().decode(LoopEvent.Kind.self, from: Data(#""resubmitted""#.utf8)) == .resubmitted)
        #expect(try JSONDecoder().decode(LoopEvent.Kind.self, from: Data(#""resubmittedTwice""#.utf8)) == .unknown)
    }
}
