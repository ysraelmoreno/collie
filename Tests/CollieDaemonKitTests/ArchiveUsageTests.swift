import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

/// M10.3: the immutable summary keeps each task's counts and attempts (counts, model, agent and check seconds; all
/// optional), `work usage` reads the closed works' summaries (the caller's paddock only), the history's detail shows
/// the total; never a conversation's text.
@Suite(.serialized) struct ArchiveUsageTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-archive-usage-\(UUID().uuidString.prefix(8))") }
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }
    private let count1 = TokenCount(input: 1_000, output: 200, cacheWrite: 50, cacheRead: 4_000, messages: 3, model: "claude-opus-5-5")
    private let count2 = TokenCount(input: 500, output: 100, messages: 2, model: "claude-sonnet-5-5")

    @Test func anOldArchiveWithoutTheFieldsDecodes() throws {
        let old = #"{"version":1,"id":"w1","title":"Velho","tasks":[{"id":"t1","title":"A","state":"done","tries":1,"commits":["abc"]}],"timeline":[],"notes":[]}"#
        let a = try #require(WorkArchive.decoded(Data(old.utf8)))
        #expect(a.tasks.count == 1 && a.tasks[0].tokens == nil && a.tasks[0].attempts == nil)
        #expect(a.tokens == nil && WorkArchive.tokensLine(a.tokens) == nil)
        // a field of the wrong type is nothing, the rest stands
        let odd = #"{"id":"w2","tasks":[{"id":"t1","tokens":"muitos","attempts":[{"n":"x","agentSeconds":"y"}]}]}"#
        let b = try #require(WorkArchive.decoded(Data(odd.utf8)))
        #expect(b.tasks[0].id == "t1" && b.tasks[0].tokens == nil)
    }

    @Test func aNewArchiveRoundTripsItsAttempts() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "Com tokens", terminal: UUID(), paddockId: nil, branch: nil)
        let journal = [
            LoopEvent(at: at(0), kind: .attemptStarted, task: "t1", attempt: 1),
            LoopEvent(at: at(5), kind: .agentSummoned, task: "t1", attempt: 1),
            LoopEvent(at: at(65), kind: .agentDismissed, task: "t1", attempt: 1, tokens: count1),
            LoopEvent(at: at(66), kind: .checkStarted, task: "t1", attempt: 1),
            LoopEvent(at: at(96), kind: .checkFinished, task: "t1", attempt: 1, detail: "exit 1"),
            LoopEvent(at: at(100), kind: .attemptStarted, task: "t1", attempt: 2),
            LoopEvent(at: at(140), kind: .agentDismissed, task: "t1", attempt: 2, tokens: count2),
            LoopEvent(at: at(141), kind: .checkStarted, task: "t1", attempt: 2),
            LoopEvent(at: at(151), kind: .checkFinished, task: "t1", attempt: 2, detail: "exit 0"),
        ]
        try await s.update(w.id) { x in
            x.tasks = [WorkTask(id: "t1", title: "A", state: .done, tries: 2), WorkTask(id: "t2", title: "B")]
            x.tasks[0].tokens = count1 + count2
            x.loop = WorkLoopState(state: .finished)
            for e in journal { x.record(e) }
        }
        try await s.close(w.id, by: "app")
        let file = await s.summaries.appendingPathComponent("\(w.id.uuidString.lowercased()).json")
        let data = try Data(contentsOf: file)
        let a = try #require(WorkArchive.decoded(data))
        let t1 = a.tasks[0]
        #expect(t1.tokens == count1 + count2 && a.tasks[1].tokens == nil && a.tasks[1].attempts == nil)
        #expect(t1.attempts == [WorkArchive.Attempt(n: 1, tokens: count1, agentSeconds: 65, checkSeconds: 30),
                                WorkArchive.Attempt(n: 2, tokens: count2, agentSeconds: 40, checkSeconds: 10)])
        #expect(t1.attempts?[0].tokens?.model == "claude-opus-5-5")
        #expect(a.tokens == count1 + count2)
        // round trip: the same bytes back
        #expect(try a.encoded() == data)
        #expect(WorkArchive.decoded(try a.encoded()) == a)
    }

    @Test func theDetailShowsTheTotal() {
        var a = WorkArchive(id: "w", tasks: [WorkArchive.Task(id: "t1", tokens: count1), WorkArchive.Task(id: "t2", tokens: count2), WorkArchive.Task(id: "t3")])
        #expect(WorkArchive.tokensLine(a.tokens) == "tokens: " + (count1 + count2).label)
        #expect(WorkArchive.tokensLine(a.tasks[0].tokens) == "tokens: " + count1.label)
        #expect(WorkArchive.tokensLine(a.tasks[2].tokens) == nil)
        a.tasks = a.tasks.map { var t = $0; t.tokens = nil; return t }
        #expect(WorkArchive.tokensLine(a.tokens) == nil)   // nothing when the file has no numbers
    }

    @Test func theLimitsStand() {
        // 600 events with counts: still 500 kept behind a `truncated` one, and the file within 1 MB
        var w = Work(id: UUID(), title: "Grande", terminalId: UUID())
        w.tasks = [WorkTask(id: "t1", title: String(repeating: "x", count: 900_000))]
        w.tasks[0].tokens = count1
        w.loop = WorkLoopState(state: .finished)
        w.loop?.events = (0..<600).map { LoopEvent(at: at(Double($0)), kind: .agentDismissed, task: "t1", attempt: $0 + 1, detail: String(repeating: "d", count: 200), tokens: count2) }
        let a = WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: "")
        #expect(a.timeline.count <= WorkArchive.timelineMax && a.truncated)
        #expect((try? a.encoded().count) ?? .max <= WorkArchive.maxBytes)
        #expect(a.tasks.first?.tokens == count1)
    }

    @Test func workUsageReadsTheClosedWorksOfItsOwnPaddockOnly() async throws {
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                              args: ["name": .string("A"), "preset": .string("shell"), "cwd": .string("/tmp")]), timeoutSeconds: 60)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let a = Term(id: id, token: try await tokenOf(d, id))
            func call(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: a.id, token: a.token, command: cmd, args: args), timeoutSeconds: 60)
            }
            let mine: String? = nil   // a terminal spawned in /tmp is in the pasture (no paddock): `work.history`'s scope nil
            // two summaries on disk only (no work in the registry): one of the caller's paddock, one of another
            let dir = await d.router.work.summaries
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ownId = UUID().uuidString.lowercased(), otherId = UUID().uuidString.lowercased()
            let own = WorkArchive(id: ownId, title: "Onda fechada", openedAt: at(0), closedAt: at(100),
                                  tasks: [WorkArchive.Task(id: "t1", title: "Contada", state: "done", tries: 1, tokens: count1,
                                                           attempts: [WorkArchive.Attempt(n: 1, tokens: count1, agentSeconds: 60, checkSeconds: 20)])],
                                  paddockId: mine)
            let other = WorkArchive(id: otherId, title: "De outro cercado", openedAt: at(10), closedAt: at(110),
                                    tasks: [WorkArchive.Task(id: "t1", title: "Alheia", tokens: count2)], paddockId: UUID().uuidString.lowercased())
            try own.encoded().write(to: dir.appendingPathComponent("\(ownId).json"))
            try other.encoded().write(to: dir.appendingPathComponent("\(otherId).json"))

            let res = try await call("work.usage")
            guard case .object(let u)? = res.result, case .string(let out)? = u["output"], case .array(let works)? = u["works"] else { Issue.record("\(res)"); return }
            #expect(out.contains("Onda fechada [\(ownId.prefix(8))] · fechado · tokens: \(count1.label)"), "\(out)")
            #expect(out.contains("  - Contada [t1]: tokens: \(count1.label)"), "\(out)")
            #expect(!out.contains("De outro cercado") && !out.contains("Alheia"), "\(out)")
            #expect(works.count == 1)
            guard case .object(let w0) = works[0], case .bool(true)? = w0["closed"], case .number(let index)? = w0["index"],
                  case .array(let tasks)? = w0["tasks"], case .object(let t0) = tasks[0], case .array(let tries)? = t0["attempts"] else { Issue.record("\(works)"); return }
            #expect(abs(index - count1.index) < 0.0001 && tries.count == 1)
            // --id: its own (by the start of the id), never another paddock's
            guard case .object(let one)? = try await call("work.usage", ["id": .string(String(ownId.prefix(8)))]).result,
                  case .array(let ws1)? = one["works"] else { Issue.record("id"); return }
            #expect(ws1.count == 1)
            #expect(try await call("work.usage", ["id": .string(otherId)]).ok == false)
            // an open work in the same paddock comes first, from the registry
            #expect(try await call("work.start", ["title": .string("Aberto")]).ok)
            guard case .object(let both)? = try await call("work.usage").result, case .string(let out2)? = both["output"] else { Issue.record("open"); return }
            #expect(out2.hasPrefix("Aberto ["), "\(out2)")
            #expect(out2.contains("· ativo · tokens: sem número") && out2.contains("Onda fechada"), "\(out2)")
            // never a conversation's text: counts, titles and model ids only
            #expect(!out2.contains("SEGREDO"))
        }
    }
}
