import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
private func ev(_ type: MemoryEvent.Kind, _ at: Date, _ f: (inout MemoryEvent) -> Void = { _ in }) -> MemoryEvent {
    var e = MemoryEvent(type: type); e.at = at; f(&e); return e
}
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func compute(_ es: [MemoryEvent], since: Date = ago(7), records: [MemoryRecord] = [], scores: [UUID: Double] = [:],
                     digest: [DigestEntry] = []) -> MemoryObservability.Report {
    MemoryObservability.compute(events: es, since: since, now: now, records: records, scores: scores, openDigest: digest,
                                curator: CuratorStatus(available: true, reason: nil, today: 1, cap: 40, queued: 2, failed: 1,
                                                       inputTokens: 0, outputTokens: 0, costUSD: 0), calendar: utc)
}

@Suite struct MemoryObservabilityTests {
    @Test func sinceParses() {
        #expect(MemoryObservability.since("7d", now: now) == ago(7))
        #expect(MemoryObservability.since("24h", now: now) == ago(1))
        #expect(MemoryObservability.since("2w", now: now) == ago(14))
        #expect(MemoryObservability.since("2026-10-01T00:00:00Z", now: now) != nil)
        #expect(MemoryObservability.since("soon", now: now) == nil && MemoryObservability.since("-3d", now: now) == nil)
    }

    @Test func usageCoverageTopAndDead() {
        let a = UUID(), b = UUID()
        let old = MemoryRecord(kind: .decision, subject: "a", title: "A"), cold = MemoryRecord(kind: .decision, subject: "c", title: "C")
        var recs = [old, cold, MemoryRecord(kind: .decision, subject: "n", title: "Nova")]
        recs[0].createdAt = ago(60); recs[1].createdAt = ago(45); recs[1].updatedAt = ago(45)
        let es = [
            ev(.injected, ago(1)) { $0.where = "prompt"; $0.ids = [a, b]; $0.tokens = 30 },
            ev(.injected, ago(2)) { $0.where = "prompt"; $0.ids = [a]; $0.tokens = 10 },
            ev(.injected, ago(2)) { $0.where = "start"; $0.ids = [recs[0].id]; $0.tokens = 100 },
            ev(.injected, ago(3)) { $0.where = "retraction"; $0.ids = [b, cold.id]; $0.tokens = 5 },   // not a use
            ev(.noHit, ago(1)), ev(.noHit, ago(1)),
            ev(.injected, ago(20)) { $0.where = "prompt"; $0.ids = [b] },   // before the period
            ev(.searched, ago(1)) { $0.hits = 3 }, ev(.searched, ago(1)) { $0.hits = 0 },
        ]
        let r = compute(es, records: recs)
        #expect(r.caveat == MemoryObservability.caveat && r.caveat.contains("tendências apenas"))
        #expect(r.usage.prompts == 4 && r.usage.promptsWithMemory == 2 && r.usage.coverage == 0.5)
        #expect(r.usage.top.first == .init(id: a, title: nil, count: 2))
        #expect(r.usage.dead.map(\.id) == [cold.id])   // 45 days old, only "retracted" since: dead; the new one is too young
        #expect(r.usage.deadShare == 0.5)
        #expect(r.usage.searches == 2 && r.usage.searchHits == 3)
        #expect(r.usage.injectionsPerDay.count == 8 && r.usage.injectionsPerDay.map(\.value).reduce(0, +) == 4)
        #expect(r.cost.injectedTokens == 145)
        #expect(r.logSince == ago(20))
    }

    @Test func repeatCorrectionsWithin14Days() {
        let mem = UUID()
        let es = [
            ev(.correction, ago(20)) { $0.subject = "banco"; $0.project = "/r" },   // before the period: the first one
            ev(.correction, ago(6)) { $0.subject = "banco"; $0.project = "/r"; $0.ids = [mem] },   // 14 days later: repeat
            ev(.correction, ago(2)) { $0.subject = "banco"; $0.project = "/r"; $0.ids = [mem] },   // repeat
            ev(.correction, ago(2)) { $0.subject = "banco"; $0.project = "/outro" },   // another project: its first
            ev(.correction, ago(1)) { $0.subject = "testes"; $0.project = "/r" },
        ]
        let r = compute(es)
        #expect(r.learning.corrections == 4 && r.learning.repeatCorrections == 2)
        #expect(r.learning.repeats == [.init(subject: "banco", corrections: 2, repeats: 2, last: ago(2), memory: mem)])
        let late = compute([ev(.correction, ago(30)) { $0.subject = "x" }, ev(.correction, ago(1)) { $0.subject = "x" }])
        #expect(late.learning.repeatCorrections == 0)   // 29 days apart: not a repeat
    }

    @Test func tokensPerTaskAndTrends() {
        let w1 = UUID(), w2 = UUID(), w3 = UUID(), gone = UUID()
        func use(_ w: UUID, _ at: Date, _ n: Int) -> MemoryEvent {
            ev(.sessionUsage, at) { $0.work = w; $0.inputTokens = n; $0.outputTokens = n; $0.cacheRead = n; $0.cacheCreation = n }
        }
        let es = [
            use(w1, ago(10), 100), ev(.workClosed, ago(9)) { $0.work = w1; $0.reason = "merge" },   // previous week: 400/task
            use(w2, ago(3), 50), use(w2, ago(2), 50), ev(.workClosed, ago(2)) { $0.work = w2; $0.reason = "agente" },
            use(w3, ago(1), 25), ev(.workClosed, ago(1)) { $0.work = w3; $0.reason = "merge" },
            use(gone, ago(1), 999), ev(.workClosed, ago(1)) { $0.work = gone; $0.reason = "removed" },   // not completed
            ev(.searched, ago(1)), ev(.searched, ago(1)), ev(.searched, ago(8)),
            ev(.curatorRun, ago(1)) { $0.job = "consolidate"; $0.ok = true; $0.inputTokens = 800; $0.outputTokens = 40; $0.costUSD = 0.01 },
            ev(.curatorRun, ago(1)) { $0.job = "correction"; $0.ok = false; $0.reason = "claude saiu com 1" },
        ]
        let r = compute(es)
        #expect(r.cost.completedTasks == 2 && r.cost.sessionTokensPerTask == 250)   // (400 + 100) / 2; the removed one's out
        let perDay: Double = r.cost.sessionTokensPerDay.map(\.value).reduce(0, +)
        #expect(perDay == 4_496)   // 400 + 100 + 999 × 4
        #expect(r.cost.curatorTokens == 840 && r.cost.curatorUSD == 0.01)
        #expect(r.maintenance.consolidations == 1 && r.maintenance.curatorRunFailures == 1 && r.maintenance.curatorQueued == 2
                && r.maintenance.curatorFailed == 1 && r.maintenance.lastCuratorRun == ago(1))
        #expect(r.trends.current.tokensPerTask == 250 && r.trends.current.searchesPerTask == 1 && r.trends.current.completedTasks == 2)
        #expect(r.trends.previous.tokensPerTask == 400 && r.trends.previous.searchesPerTask == 1)
    }

    @Test func maintenanceCounts() {
        var created = DigestEntry(id: UUID(), at: ago(1), action: "confirmar", title: "", reason: "", store: "/r", created: [], before: [],
                                  undone: false, resolved: false)
        var ask = created; ask.id = UUID(); ask.action = "ask"
        var done = ask; done.id = UUID(); done.resolved = true
        created.likelyUser = true
        let es = [
            ev(.created, ago(1)) { $0.source = "correction" }, ev(.created, ago(1)) { $0.source = "conversation" },
            ev(.created, ago(1)) { $0.source = "conversation" }, ev(.superseded, ago(1)), ev(.undone, ago(1)),
            ev(.archived, ago(1)) { $0.source = "consolidation" }, ev(.archived, ago(1)) { $0.source = "user" },
            ev(.injected, ago(1)) { $0.where = "retraction"; $0.ids = [UUID(), UUID()] },
        ]
        var rec = MemoryRecord(kind: .decision, subject: "a", title: "A"); rec.createdAt = ago(10)
        let r = compute(es, records: [rec], scores: [rec.id: 1.5], digest: [created, ask, done])
        #expect(r.maintenance.createdBySource == ["correction": 1, "conversation": 2])
        #expect(r.maintenance.undone == 1 && r.maintenance.undonePct == 1.0 / 6 && r.maintenance.supersedes == 1)
        #expect(r.maintenance.archivedLowScore == 1 && r.maintenance.retractionsDelivered == 2)
        #expect(r.maintenance.pendingAsks == 1 && r.maintenance.openContradictions == 1)
        #expect(r.maintenance.averageAgeDays == 10 && r.maintenance.averageScore == 1.5)
    }

    @Test func digestRowsMapToLifecycleEvents() {
        func row(_ a: String, by: UUID? = nil) -> DigestEntry {
            DigestEntry(id: UUID(), at: now, action: a, title: "", reason: "", store: "", created: [], before: [], undone: false,
                        resolved: false, by: by)
        }
        #expect(MemoryDigest.eventKind(row("aprendido")) == .created && MemoryDigest.eventKind(row("ativado")) == .created)
        #expect(MemoryDigest.eventKind(row("mesclado")) == .merged && MemoryDigest.eventKind(row("descartado")) == .retracted)
        #expect(MemoryDigest.eventKind(row("aposentado", by: UUID())) == .superseded && MemoryDigest.eventKind(row("aposentado")) == .archived)
        #expect(MemoryDigest.eventKind(row("ask")) == .asked && MemoryDigest.eventKind(row("confirmar")) == .asked)
    }
}

// MARK: session usage

private func line(_ o: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
}
private func assistant(_ id: String, model: String = "claude-opus-4", _ i: Int, _ o: Int, read: Int = 0, made: Int = 0) -> String {
    line(["type": "assistant", "message": ["id": id, "role": "assistant", "model": model, "content": [["type": "text", "text": "segredo"]],
                                           "usage": ["input_tokens": i, "output_tokens": o, "cache_read_input_tokens": read,
                                                     "cache_creation_input_tokens": made]]])
}

@Suite struct SessionUsageTests {
    @Test func sumsPerModelOncePerMessage() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("su-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        let text = line(["type": "user", "message": ["role": "user", "content": "oi"]])
            + assistant("m1", 10, 1, read: 100, made: 5) + assistant("m1", 10, 1, read: 100, made: 5)   // one message, two blocks
            + assistant("m2", 20, 2) + assistant("m3", model: "claude-haiku", 3, 4)
            + assistant("s", model: "<synthetic>", 0, 0) + "{broken\n" + "{\"type\":\"assistant\""   // partial last line
        try Data(text.utf8).write(to: f)
        let r = try #require(SessionUsage.read(f, from: 0))
        #expect(r.byModel["claude-opus-4"] == .init(input: 30, output: 3, cacheRead: 100, cacheCreation: 5, messages: 2))
        #expect(r.byModel["claude-haiku"] == .init(input: 3, output: 4, cacheRead: 0, cacheCreation: 0, messages: 1))
        #expect(r.byModel.count == 2)
        #expect(r.end == UInt64(text.utf8.count - "{\"type\":\"assistant\"".utf8.count))
        #expect(try #require(SessionUsage.read(f, from: r.end)).byModel.isEmpty)   // the mark: nothing read twice
    }
}

// MARK: in the daemon

private func user(_ t: String) -> String { line(["type": "user", "message": ["role": "user", "content": t]]) }
private struct Env {
    var d: Daemon, p: Paths, fake: FakeCurator, tid: UUID, token: String, transcript: URL, repo: URL
    var events: MemoryEventLog { d.router.memory.events }
    @discardableResult
    func call(_ cmd: String, _ args: [String: JSONValue] = [:], admin: Bool = false) async throws -> Response {
        try await send(p, Request(id: "c", terminalId: admin ? nil : tid.uuidString, token: admin ? d.adminToken : token, command: cmd,
                                  args: args), timeoutSeconds: 30)
    }
    var env: [String: String] { ["COLLIE_SOCKET": p.socket.path, "COLLIE_TERMINAL_ID": tid.uuidString, "COLLIE_TOKEN": token] }
    func logged() -> [MemoryEvent] { events.flush(); return events.read(since: .distantPast) }
}
private func withEnv(_ body: (Env) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("mo-home-\(UUID().uuidString.prefix(8))")
    let dir = home.appendingPathComponent(".claude/projects/-tmp-repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fake = FakeCurator()
    let repo = try await makeRepo()
    try await withDaemon(configure: { $0.curatorRunner = fake; $0.sandboxHome = home; $0.conversationIdle = .seconds(600) }) { d, p in
        let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
            "name": .string("dev"), "preset": .string("shell"), "cwd": .string(repo.path)]), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"], let tid = UUID(uuidString: id) else {
            throw ProtocolError(code: .internal, message: "\(r)")
        }
        try await body(Env(d: d, p: p, fake: fake, tid: tid, token: try await tokenOf(d, id), transcript: dir.appendingPathComponent("sess-1.jsonl"),
                           repo: repo))
    }
}
private func top(_ repo: URL) -> String {
    guard let r = realpath(repo.path, nil) else { return repo.path }
    defer { free(r) }
    return String(cString: r)
}

@Suite(.serialized) struct MemoryEventEmissionTests {
    @Test func hooksSearchSaveAndStats() async throws {
        try await withEnv { e in
            let saved = try await e.call("memory.save", ["kind": .string("decision"), "subject": .string("banco"),
                                                         "title": .string("Use Postgres"), "body": .string("por causa do jsonb")])
            #expect(saved.ok, "\(saved)")
            _ = await MemoryHookClient.output(event: .sessionStart, prompt: nil, transcript: e.transcript.path, env: e.env)
            _ = await MemoryHookClient.output(event: .userPromptSubmit, prompt: "postgres jsonb?", transcript: e.transcript.path, env: e.env)
            _ = await MemoryHookClient.output(event: .userPromptSubmit, prompt: "kubernetes ingress", env: e.env)
            #expect(try await e.call("memory.search", ["query": .string("postgres")]).ok)
            let es = e.logged()
            let created = try #require(es.first { $0.type == .created })
            #expect(created.source == "agent" && created.terminal == e.tid && created.kinds == ["decision"] && created.project == top(e.repo))
            let start = try #require(es.first { $0.type == .injected && $0.where == "start" })
            #expect(start.session == "sess-1" && start.bytes ?? 0 > 0 && start.tokens == MemoryEvent.estimate(bytes: start.bytes ?? 0))
            let prompt = try #require(es.first { $0.type == .injected && $0.where == "prompt" })
            #expect(prompt.ids?.count == 1 && prompt.kinds == ["decision"] && prompt.scopes == ["project"] && prompt.terminal == e.tid)
            #expect(es.contains { $0.type == .noHit && $0.terminal == e.tid })
            #expect(es.first { $0.type == .searched }?.hits == 1)

            // an agent's stats: its project's and the global events, never another lot's or project's
            e.events.emit(MemoryEvent(type: .searched, lot: UUID(), hits: 9))
            e.events.emit(MemoryEvent(type: .searched, project: "/outro/repo", hits: 9))
            e.events.emit(MemoryEvent(type: .searched, hits: 1))
            e.events.flush()
            let mine = try await e.call("memory.stats", ["since": .string("1d")])
            #expect(mine.ok, "\(mine)")
            let r = try JSONDecoder.iso.decode(MemoryObservability.Report.self, from: JSONEncoder().encode(try #require(mine.result)))
            #expect(r.usage.searches == 2 && r.usage.searchHits == 2)
            #expect(r.usage.prompts == 2 && r.usage.coverage == 0.5)
            #expect(r.caveat == MemoryObservability.caveat)
            let all = try JSONDecoder.iso.decode(MemoryObservability.Report.self,
                                                 from: JSONEncoder().encode(try #require(try await e.call("memory.stats", admin: true).result)))
            #expect(all.usage.searches == 4)
            #expect(try await e.call("memory.stats", ["lot": .string("nenhum")]).error?.code == .notFound)
        }
    }

    @Test func curatorRunsLifecycleUndoAndSessionUsage() async throws {
        try await withEnv { e in
            let items = ConversationCapture.Output(items: [.init(kind: "decision", title: "Usar Postgres", body: "o time opera", userQuote: nil, duplicateOf: nil)])
            e.fake.output = CuratorOutput(json: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(items)),
                                          inputTokens: 900, outputTokens: 30, costUSD: 0.002)
            try Data((user("a") + assistant("m1", 10, 2, read: 50) + user("b") + assistant("m2", 5, 1)).utf8).write(to: e.transcript)
            let stdin = try JSONSerialization.data(withJSONObject: ["transcript_path": e.transcript.path, "stop_hook_active": false,
                                                                    "last_assistant_message": "ok"])
            _ = await MemoryHookClient.stopOutput(stdin: stdin, env: e.env)
            #expect(try await e.call("memory.capture").ok)
            #expect(await waitFor(10) { e.logged().contains { $0.type == .created } && e.logged().contains { $0.type == .sessionUsage } })
            let es = e.logged()
            let run = try #require(es.first { $0.type == .curatorRun })
            #expect(run.job == "conversation" && run.ok == true && run.inputTokens == 900 && run.costUSD == 0.002 && run.project == top(e.repo))
            #expect(es.first { $0.type == .created }?.source == "conversation")
            let use = try #require(es.first { $0.type == .sessionUsage })
            #expect(use.inputTokens == 15 && use.outputTokens == 3 && use.cacheRead == 50 && use.messages == 2 && use.session == "sess-1")
            #expect(use.model == "claude-opus-4" && use.terminal == e.tid)
            // the same Stop again: nothing new to count
            _ = await MemoryHookClient.stopOutput(stdin: stdin, env: e.env)
            try await Task.sleep(for: .milliseconds(300))
            #expect(e.logged().filter { $0.type == .sessionUsage }.count == 1)

            let entry = try #require(await e.d.router.digest.since(.distantPast).first)
            #expect(try await e.call("memory.undo", ["entry": .string(entry.id.uuidString)], admin: true).ok)
            #expect(e.logged().contains { $0.type == .undone && $0.ids == entry.created && $0.source == "user" })
        }
    }

    @Test func correctionAndWorkCloseAreLogged() async throws {
        try await withEnv { e in
            _ = await MemoryHookClient.output(event: .userPromptSubmit, prompt: "não, eu disse para usar sempre o banco sqlite nos testes de integração",
                                              env: e.env)
            #expect(await waitFor(5) { e.logged().contains { $0.type == .correction } })
            let c = try #require(e.logged().first { $0.type == .correction })
            #expect(c.terminal == e.tid && c.project == top(e.repo) && c.mode == "proposed" && !(c.subject ?? "").isEmpty)
            #expect(try await e.call("work.start", ["title": .string("migrar o banco")]).ok)
            #expect(try await e.call("work.done").ok)
            #expect(await waitFor(5) { e.logged().contains { $0.type == .workClosed && $0.terminal == e.tid && $0.work != nil } })
        }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
