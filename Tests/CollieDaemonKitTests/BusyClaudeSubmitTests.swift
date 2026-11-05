import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// DX backlog 16: a prompt written while Claude is mid-turn is queued by Claude (no UserPromptSubmit until that turn
/// ends): not "did not submit", and the running turn's Stop is not its reply.
@Suite struct BusyClaudeSubmitTests {
    private func start(_ asks: AskCoordinator) async throws -> UUID {
        let rec = TerminalRecord(id: UUID(), name: "w", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf '\\033[?2004h'; exec cat"], environment: [:], cwd: "/tmp"),
                               scrollback: sb)
        await asks.attach(rec, process: p, scrollback: sb)
        await asks.sessionHooked(rec.id)
        await asks.promptSubmitted(rec.id)   // the user's own prompt: a turn is running
        return rec.id
    }

    @Test func promptQueuedDuringATurnIsNotReportedUnsubmitted() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let id = try await start(asks)
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        try await Task.sleep(for: .seconds(3))   // past submitConfirm and the echo's working window: the agent quiet
        #expect(await asks.isBusy(id))
        await asks.turnCompleted(terminal: id, message: "the user's turn")
        await asks.promptSubmitted(id)   // Claude sends the queued prompt
        try await t.value
    }

    @Test func runningTurnsStopIsNotTheAsksReply() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let id = try await start(asks)
        let t = Task { try await asks.ask(from: UUID(), to: id, prompt: "question", raw: false, timeout: .seconds(10)) }
        while !(await asks.isBusy(id)) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))   // written
        await asks.turnCompleted(terminal: id, message: "the user's turn")
        try await Task.sleep(for: .milliseconds(300))
        await asks.promptSubmitted(id)
        try await Task.sleep(for: .milliseconds(300))
        await asks.turnCompleted(terminal: id, message: "the answer")
        #expect(try await t.value.output == "the answer")
    }

    @Test func notSubmittedAfterTheTurnEndsStillFails() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let id = try await start(asks)
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        try await Task.sleep(for: .milliseconds(800))
        await asks.turnCompleted(terminal: id, message: "the user's turn")
        do { try await t.value; Issue.record("delivered") }
        catch let e as ProtocolError { #expect(e.code == .unavailable && e.message.contains("did not submit"), "\(e)") }
    }
}
