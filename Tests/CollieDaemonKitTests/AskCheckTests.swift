import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// C1: `ask --check`: the end of the target's turn does not close the ask; the daemon runs the check, and a red one sends
/// the output's tail back to the same target, up to `tries`.
@Suite(.serialized) struct AskCheckTests {
    private final class Calls: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func next() -> Int { l.withLock { n += 1; return n } }
        var count: Int { l.withLock { n } }
    }

    private func terminal(_ asks: AskCoordinator, _ name: String, preset: Preset) async throws -> (id: UUID, sb: ScrollbackBuffer) {
        let rec = TerminalRecord(id: UUID(), name: name, preset: preset, command: "cat", cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf ready; exec cat >/dev/null"], environment: [:], cwd: "/tmp"), scrollback: sb)
        await asks.attach(rec, process: p, scrollback: sb)
        return (rec.id, sb)
    }

    /// `reply`s as the target once an ask is in flight for it (the fake agent has no hook of its own).
    private func answer(_ asks: AskCoordinator, _ target: UUID, _ message: String) async {
        for _ in 0..<400 {
            if (try? await asks.reply(terminal: target, message: message)) != nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("no ask in flight to answer: \(message)")
    }

    private func typed(_ sb: ScrollbackBuffer, _ needle: String) async -> Bool {
        for _ in 0..<400 {
            if sb.snapshot().data.isEmpty == false, String(decoding: sb.snapshot().data, as: UTF8.self).contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func gate(_ command: String, tries: Int, dir: URL = URL(fileURLWithPath: "/tmp")) -> AskGate {
        AskGate(command: command, spec: nil, tries: tries, checkTimeout: .seconds(5), dir: dir)
    }

    private func red(_ out: String) -> ProcessResult { ProcessResult(status: 1, stdout: out, stderr: "", truncated: false) }
    private let green = ProcessResult(status: 0, stdout: "ok", stderr: "", truncated: false)

    /// Red once, green the second time: the target hears the output's tail, and the ask ends `passed` after 2 tries.
    @Test func checkThatFailsOnceThenPassesSendsTheTailAndPasses() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 15)
        let (a, _) = try await terminal(asks, "A", preset: .claude), (b, sb) = try await terminal(asks, "B", preset: .cursor)
        let calls = Calls()
        let run: AskCheckRun = { _, _, _ in calls.next() == 1 ? self.red("noise\nStraße → stra-e") : self.green }
        let t = Task { try await asks.askGated(from: a, to: b, prompt: "crie o slugify", raw: false, timeout: .seconds(20), gate: gate("make test", tries: 3), run: run) }
        await answer(asks, b, "pronto 1")
        #expect(await typed(sb, "O check falhou"), "no correction reached the target")
        #expect(await typed(sb, "stra-e"))
        await answer(asks, b, "pronto 2")
        let r = try await t.value
        #expect(r.output == "pronto 2" && r.check == AskCheckReport(status: .passed, tries: 2, tail: "ok"), "\(r)")
        #expect(calls.count == 2)
    }

    /// Red every time with `--tries 2`: the ask ends `failed`, with the last output's tail; the check ran twice.
    @Test func checkThatAlwaysFailsEndsFailedWithTheTail() async throws {
        let asks = AskCoordinator(idleQuietSeconds: 15)
        let (a, _) = try await terminal(asks, "A", preset: .claude), (b, sb) = try await terminal(asks, "B", preset: .cursor)
        let calls = Calls()
        let run: AskCheckRun = { _, _, _ in _ = calls.next(); return self.red("still red") }
        let t = Task { try await asks.askGated(from: a, to: b, prompt: "crie", raw: false, timeout: .seconds(20), gate: gate("make test", tries: 2), run: run) }
        await answer(asks, b, "pronto 1")
        #expect(await typed(sb, "O check falhou"))
        await answer(asks, b, "pronto 2")
        let r = try await t.value
        #expect(r.check == AskCheckReport(status: .failed, tries: 2, tail: "still red"), "\(String(describing: r.check))")
        #expect(calls.count == 2)
    }

    /// An attempt that edits a script the check's text names (one that existed before) fails with the reason: the check
    /// never runs on it.
    @Test func attemptThatEditsTheCheckScriptIsFailedWithTheReason() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("askcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("judge.sh")
        try "exit 1\n".write(to: script, atomically: true, encoding: .utf8)
        let asks = AskCoordinator(idleQuietSeconds: 15)
        let (a, _) = try await terminal(asks, "A", preset: .claude), (b, sb) = try await terminal(asks, "B", preset: .cursor)
        let calls = Calls()
        let run: AskCheckRun = { _, _, _ in _ = calls.next(); return self.green }
        let t = Task { try await asks.askGated(from: a, to: b, prompt: "crie", raw: false, timeout: .seconds(20), gate: gate("sh judge.sh", tries: 2, dir: dir), run: run) }
        for _ in 0..<400 where !(await asks.isBusy(b)) { try await Task.sleep(for: .milliseconds(25)) }   // the snapshot is taken by now
        try "exit 0\n".write(to: script, atomically: true, encoding: .utf8)   // the judged agent rewrites its judge
        await answer(asks, b, "pronto 1")
        #expect(await typed(sb, "judge.sh"))
        await answer(asks, b, "pronto 2")
        let r = try await t.value
        #expect(r.check?.status == .failed && r.check?.tries == 2 && r.check?.tail.contains("judge.sh") == true, "\(String(describing: r.check))")
        #expect(calls.count == 0, "the check ran on a tampered tree")
    }

    /// The inbox keeps the check on its entry (`ask result` shows it) and a failed one's notice points at the tail.
    @Test func inboxKeepsTheCheckOfAFailedAsk() async throws {
        let inbox = AskInbox()
        let from = UUID(), id = await inbox.open(from: from, target: "B")
        let c = AskCheckReport(status: .failed, tries: 2, tail: "still red")
        let e = try #require(await inbox.close(id: id, .failure(ProtocolError(code: .conflict, message: c.failure)), check: c))
        #expect(e.status == .failed && e.error == "check failed after 2 tries" && e.check == c)
        guard case .object(let o) = AskInbox.json(e), case .object(let j)? = o["check"] else { Issue.record("no check in the entry"); return }
        #expect(j["status"] == .string("failed") && j["tries"] == .number(2) && j["tail"] == .string("still red"))
        #expect(AskInbox.message(e).contains("collie ask result \(id)"))
    }

    @Test func askParamsParse() throws {
        let n = try ArgvParser.parse(["ask", "B", "do", "it", "--check", "make test", "--spec", "s.md", "--tries", "2", "--check-timeout", "30"])
        #expect(n.args["check"] == .string("make test") && n.args["spec"] == .string("s.md") && n.args["tries"] == .number(2) && n.args["check-timeout"] == .number(30), "\(n.args)")
    }
}
