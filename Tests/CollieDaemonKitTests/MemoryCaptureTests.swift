import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var name: String; var token: String; var uuid: UUID { UUID(uuidString: id)! }
    func env(_ p: Paths) -> [String: String] { ["COLLIE_SOCKET": p.socket.path, "COLLIE_TERMINAL_ID": id, "COLLIE_TOKEN": token] }
}
private func fx(_ n: String) -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-hooks/\(n).json")
    return (try? Data(contentsOf: url)) ?? Data()
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
@discardableResult
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    let r = try await send(p, Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                           timeoutSeconds: 60)
    #expect(r.ok, "\(cmd): \(r)")
    return r
}
/// A done task in `t`'s active work (opening one if needed).
private func doneTask(_ p: Paths, _ t: Term, _ title: String) async throws {
    try await call(p, t, "work.task.add", ["title": title])
    try await call(p, t, "work.task.done", ["task": title])
}
private func stop(_ p: Paths, _ t: Term, _ fixture: String = "stop") async -> String? {
    await MemoryHookClient.stopOutput(stdin: fx(fixture), env: t.env(p))
}
private func reason(_ out: String?) -> String? {
    guard let out, let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], o["decision"] as? String == "block" else { return nil }
    return o["reason"] as? String
}
/// Proposals in `store`, once at least `count` are there.
private func proposals(_ store: RepoMemory, count: Int = 1) async throws -> [MemoryRecord] {
    func read() async -> [MemoryRecord] { (try? await store.run { $0.store.all().records.filter { $0.status == .proposed } }) ?? [] }
    _ = await waitFor(10) { await read().count >= count }
    return await read()
}

@Suite(.serialized) struct MemoryCaptureTests {
    @Test func candidatesFromDoneNotes() {
        let t0 = Date()
        var w = Work(title: "Login", terminalId: UUID(), notes: [
            WorkNote(at: t0, text: "Context compacted"),
            WorkNote(at: t0, text: "Done: sessões ficam no Redis, não em cookies"),
            WorkNote(at: t0, text: "Escolhemos argon2 para senhas", decision: true),
            WorkNote(at: t0, text: "rodei os testes")], commits: ["abc123 feat: login form", "def456 fix: csrf"])
        w.tasks = [WorkTask(id: "a", title: "OAuth", state: .deferred, reason: "falta a chave do Google", updatedAt: t0),
                   WorkTask(id: "b", title: "SMS", state: .abandoned, reason: "o provedor bloqueia números novos", updatedAt: t0),
                   WorkTask(id: "c", title: "form", state: .done, updatedAt: t0)]
        let lot = UUID()
        let c = MemoryCapture.candidates(work: w, since: .distantPast, terminal: "T", lot: lot)
        #expect(c.map(\.title) == ["sessões ficam no Redis, não em cookies", "Escolhemos argon2 para senhas", "Adiado: OAuth", "Abandonado: SMS"])
        #expect(c.map(\.kind) == [.decision, .decision, .decision, .pitfall])
        #expect(c.allSatisfy { $0.status == .proposed && $0.origin == "captura (T)" && $0.scope == .lot && $0.lotId == lot })
        // commit subjects: body context only, never a memory of their own
        #expect(c.allSatisfy { $0.body.contains("Commits: abc123 feat: login form; def456 fix: csrf") && $0.body.contains("Trabalho: Login") })
        #expect(c[2].body.hasPrefix("falta a chave do Google"))
        let project = MemoryCapture.candidates(work: w, since: .distantPast, terminal: "T", lot: nil)
        #expect(project.allSatisfy { $0.scope == .project && $0.lotId == nil })
    }

    @Test func noCandidatesWithoutNewWork() {
        let t0 = Date()
        var w = Work(title: "Login", terminalId: UUID(), notes: [WorkNote(at: t0, text: "Done: x"), WorkNote(at: t0, text: "Context compacted")],
                     commits: ["abc123 one"])
        w.tasks = [WorkTask(id: "a", title: "OAuth", state: .deferred, reason: "later", updatedAt: t0),
                   WorkTask(id: "b", title: "open one", updatedAt: t0.addingTimeInterval(5))]
        #expect(MemoryCapture.candidates(work: w, since: t0, terminal: "T", lot: nil).isEmpty)
        w.notes.append(WorkNote(at: t0.addingTimeInterval(9), text: "Session ended"))
        #expect(MemoryCapture.candidates(work: w, since: t0, terminal: "T", lot: nil).isEmpty)
        // the chunk mark: nothing done and no commit after it is no new work
        #expect(MemoryCapture.hasNewWork(w))   // the commit, never captured
        w.capturedAt = t0.addingTimeInterval(10); w.capturedCommit = "abc123 one"
        #expect(!MemoryCapture.hasNewWork(w))
        w.commits.append("fff000 two")
        #expect(MemoryCapture.hasNewWork(w) && MemoryCapture.newCommits(w) == ["fff000 two"])
    }

    /// Review Focus 3: at most one ask per chunk; never on a continued Stop; never twice in a row.
    @Test func stopAsksOncePerChunk() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            #expect(await stop(p, t) == nil)   // no work at all
            try await doneTask(p, t, "login form")
            #expect(reason(await stop(p, t)) == MemoryCapture.stopReasonNoLot)
            #expect(await stop(p, t) == nil)   // second Stop, no new work
            #expect(await stop(p, t, "stop-continued") == nil)
            try await doneTask(p, t, "csrf")
            #expect(await stop(p, t, "stop-continued") == nil)   // stop_hook_active: never, even with new work
            #expect(reason(await stop(p, t)) != nil)   // that work is still a chunk not asked about
            #expect(await stop(p, t) == nil)
            #expect(await stop(p, t) == nil)
            // malformed stdin: a plain turn end, no block
            try await doneTask(p, t, "logout")
            #expect(await MemoryHookClient.stopOutput(stdin: Data("not json".utf8), env: t.env(p)) == nil)
            // fail open: no daemon, no block
            #expect(await MemoryHookClient.stopOutput(stdin: fx("stop"), env: ["COLLIE_SOCKET": "/tmp/none.sock", "COLLIE_TERMINAL_ID": t.id,
                                                                                "COLLIE_TOKEN": t.token]) == nil)
            #expect(await MemoryHookClient.stopOutput(stdin: fx("stop"), env: [:]) == nil)
        }
    }

    @Test func stopSkipsWhenAgentSaved() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await doneTask(p, t, "login form")
            try await call(p, t, "memory.save", ["kind": "decision", "subject": "sessions", "title": "Sessions in Redis"])
            #expect(await stop(p, t) == nil)
            #expect(await stop(p, t) == nil)   // the chunk is marked: no later ask about it
            try await doneTask(p, t, "csrf")
            #expect(reason(await stop(p, t)) != nil)   // a new chunk without a save of its own: asked
        }
    }

    @Test func stopAskTextNamesCommands() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "T"]).ok)
            try await doneTask(p, t, "login form")
            let out = try #require(await stop(p, t))
            #expect(reason(out) == "Antes de encerrar: registre decisões e armadilhas deste trabalho com collie memory save --scope lot (ou responda 'nada a registrar').")
            #expect(!out.contains("\n"))   // one JSON line on stdout
            #expect(HookPayload.claudeStopHookActive(stdinJSON: fx("stop-continued")) == true && HookPayload.claudeStopHookActive(stdinJSON: fx("stop")) == false)
            #expect(HookPayload.claudeStopHookActive(stdinJSON: Data("x".utf8)) == nil)
        }
    }

    @Test func workDoneCreatesProposals() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await call(p, t, "work.task.add", ["title": "OAuth"])
            try await call(p, t, "work.task.defer", ["task": "OAuth", "reason": "falta a chave do Google"])
            try await call(p, t, "work.done", ["reason": "sessões no Redis"])
            let store = await d.router.memory.repo(for: repo.path)
            let recs = try await proposals(store, count: 2)
            #expect(Set(recs.map(\.title)) == ["sessões no Redis", "Adiado: OAuth"], "\(recs)")
            #expect(recs.allSatisfy { $0.origin == "captura (T)" && $0.scope == .project && !$0.reviewed })
            // proposed: never injected, and it replaced nothing
            let ctx = try await call(p, t, "memory.hookContext")
            #expect(!"\(ctx)".contains("sessões no Redis"))
            // a second trigger on the same chunk adds nothing
            let w = try #require(try await d.router.work.list(includeClosed: true).first)
            await d.router.captureProposals(w.id)
            #expect(try await proposals(store).count == 2)
        }
    }

    @Test func precompactCreatesProposals() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "T"]).ok)
            try await call(p, t, "work.note", ["text": "Escolhemos argon2", "decision": "true"])
            try await call(p, t, "work.hook", ["hook": "precompact", "payload": String(decoding: fx("precompact"), as: UTF8.self)])
            let lot = try #require(await d.router.ws.lots.first)
            let recs = try await proposals(await d.router.memory.lotStore(lot.id))
            #expect(recs.map(\.title) == ["Escolhemos argon2"] && recs.first?.scope == .lot && recs.first?.lotId == lot.id)
            // session end after it: same chunk, nothing new
            try await call(p, t, "work.hook", ["hook": "session-end", "payload": "{}"])
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await proposals(await d.router.memory.lotStore(lot.id)).count == 1)
            // the app reviews it: approve makes it active
            let id = try #require(recs.first?.id.uuidString)
            #expect(try await admin(d, p, "memory.review", ["id": id, "action": "approve", "lot": "Login"]).ok)
            let after = try await d.router.memory.lotStore(lot.id).run { $0.store.all().records }
            #expect(after.first?.status == .active)
        }
    }

    @Test func capturedTextScrubbed() async throws {
        let secret = String(repeating: "ab", count: 32)
        let w = Work(title: "Deploy", terminalId: UUID(), notes: [
            WorkNote(at: Date(), text: "Done: usei COLLIE_TOKEN=\(secret) e API_KEY=s3cr3t em https://x.dev/f?edit=1&token=zz e figcraft://file/9?k=1 com \(secret)")],
            commits: ["abc123 token=zz9 leaked"])
        let c = MemoryCapture.candidates(work: w, since: .distantPast, terminal: "T", lot: nil, secrets: [secret])
        let text = c.map { $0.title + $0.body }.joined()
        #expect(!c.isEmpty)
        for leak in [secret, "s3cr3t", "edit=1", "token=zz", "figcraft://", "zz9"] { #expect(!text.contains(leak), "\(leak): \(text)") }
        // through the daemon: a live terminal token in a done reason never reaches the store
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await call(p, t, "work.task.add", ["title": "x"])
            try await call(p, t, "work.done", ["reason": "token was \(t.token)"])
            let recs = try await proposals(d.router.memory.global)
            #expect(recs.count == 1 && recs[0].scope == .global && !(recs[0].title + recs[0].body).contains(t.token), "\(recs)")
        }
    }

    @Test func localModelOptional() async throws {
        // unavailable: the deterministic text (the default test model)
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await call(p, t, "work.note", ["text": "Escolhemos argon2", "decision": "true"])
            try await call(p, t, "work.done")
            #expect(try await proposals(d.router.memory.global).map(\.title) == ["Escolhemos argon2"])
        }
        // available: its rewrite, sanitized; the subject stays the deterministic key
        let m = FakeModel(.answer("Senhas com argon2\n\nUsamos argon2 para as senhas."))
        try await withDaemon(configure: { $0.localModel = m }) { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await call(p, t, "work.note", ["text": "Escolhemos argon2", "decision": "true"])
            try await call(p, t, "work.done")
            let r = try #require(try await proposals(d.router.memory.global).first)
            #expect(r.title == "Senhas com argon2" && r.body == "Usamos argon2 para as senhas." && r.subject == "escolhemos argon2", "\(r)")
            #expect(await m.calls.first?.instructions == WorkAssistant.proposalInstructions)
        }
    }

    // MARK: fix round 1

    /// I1: an ask queued behind a capturing terminal is typed only after the continued Stop, and gets its own reply.
    @Test func askHeldDuringCaptureTurn() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            let asks = await d.router.asks
            try await call(p, t, "turn.completed", ["source": "generic"])   // hook-capable: completes by hook only
            try await doneTask(p, t, "login form")
            let first = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo one", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.isBusy(t.uuid) })
            let second = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo two", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.queued(t.uuid) == 1 })
            #expect(reason(await stop(p, t)) != nil)   // blocks
            #expect(try await first.value.output == "Pronto: o login funciona.")
            try await Task.sleep(for: .milliseconds(300))
            let (q, busy) = (await asks.queued(t.uuid), await asks.isBusy(t.uuid))
            #expect(q == 1 && !busy)   // held: not typed into the capture turn
            // an ask arriving meanwhile waits too
            let third = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo three", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.queued(t.uuid) == 2 })
            #expect(await stop(p, t, "stop-continued") == nil)   // the capture turn's reply answers nothing
            let ok1 = await waitFor(10) { let b = await asks.isBusy(t.uuid), q = await asks.queued(t.uuid); return b && q == 1 }
            #expect(ok1)
            try await call(p, t, "turn.completed", ["source": "generic", "message": "two done"])
            #expect(try await second.value.output == "two done")
            try await call(p, t, "turn.completed", ["source": "generic", "message": "three done"])
            #expect(try await third.value.output == "three done")
        }
    }

    @Test func captureHoldCapReleases() async throws {
        try await withDaemon(configure: { $0.captureHoldSeconds = 1 }) { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            let asks = await d.router.asks
            try await call(p, t, "turn.completed", ["source": "generic"])
            try await doneTask(p, t, "login form")
            let first = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo one", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.isBusy(t.uuid) })
            let second = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo two", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.queued(t.uuid) == 1 })
            #expect(reason(await stop(p, t)) != nil)
            _ = try await first.value
            let busy = await asks.isBusy(t.uuid)
            #expect(!busy)
            // no continued Stop: the cap releases the queue
            let ok0 = await waitFor(10) { let b = await asks.isBusy(t.uuid), q = await asks.queued(t.uuid); return b && q == 0 }
            #expect(ok0)
            try await call(p, t, "turn.completed", ["source": "generic", "message": "two done"])
            #expect(try await second.value.output == "two done")
        }
    }

    @Test func noBlockStopReleasesAtOnce() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            let asks = await d.router.asks
            try await call(p, t, "turn.completed", ["source": "generic"])
            let first = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo one", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.isBusy(t.uuid) })
            let second = Task { try await asks.ask(from: UUID(), to: t.uuid, prompt: "echo two", raw: false, timeout: .seconds(30)) }
            #expect(await waitFor(10) { await asks.queued(t.uuid) == 1 })
            #expect(await stop(p, t) == nil)   // no work: no block
            _ = try await first.value
            let ok0 = await waitFor(10) { let b = await asks.isBusy(t.uuid), q = await asks.queued(t.uuid); return b && q == 0 }
            #expect(ok0)
            try await call(p, t, "turn.completed", ["source": "generic", "message": "two done"])
            #expect(try await second.value.output == "two done")
        }
    }

    /// M1: the save the agent makes in the capture turn doesn't skip the next chunk's ask.
    @Test func complySaveDoesNotSkipNextChunk() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await doneTask(p, t, "login form")
            #expect(reason(await stop(p, t)) != nil)
            try await call(p, t, "memory.save", ["kind": "decision", "subject": "sessions", "title": "Sessions in Redis"])
            #expect(await stop(p, t, "stop-continued") == nil)
            try await doneTask(p, t, "csrf")
            #expect(reason(await stop(p, t)) != nil)
        }
    }

    /// R6: the chunk's proposals are written even after the Stop asked about it and the agent declined.
    @Test func proposalsWrittenAfterAsk() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await call(p, t, "work.task.add", ["title": "OAuth"])
            try await call(p, t, "work.task.drop", ["task": "OAuth", "reason": "o provedor caiu"])
            try await doneTask(p, t, "login form")
            #expect(reason(await stop(p, t)) != nil)
            #expect(await stop(p, t, "stop-continued") == nil)   // "nada a registrar"
            try await call(p, t, "work.done", ["reason": "login pronto"])
            #expect(Set(try await proposals(d.router.memory.global, count: 2).map(\.title)) == ["Abandonado: OAuth", "login pronto"])
        }
    }

    /// M3: a failed write leaves the chunk unmarked; the next trigger writes it.
    @Test func failedWriteRetries() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            let dir = await d.router.memory.global.store.dir, fm = FileManager.default
            let elsewhere = p.root.appendingPathComponent("elsewhere")
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: dir, withDestinationURL: elsewhere)   // the store refuses a symlink: the write fails
            try await call(p, t, "work.note", ["text": "Escolhemos argon2", "decision": "true"])
            try await call(p, t, "work.hook", ["hook": "precompact", "payload": "{}"])
            let w = try #require(try await d.router.work.active(terminal: t.uuid))
            await d.router.captureProposals(w.id)   // waits for the detached one, then fails again
            #expect(try await d.router.work.get(w.id)?.proposedAt == nil)
            try fm.removeItem(at: dir)
            await d.router.captureProposals(w.id)
            #expect(try await proposals(d.router.memory.global).map(\.title) == ["Escolhemos argon2"])
            #expect(try await d.router.work.get(w.id)?.proposedAt != nil)
        }
    }

    /// M4: the model's rewrite is capped and scrubbed.
    @Test func rewriteCappedAndScrubbed() async throws {
        let long = "Usamos argon2 com a chave sk-ant-abcdefghijklmnop e Bearer abc.def.ghi " + String(repeating: "x", count: 5000)
        try await withDaemon(configure: { $0.localModel = FakeModel(.answer("Senhas com argon2 password=hunter2\n\n" + long)) }) { d, p in
            let t = try await term(d, p, "T", cwd: URL(fileURLWithPath: "/tmp"))
            try await call(p, t, "work.note", ["text": "Escolhemos argon2", "decision": "true"])
            try await call(p, t, "work.done")
            let r = try #require(try await proposals(d.router.memory.global).first)
            #expect(r.body.count <= MemoryCapture.maxBody && r.title.count <= MemoryCapture.maxTitle)
            for leak in ["sk-ant-", "abc.def.ghi", "hunter2"] { #expect(!(r.title + r.body).contains(leak), "\(leak)") }
        }
    }

    /// M6: bare bearer tokens, sk- keys and passwords.
    @Test func scrubsKeyShapes() {
        let x = LotBoards.scrub("Authorization: Bearer eyJhbGciOi.x-y_z key sk-ant-api03-abcdefghij sk-proj-abcdefghijk password=hunter2 passwd: s3cret ok")
        for leak in ["eyJhbGciOi", "sk-ant", "sk-proj", "hunter2", "s3cret"] { #expect(!x.contains(leak), "\(leak): \(x)") }
        #expect(x.contains("Bearer [hidden]") && x.hasSuffix(" ok"))
        #expect(LotBoards.scrub("risk-free task-list") == "risk-free task-list")
    }
}
