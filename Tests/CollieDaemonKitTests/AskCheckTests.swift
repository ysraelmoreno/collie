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

    /// F5: a field's land in the report (and its JSON); none without one, and an old entry decodes.
    @Test func fieldNoteInReport() throws {
        var c = AskCheckReport(status: .passed, tries: 1, tail: "ok")
        guard case .object(let bare) = c.json else { Issue.record("no object"); return }
        #expect(bare["field"] == nil)
        c.field = FieldNote(land: .queued)
        guard case .object(let o) = c.json, case .object(let f)? = o["field"] else { Issue.record("no field in \(c.json)"); return }
        #expect(f["land"] == .string("queued") && f["reason"] == .null)
        c.field = FieldNote(land: .skipped, reason: "já integrando")
        #expect(try JSONDecoder().decode(AskCheckReport.self, from: JSONEncoder().encode(c)) == c)
        let old = #"{"status":"passed","tries":1,"tail":"ok"}"#
        #expect(try JSONDecoder().decode(AskCheckReport.self, from: Data(old.utf8)).field == nil)
    }

    @Test func askParamsParse() throws {
        let n = try ArgvParser.parse(["ask", "B", "do", "it", "--check", "make test", "--spec", "s.md", "--tries", "2", "--check-timeout", "30"])
        #expect(n.args["check"] == .string("make test") && n.args["spec"] == .string("s.md") && n.args["tries"] == .number(2) && n.args["check-timeout"] == .number(30), "\(n.args)")
    }

    // MARK: C2: a check that already passes before the attempt measures nothing

    /// Green on the target's folder before anything is sent: refused, with the reason; the check ran once.
    @Test func greenCheckBeforeTheAttemptIsRefused() async throws {
        let calls = Calls()
        let run: AskCheckRun = { _, _, _ in _ = calls.next(); return self.green }
        do {
            try await gate("true", tries: 3).refuseIfGreen(run: run)
            Issue.record("a check that passes before the task was accepted")
        } catch {
            #expect(error.code == .invalidArgs && error.message.contains("o check já passa antes da tarefa: não mede o que ela muda") && error.message.contains("--green-ok"), "\(error)")
        }
        #expect(calls.count == 1)
    }

    /// Red (or a check that cannot even run) before the attempt: it goes on.
    @Test func redCheckBeforeTheAttemptGoesOn() async throws {
        let missing: AskCheckRun = { _, _, _ in self.red("no such file") }
        try await gate("false", tries: 3).refuseIfGreen(run: missing)
        let slow: AskCheckRun = { _, _, _ throws(ProtocolError) in throw ProtocolError(code: .timeout, message: "slow") }
        try await gate("false", tries: 3).refuseIfGreen(run: slow)
    }

    /// `--green-ok`: the check is not even run first (a refactoring's check stays green).
    @Test func greenOkSkipsTheInitialRun() async throws {
        let calls = Calls()
        var g = gate("true", tries: 3); g.greenOk = true
        let run: AskCheckRun = { _, _, _ in _ = calls.next(); return self.green }
        try await g.refuseIfGreen(run: run)
        #expect(calls.count == 0)
    }

    @Test func greenOkFlagParses() throws {
        let n = try ArgvParser.parse(["ask", "B", "do", "it", "--check", "true", "--green-ok"])
        #expect(n.args["green-ok"] == .bool(true), "\(n.args)")
    }

    private func ask(_ d: Daemon, _ p: Paths, from: (id: String, token: String), _ args: [String: JSONValue], drop: String? = nil) async throws -> Response {
        var a: [String: JSONValue] = ["target": .string("B"), "prompt": .string("crie o slugify"), "check": .string("true")]
        for (k, v) in args { a[k] = v }
        if let drop { a[drop] = nil }
        return try await send(p, Request(id: "a", terminalId: from.id, token: from.token, command: "ask", args: a))
    }

    /// Through the daemon: `ask --check true` is refused and the target is never typed to; with `--green-ok` it goes out.
    @Test func daemonRefusesAGreenCheckAndSendsWithGreenOk() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A", preset: "shell"), b = try await spawn(d, p, "B", preset: "shell")
            let ta = (id: a.id, token: try await tokenOf(d, a.id, echo: true))
            _ = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")]))
            let refused = try await ask(d, p, from: ta, ["no-wait": .bool(true)])
            #expect(refused.error?.code == .invalidArgs && refused.error?.message.contains("já passa antes da tarefa") == true, "\(refused)")
            #expect(await !d.scrollbackText(UUID(uuidString: b.id)!).contains("crie o slugify"), "the target was typed to")
            let ok = try await ask(d, p, from: ta, ["no-wait": .bool(true), "green-ok": .bool(true)])
            #expect(ok.ok, "\(ok)")
            #expect(await waitFor(20) { await d.scrollbackText(UUID(uuidString: b.id)!).contains("crie o slugify") })
            // without --check, --green-ok means nothing
            let bare = try await ask(d, p, from: ta, ["green-ok": .bool(true)], drop: "check")
            #expect(bare.error?.code == .invalidArgs, "\(bare)")
        }
    }
}
