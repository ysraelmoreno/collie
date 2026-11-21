import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

/// A temp `<config>/projects` with one project folder; `cleanup` removes it.
private struct Projects {
    let root = URL(fileURLWithPath: "/tmp/collie-tokens-\(UUID().uuidString.prefix(8))")
    var dir: URL { root.appendingPathComponent("projects") }
    init() throws { try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true) }
    func file(_ name: String, _ lines: [String]) throws -> String {
        let f = dir.appendingPathComponent("p/\(name)")
        try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// What every content block of one assistant message repeats (Claude writes a line per block, each with its usage).
private let secret = "SEGREDO-NAO-GUARDAR-42"
private func assistant(_ id: String, input: Int, output: Int, write: Int = 0, read: Int = 0, model: String = "claude-opus-5-5") -> String {
    #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"\#(secret)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read)}}}"#
}
private let user = #"{"type":"user","message":{"role":"user","content":"\#(secret) do usuário"}}"#

/// M5.4: each attempt's agent's transcript is read as counts only (one per message id), kept on the journal's
/// `agentDismissed` and summed on its task; refused, gone or too big: no number, no error; `work usage` lists them.
@Suite(.serialized) struct TokenUsageTests {
    @Test func aRepeatedMessageCountsOnce() throws {
        let p = try Projects(); defer { p.cleanup() }
        let path = try p.file("s.jsonl", [user, assistant("m1", input: 10, output: 5, write: 100, read: 1000),
                                          assistant("m1", input: 10, output: 5, write: 100, read: 1000),   // a second block of m1
                                          assistant("m2", input: 1, output: 2, read: 10, model: "claude-sonnet-5-5")])
        let t = try #require(SessionUsage.attempt(path, projectsDir: p.dir))
        #expect(t == TokenCount(input: 11, output: 7, cacheWrite: 100, cacheRead: 1010, messages: 2, model: "claude-sonnet-5-5"))
        // the relative index: input 1, cache write 1.25, output 5, cache read 0.1
        #expect(abs(t.index - (11 + 125 + 35 + 101)) < 0.0001)
    }

    @Test func noUsageIsZero() throws {
        let p = try Projects(); defer { p.cleanup() }
        let path = try p.file("s.jsonl", [user, #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"oi"}]}}"#, "not json"])
        #expect(SessionUsage.attempt(path, projectsDir: p.dir) == TokenCount())
    }

    @Test func refusedGoneOrTooBigIsNoNumber() throws {
        let p = try Projects(); defer { p.cleanup() }
        let good = try p.file("s.jsonl", [assistant("m1", input: 10, output: 5)])
        // gone
        #expect(SessionUsage.attempt(p.dir.appendingPathComponent("p/gone.jsonl").path, projectsDir: p.dir) == nil)
        // a symlink (even to a good transcript)
        let link = p.dir.appendingPathComponent("p/link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: good))
        #expect(SessionUsage.attempt(link.path, projectsDir: p.dir) == nil)
        // a FIFO: refused without blocking on its open
        let fifo = p.dir.appendingPathComponent("p/fifo.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(SessionUsage.attempt(fifo.path, projectsDir: p.dir) == nil)
        // outside `<config>/projects`
        let outside = p.root.appendingPathComponent("out.jsonl")
        try Data(assistant("m1", input: 1, output: 1).utf8).write(to: outside)
        #expect(SessionUsage.attempt(outside.path, projectsDir: p.dir) == nil)
        // too big: past the limit, no number (the limit itself is 64 MB)
        #expect(SessionUsage.attemptMaxBytes == 64 << 20)
        #expect(SessionUsage.attempt(good, projectsDir: p.dir, maxBytes: 10) == nil)
        #expect(SessionUsage.attempt(good, projectsDir: p.dir)?.messages == 1)
    }

    @Test func theCountsHoldNoContent() throws {
        let p = try Projects(); defer { p.cleanup() }
        let path = try p.file("s.jsonl", [user, assistant("m1", input: 10, output: 5)])
        let t = try #require(SessionUsage.attempt(path, projectsDir: p.dir))
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        #expect(!json.contains(secret) && !json.contains("usuário"), "\(json)")
    }

    @Test func theLabelIsRelativeAndShort() {
        #expect(TokenCount(input: 1_200_000, messages: 14).label == "1,2 M (índice relativo) · 14 msgs")
        #expect(TokenCount(output: 300, messages: 1).label == "1,5 mil (índice relativo) · 1 msg")
        #expect(TokenCount(input: 42, messages: 2).label == "42 (índice relativo) · 2 msgs")
        #expect(!TokenCount(input: 1).label.contains("$") && !TokenCount(input: 1).label.contains("US"))
    }

    @Test func stateWithoutTheFieldDecodes() throws {
        let task = #"{"id":"a","title":"A","state":"open","updatedAt":"2026-11-20T10:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(WorkTask.self, from: Data(task.utf8)).tokens == nil)
        // a wrong type: the task survives with no counts
        let bad = #"{"id":"a","title":"A","state":"open","updatedAt":"2026-11-20T10:00:00Z","tokens":"muitos"}"#
        #expect(try dec.decode(WorkTask.self, from: Data(bad.utf8)).tokens == nil)
        let event = #"{"at":"2026-11-20T10:00:00Z","kind":"agentDismissed","task":"a","attempt":1}"#
        #expect(try dec.decode(LoopEvent.self, from: Data(event.utf8)).tokens == nil)
        // a field of the wrong type is 0
        let t = try JSONDecoder().decode(TokenCount.self, from: Data(#"{"input":"x","output":3,"model":7}"#.utf8))
        #expect(t == TokenCount(output: 3))
        let full = TokenCount(input: 1, output: 2, cacheWrite: 3, cacheRead: 4, messages: 5, model: "m")
        #expect(try JSONDecoder().decode(TokenCount.self, from: JSONEncoder().encode(full)) == full)
    }

    /// End to end with the fake host: read before the dismiss, on the attempt's `agentDismissed`, summed on the task
    /// over its attempts, and shown by `work status`'s line and the summary.
    @Test func theLoopKeepsEachAttemptsCounts() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")], tries: 3)
        defer { r.cleanup() }
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.setTokens("w-task-a-t1", TokenCount(input: 100, output: 10, messages: 3, model: "m"))
        await r.host.setTokens("w-task-a-t2", TokenCount(input: 1_000_000, cacheRead: 2_000_000, messages: 11, model: "m"))
        #expect(await r.run() == .finished)
        #expect(await r.host.tokensRead == ["w-task-a-t1", "w-task-a-t2"])
        let w = try await r.get()
        let dismissed = (w.loop?.events ?? []).filter { $0.kind == .agentDismissed }
        #expect(dismissed.map(\.tokens?.messages) == [3, 11])
        #expect(w.tasks[0].tokens == TokenCount(input: 1_000_100, output: 10, cacheRead: 2_000_000, messages: 14, model: "m"))
        #expect(WorkStatusText.tokensLine(w) == "tokens: 1,2 M (índice relativo) · 14 msgs")
        let sum = WorkSummary.make(w, terminalAlive: true, now: Date())
        #expect(sum.tokens?.messages == 14 && sum.markdown().contains("tokens: 1,2 M (índice relativo) · 14 msgs"))
    }

    @Test func noNumberNeverHoldsTheLoop() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")], tries: 1)
        defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tokens == nil)
        #expect(WorkStatusText.tokensLine(w) == nil)
        #expect((w.loop?.events ?? []).contains { $0.kind == .agentDismissed && $0.tokens == nil })
    }

    @Test func workUsageIsACommandOfCLIAndMCP() throws {
        let spec = try #require(Commands.spec("work.usage"))
        #expect(spec.mcpName == "work_usage" && spec.exposedToMCP && !spec.shepherdOnly)
        #expect(spec.params.map(\.name) == ["limit", "terminal"])
        let p = try ArgvParser.parse(["work", "usage", "--limit", "3"])
        #expect(p.command == "work.usage" && p.args["limit"] == .number(3))
        let names = MCPSchema.tools().compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { n } else { nil } }
        #expect(names.contains("work_usage"))
    }

    @Test func workUsageListsThePaddocksWorksWithTheirCounts() async throws {
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                              args: ["name": .string("A"), "preset": .string("shell"), "cwd": .string("/tmp")]), timeoutSeconds: 60)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let a = Term(id: id, token: try await tokenOf(d, id))
            func call(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: a.id, token: a.token, command: cmd, args: args), timeoutSeconds: 60)
            }
            #expect(try await call("work.start", ["title": .string("Old")]).ok)
            #expect(try await call("work.done").ok)
            #expect(try await call("work.start", ["title": .string("New")]).ok)
            #expect(try await call("work.task.add", ["title": .string("Counted")]).ok)
            #expect(try await call("work.task.add", ["title": .string("Not counted")]).ok)
            let w = try #require(try await d.router.work.active(terminal: a.uuid))
            try await d.router.work.update(w.id) { $0.tasks[0].tokens = TokenCount(input: 2_000, messages: 4, model: "m") }
            let res = try await call("work.usage")
            guard case .object(let u)? = res.result, case .string(let out)? = u["output"], case .array(let works)? = u["works"] else { Issue.record("\(res)"); return }
            #expect(works.count == 2)
            let lines = out.split(separator: "\n").map(String.init)
            #expect(lines.count == 3, "\(out)")
            #expect(lines[0].hasPrefix("New [") && lines[0].hasSuffix("· ativo · tokens: 2,0 mil (índice relativo) · 4 msgs"), "\(out)")
            #expect(lines[1].hasPrefix("  - Counted [") && lines[1].hasSuffix("tokens: 2,0 mil (índice relativo) · 4 msgs"), "\(out)")
            #expect(lines[2].hasPrefix("Old [") && lines[2].hasSuffix("· fechado · tokens: sem número"), "\(out)")
            guard case .object(let first) = works[0], case .number(let index)? = first["index"], case .array(let tasks)? = first["tasks"] else { Issue.record("\(works)"); return }
            #expect(index == 2_000 && tasks.count == 1)
            // --limit
            guard case .object(let one)? = try await call("work.usage", ["limit": .number(1)]).result, case .array(let ws)? = one["works"] else { Issue.record("limit"); return }
            #expect(ws.count == 1)
            // the status line too
            guard case .object(let st)? = try await call("work.status").result, case .string(let s)? = st["output"] else { Issue.record("status"); return }
            #expect(s.contains("tokens: 2,0 mil (índice relativo) · 4 msgs"), "\(s)")
        }
    }
}
