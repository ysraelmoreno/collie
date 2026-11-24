import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A6: the auto-land's summary, written once, 0444, in the daemon's folder of the work (never the agent's tree), for
/// every stop of a `--auto-land` run, with one line to the owner; `work summary` (`WorkSummary.make`) reads the same
/// file. Fakes only (`LoopFakeHost`): no terminal.
@Suite struct AutoLandSummaryTests {
    private static func rig(title: String = "Task a", gate: String = "true", ci: String = "true") async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: title, check: "true")], tries: 1)
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec
            $0.loop?.review = true
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: gate, ci: ci, timeout: 60)
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        await r.host.setFactory(true)
        return r
    }

    /// The one summary of the run: its path on the loop, in `patchDir/autoland`, 0444, and its text.
    private static func summary(_ r: LoopRig, _ at: SourceLocation = #_sourceLocation) async throws -> (path: String, text: String) {
        let w = try await r.get()
        let path = try #require(w.loop?.autoLand?.summary, sourceLocation: at)
        let dir = r.host.patchDir(r.work).appendingPathComponent("autoland")
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, sourceLocation: at)
        #expect(!path.hasPrefix(r.repo.path), "never in the agent's tree", sourceLocation: at)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1, sourceLocation: at)
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o444, sourceLocation: at)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains(path), "\(notices)", sourceLocation: at)
        return (path, try String(contentsOfFile: path, encoding: .utf8))
    }

    @Test func aLandWritesTheSummaryOnceWithCommitsReviewAndTheRevertLine() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let (_, text) = try await Self.summary(r)
        #expect(text.contains("stopReason: landed"))
        #expect(text.contains("base antes: \(LoopFakeHost.landedBefore) · depois: \(LoopFakeHost.landedAfter)"))
        #expect(text.contains("reset --hard \(LoopFakeHost.landedBefore)") && text.contains("git -C "))
        #expect(text.contains("sem push; pronto para você revisar e dar push"))
        #expect(text.contains("Task a [done]: tentativas 1") && text.contains("aprovou: parecer"))
        #expect(text.contains("doctor no momento: static "))
        #expect(await r.host.ownerNotices[0].contains("integrou 1 trabalho"))
    }

    /// C2: a name taken is never replaced (`O_EXCL`): the next write takes `-1`, `-2` ... up to `-20`, then it throws.
    @Test func aTakenNameGetsASuffixAndKeepsTheFirst() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-a6-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "2026-11-24-101010.md"
        let url = try AutoLandSummary.write("primeiro\n", in: dir, name: name)
        let second = try AutoLandSummary.write("segundo\n", in: dir, name: name)
        #expect(second.lastPathComponent == "2026-11-24-101010-1.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "primeiro\n" && (try String(contentsOf: second, encoding: .utf8)) == "segundo\n")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o444)
        #expect((try FileManager.default.attributesOfItem(atPath: second.path)[.posixPermissions] as? Int) == 0o444)
        for n in 2...AutoLandSummary.maxSuffix {
            #expect(try AutoLandSummary.write("\(n)\n", in: dir, name: name).lastPathComponent == "2026-11-24-101010-\(n).md")
        }
        #expect(throws: (any Error).self) { try AutoLandSummary.write("demais\n", in: dir, name: name) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == AutoLandSummary.maxSuffix + 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "primeiro\n")
        #expect(AutoLandSummary.fileName(Date()).range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}\.md$"#, options: .regularExpression) != nil)
    }

    /// C2: every byte is written (short writes go on, `EINTR` is retried); a write that fails leaves no partial file.
    @Test func theWriteIsWholeOrNothing() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-c2-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        var calls = 0
        let url = try AutoLandSummary.write("abcdef\n", in: dir, name: "s.md") { fd, p, n in
            calls += 1
            if calls == 2 { errno = EINTR; return -1 }
            return Darwin.write(fd, p, min(n, 2))   // two bytes at a time
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "abcdef\n" && calls > 4)
        var sent = 0
        #expect(throws: (any Error).self) {
            try AutoLandSummary.write("abcdef\n", in: dir, name: "f.md") { fd, p, n in
                if sent > 0 { errno = ENOSPC; return -1 }
                sent = Darwin.write(fd, p, 3); return sent
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("f.md").path), "the partial file is unlinked")
    }

    /// C2: the owner's line goes through the scrub and names the stop's code.
    @Test func theOwnersLineIsScrubbedAndNamesTheCode() {
        let line = AutoLandSummary.ownerLine(title: "W vivo-xyz-987", stop: .init(.landCiRed, detail: "token=abc123segredo"), left: 0,
                                             path: "/r/s.md", error: nil, secrets: ["vivo-xyz-987"])
        #expect(!line.contains("vivo-xyz-987") && !line.contains("abc123segredo") && line.contains("[hidden]"), "\(line)")
        #expect(line.contains("[landCiRed]") && line.contains("parou em "), "\(line)")
        let landed = AutoLandSummary.ownerLine(title: "W", stop: .init(.maxReached), left: 0, path: nil, error: "x", landed: 2)
        #expect(landed.contains("integrou 2 trabalhos") && landed.contains("[maxReached]"), "\(landed)")
    }

    /// C2: a land whose `before` was not recorded still landed: "sem push" and the revert line with `?`, never "nada integrado".
    @Test func aLandWithNoBeforeStillSaysNoPush() {
        var w = Work(title: "W", terminalId: UUID(), branch: "main")
        w.tasks = [WorkTask(id: "a", title: "Task a", state: .done, tries: 1)]
        var loop = WorkLoopState(tries: 1, timeout: 60)
        loop.autoLand = WorkLoopState.AutoLand(gate: "true"); loop.autoLand?.after = "af"
        w.loop = loop
        let text = AutoLandSummary.text(w, started: Date(), ended: Date(), stop: .init(.landed), base: "/repo", doctor: nil)
        #expect(text.contains("sem push; pronto para você revisar e dar push") && text.contains("`git -C /repo reset --hard ?`"), "\(text)")
        #expect(!text.contains("nada integrado"))
    }

    /// C2: the registry unreadable at the end: no summary, but the owner still gets one (scrubbed) line.
    @Test func anUnreadableRegistryStillTellsTheOwner() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setSecrets(["vivo-xyz-987"])
        try Data("{ quebrado".utf8).write(to: r.storeDir.appendingPathComponent("work.json"))
        await r.loop.autoLandSummary(work: r.work, started: Date(), stop: .init(.landCiRed, detail: "vivo-xyz-987"), dir: r.repo, landing: true)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("Resumo não gravado") && notices[0].contains("[landCiRed]"), "\(notices)")
        #expect(notices[0].contains(r.work.uuidString.prefix(8).lowercased()) && !notices[0].contains("vivo-xyz-987"), "\(notices)")
        // a run that was no auto-land's tells nothing
        await r.loop.autoLandSummary(work: r.work, started: Date(), stop: nil, dir: r.repo)
        #expect(await r.host.ownerNotices.count == 1)
    }

    @Test func aRedCISaysWhichConditionsPassedAndWhichStopped() async throws {
        let r = try await Self.rig(ci: "echo quebrou; exit 3"); defer { r.cleanup() }
        #expect(await r.run() == .stopped)
        let (_, text) = try await Self.summary(r)
        #expect(text.contains("stopReason: landCiRed"))
        #expect(text.contains("condições que passaram: cercado fábrica, portão, revisão limpa de cada tarefa"))
        #expect(text.contains("parou em: CI local"))
        #expect(text.contains("nada integrado; sem push") && !text.contains("reset --hard"))
        #expect(await r.host.ownerNotices[0].contains("parou em "))
    }

    /// The reviewer's finding of attempt 1: a run that stops before the land writes its summary and tells the owner too.
    @Test func aStopBeforeTheLandStillWritesAndNotifies() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.max = 0 }
        #expect(await r.run() == .stopped)
        #expect(try await r.get().loop?.stopReason?.code == .maxReached)
        let (_, text) = try await Self.summary(r)
        #expect(text.contains("stopReason: maxReached") && text.contains("parou antes do land"))
        #expect(text.contains("tarefas não feitas: Task a"))
        #expect(await r.host.lands.isEmpty)
    }

    /// A `work stop` during the CI: the summary still goes, with the stop it got.
    @Test func aWorkStopDuringTheCIStillWrites() async throws {
        let r = try await Self.rig(ci: "echo ci"); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.setProbe { c in if c == "echo ci" { await loop.stop(work: id) } }
        #expect(await r.run() == .stopped)
        let (_, text) = try await Self.summary(r)
        #expect(text.contains("stopReason: requested"))
    }

    @Test func noAutoLandWritesNothing() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.autoLand = nil }
        _ = await r.run()
        #expect(try await r.get().loop?.autoLand == nil)
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(r.work).appendingPathComponent("autoland").path))
        #expect(await r.host.ownerNotices.isEmpty)
    }

    /// The end of the run itself (`autoLandSummary`, what `run` calls), with secrets in the titles: no agent runs, so
    /// the titles (which name the agent) are free.
    @Test func aSecretInTheTextNeverAppears() async throws {
        let r = try await Self.rig(title: "Task a token=abc123segredo"); defer { r.cleanup() }
        await r.host.setSecrets(["vivo-xyz-987"])
        try await r.store.update(r.work) { $0.title = "W vivo-xyz-987" }
        await r.loop.autoLandSummary(work: r.work, started: Date(), stop: .init(.landCiRed, detail: "password=hunter2"), dir: r.repo)
        let (_, text) = try await Self.summary(r)
        #expect(!text.contains("abc123segredo") && !text.contains("vivo-xyz-987"))
        #expect(text.contains("[hidden]"))
    }

    /// The vetoes come from the loop's own failure notes of the task: persona and arquivo:linha, as the review wrote them.
    @Test func theTextNamesWhoVetoedWhatAndWhoApproved() {
        var w = Work(title: "W", terminalId: UUID(), branch: "main")
        var t = WorkTask(id: "a", title: "Task a", state: .done, tries: 2)
        t.review = "parecer: sem veto (personas: correcao)"; t.reviewClean = true
        w.tasks = [t]
        w.notes = [WorkNote(at: Date(), text: "[loop a] Task a, tentativa 1/2: revisor recusou: [correcao] Sources/X.swift:42 falta teste (agente w-a-t1)\nfim da saída")]
        var loop = WorkLoopState(tries: 2, timeout: 60)
        loop.autoLand = WorkLoopState.AutoLand(gate: "true"); loop.autoLand?.before = "b4"; loop.autoLand?.after = "af"
        w.loop = loop
        let text = AutoLandSummary.text(w, started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 125),
                                        stop: .init(.landed, detail: "b4 -> af"), base: "/repo", doctor: "static 3/3")
        #expect(text.contains("vetou: [correcao] Sources/X.swift:42 falta teste"))
        #expect(text.contains("aprovou: parecer: sem veto (personas: correcao)"))
        #expect(text.contains("tentativas 2") && text.contains("duração: 2min05s"))
        #expect(text.contains("`git -C /repo reset --hard b4`"))
    }

    /// `work summary` (and the app's card, the chat) show the file's text: `WorkSummary.make` reads it from the loop's
    /// path, cut at `shownMax`, in the JSON and the markdown alike.
    @Test func workSummaryShowsTheFileItself() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-a6-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "# Auto-land: W\n" + String(repeating: "x", count: AutoLandSummary.shownMax + 500)
        let url = try AutoLandSummary.write(body, in: dir, name: "s.md")
        var w = Work(title: "W", terminalId: UUID(), branch: "main")
        var loop = WorkLoopState(tries: 1, timeout: 60)
        loop.autoLand = WorkLoopState.AutoLand(gate: "true"); loop.autoLand?.summary = url.path
        w.loop = loop
        let sum = WorkSummary.make(w, terminalAlive: false, now: Date())
        let shown = try #require(sum.autoLand)
        #expect(shown.hasPrefix("# Auto-land: W\nxxx") && shown.count <= AutoLandSummary.shownMax + 2)
        #expect(sum.markdown().contains("**Auto-land**") && sum.markdown().contains("# Auto-land: W"))
        let json = String(decoding: try JSONEncoder().encode(sum), as: UTF8.self)
        #expect(json.contains("Auto-land: W"))
        // a link in place of the file is not read
        let link = dir.appendingPathComponent("l.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(AutoLandSummary.read(link.path) == nil)
    }
}
