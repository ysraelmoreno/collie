import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// How a prompt reaches a fresh agent: what is written, when, and what happens when it isn't submitted.
@Suite struct PromptDeliveryTests {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock(); private var all: [Data] = []
        func add(_ d: Data) { lock.withLock { all.append(d) } }
        var chunks: [String] { lock.withLock { all.map { String(decoding: $0, as: UTF8.self) } } }
    }

    private func start(_ asks: AskCoordinator, preset: Preset, script: String) async throws -> (id: UUID, writes: Writes) {
        let rec = TerminalRecord(id: UUID(), name: "w", preset: preset, command: nil, cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", script], environment: [:], cwd: "/tmp"), scrollback: sb)
        await asks.attach(rec, process: p, scrollback: sb)
        let writes = Writes(), prev = p.onWrite
        p.onWrite = { o, d in writes.add(d); prev?(o, d) }
        return (rec.id, writes)
    }

    @Test func enterIsWrittenApartFromTheText() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1)
        let (id, w) = try await start(asks, preset: .shell, script: "printf ready; exec cat")
        try await asks.inject(to: id, prompt: "hi")
        #expect(w.chunks == ["hi", "\r"])
    }

    @Test func claudeQuietBeforeEnablingPasteIsNotReady() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.1)
        // a pause in the boot longer than the readiness quiet, then paste mode
        let (id, w) = try await start(asks, preset: .claude, script: "printf booting; sleep 1; printf '\\033[?2004h'; exec cat")
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        try await Task.sleep(for: .milliseconds(800))
        #expect(w.chunks.isEmpty)
        try await t.value
        #expect(w.chunks == ["\u{1B}[200~hi\u{1B}[201~", "\r"])
    }

    @Test func unsubmittedPromptFailsAndFreesTheQueue() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let (id, _) = try await start(asks, preset: .claude, script: "printf '\\033[?2004h'; exec cat")
        await asks.sessionHooked(id)
        do { try await asks.inject(to: id, prompt: "hi"); Issue.record("delivered") }
        catch { #expect(error.code == .unavailable && error.message.contains("did not submit"), "\(error)") }
        #expect(!(await asks.isBusy(id)))
    }

    @Test func submittedPromptIsDeliveredAndHoldsTheSlot() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 5)
        let (id, _) = try await start(asks, preset: .claude, script: "printf '\\033[?2004h'; exec cat")
        await asks.sessionHooked(id)
        let t = Task { try await asks.inject(to: id, prompt: "hi") }
        while !(await asks.isBusy(id)) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        await asks.promptSubmitted(id)
        try await t.value
        #expect(await asks.isBusy(id))
    }

    @Test func withoutHooksNothingIsReportedAsStuck() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2)
        let (id, _) = try await start(asks, preset: .claude, script: "printf '\\033[?2004h'; exec cat")
        try await asks.inject(to: id, prompt: "hi")   // no SessionStart seen: can't tell, as written
        #expect(await asks.isBusy(id))
    }

    @Test func taskToAFreshAgentDoesNotAnswerItsDialog() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 1)
        let (id, w) = try await start(asks, preset: .claude, script: "printf '\\033[?2004hDo you trust the files in this folder?\\n'; exec cat")
        let me = UUID()
        await #expect(throws: ProtocolError.self) { try await asks.ask(from: me, to: id, prompt: "implemente o painel", raw: false, timeout: .seconds(5)) }
        #expect(w.chunks.isEmpty)
        // a short answer still goes through (R7)
        _ = try? await asks.ask(from: me, to: id, prompt: "y", raw: false, timeout: .seconds(1))
        #expect(w.chunks.first == "\u{1B}[200~y\u{1B}[201~")
    }

    /// claude 2.1.314's dialog as printed: words apart by cursor moves.
    @Test func trustDialogDrawnWithCursorMovesIsDetectedAndLeftToTheUser() {
        let raw = "\u{1B}[2GYes,\u{1B}[7GI\u{1B}[9Gtrust\u{1B}[15Gthis\u{1B}[20Gfolder\r\n"
        #expect(ANSI.strip(raw) == "Yes, I trust this folder\n")
        var d = AttentionDetector(preset: .claude)
        let why = d.feed(ANSI.strip(raw))
        #expect(why == "trust this folder")
        #expect(AttentionDetector.kind(why!) == .unknown)
        #expect(AskCoordinator.keys(AttentionDetector.kind(why!), allow: true) == nil)
    }
}
