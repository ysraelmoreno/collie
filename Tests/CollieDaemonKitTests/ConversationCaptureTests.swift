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

/// A daemon with a temp home (never the real ~/.claude), an available fake curator, a shell terminal "dev" in a repo,
/// and the transcript path the terminal's hook would send.
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
private func withEnv(idle: Duration = .seconds(60), _ body: (Env) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("cc-home-\(UUID().uuidString.prefix(8))")
    let dir = home.appendingPathComponent(".claude/projects/-tmp-repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fake = FakeCurator()
    let repo = try await makeRepo()
    try await withDaemon(configure: { $0.curatorRunner = fake; $0.sandboxHome = home; $0.conversationIdle = idle }) { d, p in
        let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
            "name": .string("dev"), "preset": .string("shell"), "cwd": .string(repo.path)]), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"], let tid = UUID(uuidString: id) else {
            throw ProtocolError(code: .internal, message: "\(r)")
        }
        try await body(Env(d: d, p: p, fake: fake, tid: tid, token: try await tokenOf(d, id), transcript: dir.appendingPathComponent("s.jsonl"),
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
}
