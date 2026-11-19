import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func item(_ kind: String = "decision", _ title: String = "Usar Postgres", body: String = "porque o time já opera",
                  quote: String? = nil, dup: String? = nil) -> ConversationCapture.Item {
    .init(kind: kind, title: title, body: body, userQuote: quote, duplicateOf: dup)
}
private func out(_ items: [ConversationCapture.Item]) -> CuratorOutput {
    let json = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ConversationCapture.Output(items: items)))
    return CuratorOutput(json: json, inputTokens: 10, outputTokens: 5, costUSD: 0.0001)
}
private func line(_ o: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
}
private func user(_ t: String) -> String { line(["type": "user", "message": ["role": "user", "content": t]]) }
private func agent(_ t: String) -> String { line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": t]]]]) }
private func talk(_ n: Int, _ extra: String = "") -> String {
    (0..<n).map { user("mensagem \($0) sobre o banco \(extra)") + agent("ok \($0)") }.joined()
}

/// cursor-agent's line shape: the role at the top level, no `type`.
private func cursorTalk(_ n: Int) -> String {
    (0..<n).map { i in
        line(["role": "user", "message": ["content": [["type": "text", "text": "<user_query>\nmensagem \(i) sobre o banco\n</user_query>"]]]])
            + line(["role": "assistant", "message": ["content": [["type": "text", "text": "ok \(i)"]]]])
    }.joined()
}
private let cursorSession = "3f2a9c1e-7b4d-4e58-9a6b-0c1d2e3f4a5b"
private let cursorFile = ".cursor/projects/any-slug/agent-transcripts/\(cursorSession)/\(cursorSession).jsonl"

/// A daemon with a temp home (never the real ~/.claude), an available fake curator, a shell terminal "dev" in a repo,
/// and the transcript path the terminal's hook would send. `preset` other than shell: an agent terminal (a stand-in
/// command that prints its token); `at`: the transcript, relative to the home.
private struct Env {
    var d: Daemon, p: Paths, fake: FakeCurator, tid: UUID, token: String, transcript: URL, store: RepoMemory, root: URL
    var mark: UInt64? { ConversationCapture.marks(root.appendingPathComponent("memory/capture-marks.json"))[real] }
    var real: String {
        guard let r = realpath(transcript.path, nil) else { return transcript.path }
        defer { free(r) }
        return String(cString: r)
    }
    func records() async throws -> [MemoryRecord] { try await store.run { $0.store.all().records } }
    func size() throws -> UInt64 { UInt64(try Data(contentsOf: transcript).count) }
    /// Claude's Stop hook, as `collie hook claude-stop` sends it.
    func stop(_ path: String? = nil) async {
        let stdin = try! JSONSerialization.data(withJSONObject: ["transcript_path": path ?? transcript.path, "stop_hook_active": false,
                                                                  "last_assistant_message": "ok"])
        _ = await MemoryHookClient.stopOutput(stdin: stdin, env: ["COLLIE_SOCKET": p.socket.path, "COLLIE_TERMINAL_ID": tid.uuidString, "COLLIE_TOKEN": token])
    }
    @discardableResult
    func call(_ cmd: String, _ args: [String: String] = [:], admin: Bool = false) async throws -> Response {
        try await send(p, Request(id: "c", terminalId: admin ? nil : tid.uuidString, token: admin ? d.adminToken : token, command: cmd,
                                  args: args.mapValues { .string($0) }), timeoutSeconds: 30)
    }
    func hook(_ name: String) async throws {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["transcript_path": transcript.path, "hook_event_name": name]), as: UTF8.self)
        #expect(try await call("work.hook", ["hook": name, "payload": payload]).ok)
    }
}
private func withEnv(idle: Duration = .seconds(60), poll: Duration = .seconds(30), preset: String = "shell",
                     at file: String = ".claude/projects/-tmp-repo/s.jsonl",
                     _ body: (Env) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("cc-home-\(UUID().uuidString.prefix(8))")
    let transcript = home.appendingPathComponent(file), dir = transcript.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fake = FakeCurator()
    let repo = try await makeRepo()
    try await withDaemon(configure: { $0.curatorRunner = fake; $0.sandboxHome = home; $0.conversationIdle = idle
                                     $0.cursorTranscriptPoll = poll }) { d, p in
        var args: [String: JSONValue] = ["name": .string("dev"), "preset": .string(preset), "cwd": .string(repo.path)]
        if preset != "shell" { args["command"] = .string("echo T=$COLLIE_TOKEN; exec cat >/dev/null") }
        // sandbox-exec can't nest: run from inside a sandboxed Collie terminal (a loop's check), the terminal is a free one
        // (nothing here is about its sandbox; outside one it stays sandboxed, as before)
        if !canSandbox { args["sandbox"] = .string("free") }
        let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"], let tid = UUID(uuidString: id) else {
            throw ProtocolError(code: .internal, message: "\(r)")
        }
        try await body(Env(d: d, p: p, fake: fake, tid: tid, token: try await tokenOf(d, id, echo: preset == "shell"), transcript: transcript,
                           store: await d.router.memory.repo(for: repo.path), root: p.root))
    }
}

@Suite struct ConversationApplyTests {
    let chunk = "Usuário: eu prefiro respostas em português sempre\n\nAgente: ok"

    @Test func applyWritesActive() {
        let r = ConversationCapture.apply(.init(items: [item(), item("pitfall", "O build quebra sem --filter")]), chunk: chunk,
                                          candidates: [], terminal: "dev", secrets: [])
        #expect(r.count == 2)
        #expect(r.allSatisfy { $0.status == .active && $0.origin == "conversa (dev)" && $0.scope == .project })
        #expect(r.map(\.kind) == [.decision, .pitfall])
    }

    /// Task 9: the provider's cap reaches the builder: the newest part of the chunk is kept, the closing mark survives.
    @Test func smallInputMaxKeepsClosingMark() {
        let nonce = String(repeating: "d", count: 32), chunk = "Usuário: " + String(repeating: "z", count: 20_000)
        let i = ConversationCapture.input(chunk: chunk, candidates: [], nonce: nonce, inputMax: 3_000)
        #expect(i.unicodeScalars.count <= 3_000 && i.hasPrefix("DADOS-\(nonce)") && i.hasSuffix("\nDADOS-\(nonce)"))
    }

    @Test func conversationStampsCuratedBy() {
        let by = CuratedBy(provider: "claude", model: "haiku", trust: .full)
        let r = ConversationCapture.apply(.init(items: [item()]), chunk: chunk, candidates: [], terminal: "dev", secrets: [], curatedBy: by)
        #expect(r.count == 1 && r[0].curatedBy == by && r[0].status == .active)
    }

    /// A limited curator's findings wait for the user, decisions and pitfalls too.
    @Test func conversationLimitedIsProposed() {
        let by = CuratedBy(provider: "cursor", model: "", trust: .limited)
        let r = ConversationCapture.apply(.init(items: [item(), item("pitfall", "O build quebra sem --filter")]), chunk: chunk,
                                          candidates: [], terminal: "dev", secrets: [], curatedBy: by)
        #expect(r.count == 2 && r.allSatisfy { $0.status == .proposed && $0.curatedBy == by })
    }

    @Test func applyCapsAtFive() {
        let r = ConversationCapture.apply(.init(items: (0..<8).map { item("decision", "D\($0)") }), chunk: chunk, candidates: [], terminal: "dev", secrets: [])
        #expect(r.count == 5)
    }

    @Test func applyDropsUnknownKind() {
        let r = ConversationCapture.apply(.init(items: [item("procedure"), item("map"), item("bogus"), item()]), chunk: chunk,
                                          candidates: [], terminal: "dev", secrets: [])
        #expect(r.map(\.kind) == [.decision])
    }

    @Test func applyDropsFeedbackWithoutQuote() {
        let items = [item("feedback", "Responder em português"), item("feedback", "Responder em inglês", quote: "eu prefiro respostas em inglês"),
                     item("feedback", "Agente disse", quote: "ok")]
        #expect(ConversationCapture.apply(.init(items: items), chunk: chunk, candidates: [], terminal: "dev", secrets: []).isEmpty)
        // a quote from the agent's text is not the user's
        let c2 = "Usuário: faça\n\nAgente: o usuário prefere tabs sempre"
        #expect(ConversationCapture.apply(.init(items: [item("feedback", "Tabs", quote: "o usuário prefere tabs sempre")]), chunk: c2,
                                          candidates: [], terminal: "dev", secrets: []).isEmpty)
    }

    /// R19: the user's kind is never made active by a conversation: a proposal for the user to confirm.
    @Test func applyKeepsFeedbackWithQuoteInChunk() {
        let r = ConversationCapture.apply(.init(items: [item("feedback", "Responder em português", quote: "Eu prefiro  respostas em português")]),
                                          chunk: chunk, candidates: [], terminal: "dev", secrets: [])
        #expect(r.map(\.kind) == [.feedback])
        #expect(r.first?.status == .proposed)
    }

    @Test func applySkipsDuplicateOfCandidate() {
        let known = UUID()
        let r = ConversationCapture.apply(.init(items: [item(dup: known.uuidString), item("decision", "Outra")]), chunk: chunk,
                                          candidates: [known], terminal: "dev", secrets: [])
        #expect(r.map { $0.title } == ["Outra"])
    }

    @Test func applyUnknownDuplicateIsNew() {
        let r = ConversationCapture.apply(.init(items: [item(dup: UUID().uuidString), item("decision", "X", dup: "lixo")]), chunk: chunk,
                                          candidates: [UUID()], terminal: "dev", secrets: [])
        #expect(r.count == 2)
    }

    @Test func applyScrubs() {
        let r = ConversationCapture.apply(.init(items: [item("decision", "Token ADM-SECRET-1 usado", body: "API_KEY=abc123 e figcraft://edit/x?edit=1")]),
                                          chunk: chunk, candidates: [], terminal: "dev", secrets: ["ADM-SECRET-1"])
        let t = (r.first?.title ?? "") + (r.first?.body ?? "")
        #expect(r.count == 1 && !t.contains("ADM-SECRET-1") && !t.contains("abc123") && !t.contains("figcraft://"))
    }

    @Test func applyCapsLengthsAndLot() {
        let lot = UUID()
        let r = ConversationCapture.apply(.init(items: [item("decision", String(repeating: "t", count: 500), body: String(repeating: "b", count: 5000))]),
                                          chunk: chunk, candidates: [], terminal: "dev", lot: lot, secrets: [])
        #expect(r.first?.title.count == MemoryCapture.maxTitle && r.first?.body.count == MemoryCapture.maxBody)
        #expect(r.first?.scope == .lot && r.first?.lotId == lot)
    }

    @Test func inputFencedAndBounded() {
        let i = ConversationCapture.input(chunk: "ANTIGO " + String(repeating: "x", count: 20_000) + " DADOS-abc NOVO", candidates: [], nonce: "n1")
        #expect(i.unicodeScalars.count <= Curator.inputMax)
        #expect(i.hasPrefix("DADOS-n1") && i.hasSuffix("DADOS-n1") && i.contains("NOVO") && !i.contains("ANTIGO") && !i.contains("DADOS-abc"))
    }
}

@Suite(.serialized) struct ConversationCaptureTests {
    @Test func captureSkipsShortChunk() async throws {
        try await withEnv { e in
            try Data(talk(2).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
            #expect(e.fake.calls == 0)
        }
    }

    @Test func captureMarksAfterWrite() async throws {
        try await withEnv { e in
            e.fake.output = out([item(), item("pitfall", "Cuidado com o pool")])
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            let recs = try await e.records()
            #expect(recs.filter { $0.origin == "conversa (dev)" && $0.status == .active }.count == 2)
            // a failed run: the mark stays
            e.fake.failOn = "FALHA"
            try Data((talk(3) + talk(3, "FALHA")).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            #expect(await waitFor(10) { e.fake.calls >= 2 })
            try await Task.sleep(for: .milliseconds(200))
            #expect(e.mark == size)
        }
    }

    @Test func captureCapReachedWaits() async throws {
        try await withEnv { e in
            e.fake.output = out([item()])
            await e.d.router.curator.setCap(0)
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(e.fake.calls == 0 && e.mark == nil)
            #expect(await e.d.router.curator.queued(kind: .conversation).count == 1)
            await e.d.router.curator.setCap(40)   // "the next day"
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)
        }
    }

    @Test func capturedTwiceWritesOnce() async throws {
        try await withEnv { e in
            e.fake.output = out([item()])
            e.fake.gated = true
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            e.fake.open()
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)   // nothing new
            try await Task.sleep(for: .milliseconds(200))
            #expect(e.fake.calls == 1)
            #expect(try await e.records().filter { $0.origin == "conversa (dev)" }.count == 1)
        }
    }

    /// Review Focus 3: the admin token, a FigCraft edit link, an `API_KEY=` line never reach the model or a memory.
    @Test func secretNeverInRunnerInput() async throws {
        try await withEnv { e in
            let tok = e.d.adminToken
            e.fake.output = out([item("decision", "Token \(tok)", body: "API_KEY=sekret99")])
            try Data((talk(2) + user("o token é \(tok)\nAPI_KEY=sekret99\nlink figcraft://file/1?edit=abc")).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            #expect(await waitFor(10) { e.fake.calls == 1 })
            let input = try #require(e.fake.inputs.first)
            #expect(input.contains("o token é") && !input.contains(tok) && !input.contains("sekret99") && !input.contains("figcraft://"))
            #expect(await waitFor(10) { e.mark != nil })
            for r in try await e.records() { #expect(!(r.title + r.body).contains(tok) && !(r.title + r.body).contains("sekret99")) }
        }
    }

    /// Review Focus 1: a symlink to a key, or a path outside `<config>/projects`: nothing read, nothing sent.
    @Test func badTranscriptPathIgnored() async throws {
        try await withEnv { e in
            let key = e.transcript.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("id_ed25519")
            try Data(talk(5).utf8).write(to: key)
            let link = e.transcript.deletingLastPathComponent().appendingPathComponent("evil.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
            for p in [link.path, "/etc/passwd", key.path] {
                await e.d.router.captureConversation(e.tid, transcript: p, force: true)
            }
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
            #expect(e.fake.calls == 0)
        }
    }

    @Test func idleTenMinutesTriggers() async throws {
        #expect(DaemonConfig(paths: Paths(root: URL(fileURLWithPath: "/tmp/x")), collieExecutable: URL(fileURLWithPath: "/tmp/c"),
                             workspaceId: UUID()).conversationIdle == .seconds(600))
        try await withEnv(idle: .milliseconds(300)) { e in
            e.fake.output = out([item()])
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.stop()
            #expect(e.fake.calls == 0)
            #expect(await waitFor(10) { e.fake.calls == 1 })
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
        }
    }

    @Test func newTurnResetsIdle() async throws {
        try await withEnv(idle: .milliseconds(600)) { e in
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.stop()
            try await Task.sleep(for: .milliseconds(300))
            await e.stop()
            try await Task.sleep(for: .milliseconds(400))
            #expect(e.fake.calls == 0)   // the first timer would have fired by now
            #expect(await waitFor(10) { e.fake.calls == 1 })
        }
    }

    /// Review Focus 5: a quick Q&A then idle: no model call.
    @Test func quickTurnNoModelCall() async throws {
        try await withEnv(idle: .milliseconds(100)) { e in
            try Data(talk(2).utf8).write(to: e.transcript)
            await e.stop()
            try await Task.sleep(for: .milliseconds(500))
            #expect(e.fake.calls == 0 && e.mark == nil)
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
        }
    }

    @Test func precompactTriggersForced() async throws {
        try await withEnv { e in
            try Data(talk(1).utf8).write(to: e.transcript)
            try await e.hook("precompact")
            #expect(await waitFor(10) { e.fake.calls == 1 })
        }
    }

    @Test func sessionEndTriggersForced() async throws {
        try await withEnv { e in
            try Data(talk(1).utf8).write(to: e.transcript)
            try await e.hook("session-end")
            #expect(await waitFor(10) { e.fake.calls == 1 })
        }
    }

    /// Review Focus 2: compaction three times, then the end: each chunk read once, nothing written twice.
    @Test func compactionsThenEndReadEachChunkOnce() async throws {
        try await withEnv { e in
            e.fake.output = out([item()])
            var all = ""
            for i in 0..<3 {
                all += talk(1, "parte\(i)")
                try Data(all.utf8).write(to: e.transcript)
                try await e.hook("precompact")
                let size = try e.size()
                #expect(await waitFor(10) { e.mark == size })
            }
            try await e.hook("session-end")   // nothing new
            try await Task.sleep(for: .milliseconds(300))
            #expect(e.fake.calls == 3)
            for (i, input) in e.fake.inputs.enumerated() {
                #expect(input.contains("parte\(i)") && (0..<3).filter { $0 != i }.allSatisfy { !input.contains("parte\($0)") })
            }
            #expect(try await e.records().filter { $0.origin == "conversa (dev)" }.count == 3)
        }
    }

    @Test func workDoneTriggersForced() async throws {
        try await withEnv { e in
            try Data(talk(1).utf8).write(to: e.transcript)
            await e.stop()   // remembers the transcript (idle: 60 s)
            #expect(try await e.call("work.start", ["title": "login"]).ok)
            #expect(try await e.call("work.done").ok)
            #expect(await waitFor(10) { e.fake.calls == 1 })
        }
    }

    @Test func memoryCaptureCommandForced() async throws {
        try await withEnv { e in
            e.fake.output = out([])
            try Data(talk(1).utf8).write(to: e.transcript)
            let none = try await e.call("memory.capture")
            #expect(!none.ok && none.error?.code == .notFound)   // no Claude conversation seen yet
            await e.stop()
            #expect(try await e.call("memory.capture").ok)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            try Data((talk(1) + talk(1, "mais")).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.capture", ["terminal": "dev"], admin: true).ok)
            #expect(await waitFor(10) { e.fake.calls == 2 })
            #expect(try await e.call("memory.capture", ["terminal": "nobody"], admin: true).error?.code == .notFound)
        }
    }

    /// A Codex (or shell) terminal sends no transcript: no idle capture, `memory.capture` refused, work done calls nothing.
    @Test func codexTerminalNeverTriggers() async throws {
        try await withEnv(idle: .milliseconds(100)) { e in
            try Data(talk(5).utf8).write(to: e.transcript)
            #expect(try await e.call("turn.completed", ["source": "codex", "message": "feito"]).ok)
            #expect(try await e.call("memory.capture").error?.code == .notFound)
            #expect(try await e.call("work.start", ["title": "x"]).ok)
            #expect(try await e.call("work.done").ok)
            try await Task.sleep(for: .milliseconds(500))
            #expect(e.fake.calls == 0)
        }
    }

    /// Review Focus 1 through the hook: a Stop naming a symlink to a key never leads to a read or a call.
    @Test func badTranscriptPathFromHookIgnored() async throws {
        try await withEnv(idle: .milliseconds(100)) { e in
            let key = FileManager.default.temporaryDirectory.appendingPathComponent("cc-key-\(UUID().uuidString.prefix(8))")
            try Data(talk(5).utf8).write(to: key)
            defer { try? FileManager.default.removeItem(at: key) }
            let link = e.transcript.deletingLastPathComponent().appendingPathComponent("evil.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
            await e.stop(link.path)
            try await Task.sleep(for: .milliseconds(500))
            #expect(e.fake.calls == 0)
            #expect(try await e.call("memory.capture").ok)   // the remembered path is still vetted
            try await Task.sleep(for: .milliseconds(300))
            #expect(e.fake.calls == 0 && e.mark == nil)
        }
    }

    /// Aprendido rows in the digest, one job: Desfazer on one discards exactly the records that job created.
    @Test func digestEntriesAndUndo() async throws {
        try await withEnv { e in
            let other = MemoryRecord(kind: .decision, subject: "outra", title: "Outra decisão")
            try await e.store.run { try $0.store.write(other) }
            e.fake.output = out([item(), item("pitfall", "Cuidado com o pool")])
            try Data(talk(3).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: false)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            let rows = await e.d.router.digest.since(.distantPast).filter { $0.action == "aprendido" }
            #expect(rows.count == 2 && Set(rows.compactMap(\.job)).count == 1 && rows.allSatisfy { $0.store == e.store.key })
            let created = Set(rows.flatMap(\.created))
            #expect(created == Set(try await e.records().filter { $0.origin == "conversa (dev)" }.map(\.id)))
            _ = try await e.d.router.undoDigest(try #require(rows.first).id)
            let recs = try await e.records()
            #expect(recs.filter { created.contains($0.id) }.allSatisfy { $0.status == .discarded })
            #expect(recs.first { $0.id == other.id }?.status == .active)
        }
    }

    /// A trigger while that transcript's job runs is queued, not dropped: one follow-up job for the new part.
    @Test func triggerDuringRunCoalescesIntoFollowUp() async throws {
        try await withEnv { e in
            e.fake.output = out([])
            e.fake.gated = true
            try Data(talk(3, "primeira").utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            #expect(await waitFor(10) { e.fake.calls == 1 })   // running, held
            let first = try e.size()
            try Data((talk(3, "primeira") + talk(1, "segunda")).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            e.fake.open()
            let size = try e.size()
            #expect(size > first)
            #expect(await waitFor(10) { e.mark == size })
            try await Task.sleep(for: .milliseconds(200))
            #expect(e.fake.calls == 2)
            #expect(e.fake.inputs.last?.contains("segunda") == true && e.fake.inputs.last?.contains("primeira") == false)
        }
    }

    /// C2: a Cursor sessionStart names the transcript: `memory.capture` then learns from it like a Claude one.
    @Test func cursorSessionStartRegistersTranscript() async throws {
        try await withEnv(preset: "cursor", at: cursorFile) { e in
            e.fake.output = out([item()])
            try Data(cursorTalk(1).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.capture").error?.message == "no conversation seen for 'dev' yet")
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            #expect(try await e.call("memory.capture").ok)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)   // one conversation job
            #expect(e.fake.inputs.first?.contains("mensagem 0 sobre o banco") == true)
            #expect(try await e.records().filter { $0.origin == "conversa (dev)" }.count == 1)
            #expect(await e.d.router.digest.since(.distantPast).filter { $0.action == "aprendido" }.count == 1)
        }
    }

    /// A `.jsonl` outside Cursor's `projects` dir (here under Claude's): remembered, refused when vetted, no job.
    @Test func cursorTranscriptOutsideProjectsIsRefused() async throws {
        try await withEnv(preset: "cursor") { e in
            try Data(cursorTalk(5).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            #expect(try await e.call("memory.capture").ok)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
            #expect(e.fake.calls == 0 && e.mark == nil)
        }
    }

    /// No `transcript_path`, only the session id: the file under any project slug is found once it exists.
    @Test func cursorSessionIdFindsTranscript() async throws {
        try await withEnv(preset: "cursor", at: cursorFile) { e in
            e.fake.output = out([])
            #expect(try await e.call("memory.hookContext", ["session": cursorSession]).ok)
            #expect(try await e.call("memory.capture").error?.code == .notFound)   // no file yet: nothing remembered
            try Data(cursorTalk(1).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.hookContext", ["session": "../../\(cursorSession)"]).ok)
            #expect(try await e.call("memory.capture").error?.code == .notFound)   // not a UUID: never a path piece
            #expect(try await e.call("memory.hookContext", ["session": cursorSession]).ok)
            #expect(try await e.call("memory.capture").ok)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)
        }
    }

    /// Only a Cursor terminal reads under `.cursor`: a Claude one's transcript under `.claude/projects` is still captured.
    @Test func claudeTerminalStillUsesClaudeProjects() async throws {
        try await withEnv(preset: "claude") { e in
            e.fake.output = out([])
            try Data(talk(1).utf8).write(to: e.transcript)
            await e.d.router.captureConversation(e.tid, transcript: e.transcript.path, force: true)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)
        }
    }

    /// C3: no hook and no `memory.capture`: the registered transcript growing is the trigger, then the idle capture.
    @Test func cursorTranscriptGrowthCapturesAfterIdle() async throws {
        try await withEnv(idle: .milliseconds(20), poll: .milliseconds(20), preset: "cursor", at: cursorFile) { e in
            e.fake.output = out([])
            try Data(cursorTalk(3).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            try Data((cursorTalk(3) + cursorTalk(1)).utf8).write(to: e.transcript)
            let size = try e.size()
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)   // one conversation job
        }
    }

    /// The size at registration is the baseline: a transcript that does not grow queues nothing.
    @Test func cursorTranscriptUnchangedQueuesNothing() async throws {
        try await withEnv(idle: .milliseconds(20), poll: .milliseconds(20), preset: "cursor", at: cursorFile) { e in
            try Data(cursorTalk(3).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            try await Task.sleep(for: .milliseconds(400))
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
            #expect(e.fake.calls == 0 && e.mark == nil)
        }
    }

    /// Growth, but fewer than 3 user messages since the mark: the idle capture waits for more (as for Claude).
    @Test func cursorShortChunkWaits() async throws {
        try await withEnv(idle: .milliseconds(20), poll: .milliseconds(20), preset: "cursor", at: cursorFile) { e in
            try Data(cursorTalk(1).utf8).write(to: e.transcript)
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            try Data(cursorTalk(2).utf8).write(to: e.transcript)
            try await Task.sleep(for: .milliseconds(400))
            #expect(await e.d.router.curator.queued(kind: .conversation).isEmpty)
            #expect(e.fake.calls == 0 && e.mark == nil)
        }
    }

    /// The terminal ends (no session-end hook on Cursor): what is left is captured at once, however short, no idle wait.
    @Test func cursorTerminalEndCapturesNow() async throws {
        try await withEnv(preset: "cursor", at: cursorFile) { e in   // idle 60 s, poll 30 s: only the end can capture
            e.fake.output = out([])
            #expect(try await e.call("memory.hookContext", ["transcript": e.transcript.path]).ok)
            try Data(cursorTalk(1).utf8).write(to: e.transcript)
            let size = try e.size()
            #expect(try await e.call("admin.kill", ["target": "dev"], admin: true).ok)
            #expect(await waitFor(10) { e.mark == size })
            #expect(e.fake.calls == 1)
        }
    }
}
