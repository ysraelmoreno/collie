import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// F3, `work task add --accept`: the runtime acceptance, kept in the work's state, run after the check and the gate
/// (never with either red), a failure as a check's with its whole output, guarded against tampering like the gate, and
/// the 4th condition of the auto-land. Hosts are fakes (`LoopFakeHost`): no terminal, no `sandbox-exec`.
@Suite struct AcceptTests {
    private typealias Script = LoopScript

    private static func rig(check: String = "true", accept: String?, gate: String? = nil, tries: Int = 1) async throws -> LoopRig {
        var t = WorkTask(id: "a", title: "Task a", check: check)
        t.accept = accept
        let r = try await LoopRig([t], tries: tries, gate: gate)
        await r.host.set("w-task-a-t1", Script(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        return r
    }

    // MARK: the field

    @Test func theFieldIsValidatedAsTheCheckAndKeptInTheState() throws {
        #expect(CommandRouter.acceptRefusal("curl -fsS localhost:8080/health") == nil)
        #expect(CommandRouter.acceptRefusal("a &&\n\tb") == nil)   // a newline and a tab are a command's
        #expect(CommandRouter.acceptRefusal("") != nil)
        #expect(CommandRouter.acceptRefusal(String(repeating: "x", count: CommandRouter.maxWorkText + 1)) != nil)
        #expect(CommandRouter.acceptRefusal("echo \u{1B}[31m") != nil)
        #expect(CommandRouter.acceptRefusal("echo \u{07}") != nil)
        // kept (and read back) with the task, its result too
        var t = WorkTask(id: "a", title: "T", check: "true")
        t.accept = "scripts/accept.sh"; t.acceptTimeout = 900; t.acceptPassed = true; t.acceptResult = "passou (exit 0)"
        let back = try JSONDecoder().decode(WorkTask.self, from: try JSONEncoder().encode(t))
        #expect(back == t)
        // a malformed one is nil and the task survives (tolerant, like the newer fields)
        let bad = #"{"id":"a","title":"T","updatedAt":0,"state":"open","accept":7,"acceptTimeout":"x","acceptPassed":"sim"}"#
        let read = try JSONDecoder().decode(WorkTask.self, from: Data(bad.utf8))
        #expect(read.accept == nil && read.acceptTimeout == nil && read.acceptPassed == nil)
        // what the owner reads
        #expect(WorkStatusText.acceptLabel(t) == " · aceite «scripts/accept.sh» até 900 s (último: passou (exit 0))")
        #expect(WorkStatusText.acceptLabel(WorkTask(id: "b", title: "T")) == "")
    }

    // MARK: the order

    @Test func aPassedAcceptanceRunsAfterTheCheckAndTheGate() async throws {
        let r = try await Self.rig(check: "echo check", accept: "echo SERVICO OK", gate: "echo gate"); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["echo check", "echo gate", "echo SERVICO OK"])
        #expect(w.tasks[0].state == .done && w.tasks[0].acceptPassed == true && w.tasks[0].acceptResult == "passou (exit 0)")
        #expect(w.tasks[0].evidence?.acceptOutput == "SERVICO OK")
        let kinds = w.loop?.events?.map(\.kind) ?? []
        #expect(kinds.contains(.acceptStarted) && kinds.contains(.acceptPassed) && !kinds.contains(.acceptFailed))
        // the agent never sees it: its prompt has the task, never the acceptance
        let prompt = await r.host.prompts["w-task-a-t1"] ?? ""
        #expect(!prompt.isEmpty && !prompt.contains("SERVICO"))
    }

    @Test func aRedCheckRunsNoAcceptance() async throws {
        let r = try await Self.rig(check: "false", accept: "echo accept"); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["false"])
        #expect(w.tasks[0].state == .deferred && w.tasks[0].acceptPassed == nil)
        #expect(w.loop?.events?.contains { $0.kind == .acceptStarted } == false)
    }

    @Test func aRedGateRunsNoAcceptance() async throws {
        let r = try await Self.rig(accept: "echo accept", gate: "exit 4"); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["true", "exit 4"])
        #expect(w.tasks[0].state == .deferred && w.tasks[0].acceptPassed == nil)
    }

    // MARK: the failure

    @Test func aFailingAcceptanceFailsTheAttemptWithItsWholeOutput() async throws {
        // 300 lines: far past the 40 a check's note keeps
        let r = try await Self.rig(accept: "for i in $(seq 1 300); do echo linha-$i; done; echo GH_TOKEN=ghp_abcdefgh123456; exit 3", tries: 2)
        defer { r.cleanup() }
        await r.host.set("w-task-a-t2", Script(act: { try await commit("b.swift", "let b = 1\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].tries == 2)
        #expect(w.tasks[0].acceptPassed == false && w.tasks[0].acceptResult == "falhou (exit 3)")
        #expect(w.tasks[0].lastFailure?.contains("accept failed (exit 3)") == true)
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop a]") && $0.text.contains("tentativa 1/2") })
        #expect(note.text.contains("linha-1\n") && note.text.contains("linha-150\n") && note.text.contains("linha-300"), "\(note.text.prefix(300))")
        #expect(!note.text.contains("ghp_abcdefgh123456") && note.text.contains("[hidden]"))
        #expect(w.loop?.events?.contains { $0.kind == .acceptFailed && $0.detail == "exit 3" } == true)
        // the next attempt's prompt carries what failed
        #expect((await r.host.prompts["w-task-a-t2"] ?? "").contains("linha-1\n"))
    }

    @Test func theOutputIsBoundedHeadAndTail() {
        let big = "INICIO\n" + String(repeating: "abcdefghij\n", count: 10_000) + "FIM"
        let out = WorkLoop.acceptOutput(big)
        #expect(out.utf8.count <= WorkLoop.acceptChars + 100)
        #expect(out.hasPrefix("INICIO") && out.hasSuffix("FIM") && out.contains("bytes cortados no meio"))
        #expect(WorkLoop.acceptOutput("\u{1B}[32mok\u{1B}[0m\n") == "ok")
        // a multi-byte character cut in half leaves no replacement character behind
        let wide = WorkLoop.acceptOutput(String(repeating: "é", count: WorkLoop.acceptChars))
        #expect(!wide.contains("\u{FFFD}"))
    }

    // MARK: the agent and the command

    /// The acceptance names a script of the base: an attempt that rewrote it is failed as at the gate, and the command
    /// never runs on that tree.
    @Test func anAttemptThatChangesWhatTheAcceptanceRunsFails() async throws {
        let r = try await Self.rig(accept: "bash accept.sh"); defer { r.cleanup() }
        try await commit("accept.sh", "exit 1\n", in: r.repo)
        await r.host.set("w-task-a-t1", Script(act: { try await commit("accept.sh", "exit 0\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["true"])
        #expect(w.tasks[0].state == .deferred && w.tasks[0].acceptPassed == false)
        #expect(w.tasks[0].lastFailure?.contains("a tentativa alterou «accept.sh», que o aceite executa") == true)
    }

    /// The loop runs the command it holds in the work's state; a file the agent leaves in the tree is never read.
    /// C4a: and one it commits that the acceptance names (absent from the base) fails the attempt before anything runs.
    @Test func theCommandComesFromTheStateNeverFromTheTree() async throws {
        let r = try await Self.rig(accept: "test ! -f collie-accept.txt"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", Script(act: { d in
            try "true\n".write(to: d.appendingPathComponent("collie-accept.txt"), atomically: true, encoding: .utf8)
            try await commit("collie-accept.txt", "true\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["true"])
        #expect(w.tasks[0].accept == "test ! -f collie-accept.txt" && w.tasks[0].state == .deferred)
        #expect(w.tasks[0].lastFailure?.contains("cita «collie-accept.txt»") == true)
    }

    /// C4a: the acceptance names a script the base does not have: the attempt that creates it would write what judges
    /// it. Failed with the reason, the command never run, even when the spec names the file.
    @Test func anAcceptanceOfAScriptTheBaseLacksFails() async throws {
        let r = try await Self.rig(accept: "bash scripts/accept.sh"); defer { r.cleanup() }
        try await commit("spec.md", "crie scripts/accept.sh\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) { $0.tasks[0].spec = spec }
        await r.host.set("w-task-a-t1", Script(act: { d in
            try FileManager.default.createDirectory(at: d.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try await commit("scripts/accept.sh", "exit 0\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["true"])
        #expect(w.tasks[0].state == .deferred && w.tasks[0].acceptPassed == false)
        #expect(w.tasks[0].lastFailure?.contains("o aceite cita «scripts/accept.sh» que não existe no commit base: crie-o numa tarefa anterior e commite") == true,
                "\(w.tasks[0].lastFailure ?? "")")
    }

    /// C4a: a huge failed acceptance: the whole output in a file, the note only its head and tail (3000 characters),
    /// and the next prompt never more than 4000 characters of acceptance notes in all.
    @Test func aHugeAcceptanceOutputGoesToAFileAndTheNoteKeepsHeadAndTail() async throws {
        let r = try await Self.rig(accept: "echo INICIO; for i in $(seq 1 5000); do echo linha-$i; done; echo FIM; exit 3", tries: 3)
        defer { r.cleanup() }
        await r.host.set("w-task-a-t2", Script(act: { try await commit("b.swift", "let b = 1\n", in: $0) }))
        await r.host.set("w-task-a-t3", Script(act: { try await commit("c.swift", "let c = 1\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        let notes = w.notes.filter { $0.text.hasPrefix("[loop a]") }
        #expect(notes.count == 3)
        for n in notes {
            let out = try #require(n.text.range(of: WorkLoop.acceptMark).map { String(n.text[$0.upperBound...]) })
            #expect(out.hasPrefix("INICIO") && out.hasSuffix("FIM") && out.count < WorkLoop.acceptNoteChars + 300, "\(out.count)")
            #expect(out.contains("saída inteira em ") && !out.contains("linha-2500\n"))
        }
        let file = r.host.patchDir(r.work).appendingPathComponent("accept-output/a-1.txt")
        let whole = try String(contentsOf: file, encoding: .utf8)
        #expect(whole.contains("linha-2500\n") && whole.hasPrefix("INICIO") && whole.hasSuffix("FIM"))
        #expect(notes[0].text.contains(file.path))
        // the third attempt's prompt: two notes of ~3000 characters, at most 4000 of them together
        let prompt = await r.host.prompts["w-task-a-t3"] ?? ""
        #expect(prompt.components(separatedBy: WorkLoop.acceptMark).count - 1 == 2)
        let sum = WorkLoop.promptNotes(Array(notes.prefix(2))).compactMap { t in t.range(of: WorkLoop.acceptMark).map { t[$0.upperBound...].count } }.reduce(0, +)
        #expect(sum <= WorkLoop.acceptPromptChars, "\(sum)")
        #expect(prompt.contains("FIM"))
        #expect(prompt.count < WorkLoop.acceptPromptChars + 2500, "\(prompt.count)")
    }

    /// A work with no `--accept` runs exactly as before: no acceptance event, nothing recorded on the task.
    @Test func aWorkWithNoAcceptanceIsUnchanged() async throws {
        let r = try await Self.rig(accept: nil, gate: "echo gate"); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.commands == ["true", "echo gate"])
        #expect(w.tasks[0].state == .done && w.tasks[0].acceptPassed == nil && w.tasks[0].acceptResult == nil)
        #expect(w.tasks[0].evidence?.acceptOutput == nil)
        #expect(w.loop?.events?.contains { [.acceptStarted, .acceptPassed, .acceptFailed].contains($0.kind) } == false)
    }

    // MARK: the auto-land

    /// Every task already done and reviewed clean at HEAD, the auto-land on: only the acceptance decides.
    private static func landRig(accept: String?, passed: Bool?) async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1)
        let head = try await GitRunner.run(["rev-parse", "HEAD"], in: r.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await r.store.update(r.work) {
            $0.tasks[0].state = .done; $0.tasks[0].reviewClean = true; $0.tasks[0].review = "parecer: sem veto"; $0.tasks[0].reviewedHead = head
            $0.tasks[0].accept = accept; $0.tasks[0].acceptPassed = passed; $0.tasks[0].acceptResult = passed.map { $0 ? "passou (exit 0)" : "falhou (exit 1)" }
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60)
        }
        await r.host.setFactory(true)
        return r
    }

    private static func summary(_ r: LoopRig) async throws -> String {
        let path = try #require(try await r.get().loop?.autoLand?.summary)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test func anAcceptanceNotPassedStopsTheLand() async throws {
        for passed in [false, nil] as [Bool?] {
            let r = try await Self.landRig(accept: "echo up", passed: passed); defer { r.cleanup() }
            #expect(await r.run() == .stopped)
            let w = try await r.get()
            #expect(w.loop?.stopReason?.code == .landAcceptRed, "\(String(describing: w.loop?.stopReason))")
            #expect(w.loop?.stopReason?.detail?.contains("Task a") == true)
            #expect(await r.host.lands.isEmpty && w.loop?.autoLand?.after == nil)
            let text = try await Self.summary(r)
            #expect(text.contains("landAcceptRed") && text.contains("parou em: aceite em runtime") && text.contains("aceite em runtime: "))
            #expect(!text.contains("sem aceite em runtime"))
        }
    }

    @Test func aPassedAcceptanceLands() async throws {
        let r = try await Self.landRig(accept: "echo up", passed: true); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(try await r.get().loop?.stopReason?.code == .landed)
        #expect(await r.host.lands == [.merge])
        #expect(try await Self.summary(r).contains("aceite em runtime: passou (exit 0)"))
    }

    @Test func aWorkWithNoAcceptanceLandsAsBeforeAndSaysSo() async throws {
        let r = try await Self.landRig(accept: nil, passed: nil); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(try await r.get().loop?.stopReason?.code == .landed)
        #expect(try await Self.summary(r).contains("sem aceite em runtime"))
    }

    @Test func aStoppedLandWithNoAcceptanceDoesNotListItAsPassed() async throws {
        let r = try await Self.landRig(accept: nil, passed: nil); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.autoLand?.ci = "exit 2" }
        #expect(await r.run() == .stopped)
        let text = try await Self.summary(r)
        #expect(text.contains("parou em: CI local") && !text.contains("passaram: cercado fábrica, portão, revisão limpa de cada tarefa, aceite"))
    }
}
