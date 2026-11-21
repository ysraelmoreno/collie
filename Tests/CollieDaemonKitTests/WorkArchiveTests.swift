import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// T6.1: a closed work's summary is written once to `work-archive/<id>.json` (`-2` when closed again), never
/// rewritten; `work.history` lists the caller's paddock's only.
@Suite(.serialized) struct WorkArchiveTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-archive-\(UUID().uuidString.prefix(8))") }
    private func files(_ s: WorkStore) async -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: await s.summaries.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    private func events(_ n: Int, from: Double = 1_000_000) -> [LoopEvent] {
        (0..<n).map { LoopEvent(at: Date(timeIntervalSince1970: from + Double($0)), kind: .turnEnded, task: "t1", attempt: 1, detail: "e\($0)") }
    }

    @Test func closingWritesOnceAndClosingAgainWritesTheNextNumber() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir, namer: { _ in ("collie", "agent-1") })
        let w = try await s.start(title: "Login", terminal: UUID(), paddockId: UUID(), branch: "collie/x")
        try await s.update(w.id) { $0.tasks = [WorkTask(id: "t1", title: "Form", state: .done, tries: 1)]; $0.notes = [WorkNote(text: "nota")] }
        #expect(await files(s).isEmpty)   // open: nothing yet
        try await s.close(w.id, by: "app")
        let id = w.id.uuidString.lowercased()
        #expect(await files(s) == ["\(id).json"])
        let first = try Data(contentsOf: await s.summaries.appendingPathComponent("\(id).json"))
        let a = try #require(WorkArchive.decoded(first))
        #expect(a.title == "Login" && a.paddock == "collie" && a.terminal == "agent-1" && a.branch == "collie/x")
        #expect(a.tasks.map(\.id) == ["t1"] && a.tasks[0].state == "done" && a.notes == ["nota"] && !a.reconstructed)
        // another write of the closed work: no new summary
        try await s.update(w.id) { $0.notes.append(WorkNote(text: "depois")) }
        #expect(await files(s).count == 1)
        // reopened and changed: the first file does not change; closed again: `-2`
        try await s.reopen(w.id)
        try await s.update(w.id) { $0.title = "Login 2"; $0.tasks.append(WorkTask(id: "t2", title: "API")) }
        #expect(try Data(contentsOf: await s.summaries.appendingPathComponent("\(id).json")) == first)
        try await s.close(w.id, by: "app")
        #expect(await files(s) == ["\(id)-2.json", "\(id).json"])
        #expect(try Data(contentsOf: await s.summaries.appendingPathComponent("\(id).json")) == first)
        let second = try #require(WorkArchive.decoded(try Data(contentsOf: await s.summaries.appendingPathComponent("\(id)-2.json"))))
        #expect(second.title == "Login 2" && second.tasks.count == 2)
        // the newest is the one history gives
        #expect(try await s.history { _ in true }.map(\.title) == ["Login 2"])
    }

    @Test func aWorkClosedUnderARunningLoopIsSummarizedWhenTheLoopEnds() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "L", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) { $0.loop = WorkLoopState(state: .running); for e in events(30) { $0.record(e) } }
        try await s.close(w.id, by: "app")
        #expect(await files(s).isEmpty)
        // M6.4: the loop only adds events, one write at a time (assigning all 150 at once hid the cut to 20)
        let all = events(150)
        for chunk in stride(from: 30, to: 150, by: 10) {
            try await s.update(w.id) { w in for e in all[chunk..<chunk + 10] { w.record(e) } }
        }
        try await s.update(w.id) { $0.loop?.state = .stopped; $0.loop?.stopReason = .init(.requested) }
        #expect(await files(s).count == 1)
        let a = try #require(try await s.history { _ in true }.first)
        // the whole journal at the close, not the 20 a closed work keeps
        #expect(a.timeline.count == 150 && a.stopReason == "requested" && !a.truncated)
        #expect(try await s.get(w.id)?.loop?.events?.count == WorkStore.maxClosedEvents)
    }

    @Test func theTimelineFollowsThePreviousSummaryAndIsCutAt500() async throws {
        var w = Work(title: "T", terminalId: UUID(), closedAt: Date(timeIntervalSince1970: 2_000_000))
        w.loop = WorkLoopState(state: .finished); w.loop?.events = events(300)
        let first = WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: "")
        #expect(first.timeline.count == 300 && !first.truncated)
        // closed again: the last 20 (already in the previous) are not repeated, the new run's 300 follow
        w.loop?.events = Array(events(300).suffix(20)) + events(300, from: 1_500_000)
        let next = WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: "", previous: first.timeline)
        #expect(next.timeline.count == WorkArchive.timelineMax && next.truncated)
        #expect(next.timeline[0].kind == "truncated" && next.timeline[0].detail.hasPrefix("101 "))
        #expect(next.timeline.last?.detail == "e299" && next.timeline[1].detail == "e101")
        #expect(Set(next.timeline.dropFirst()).count == WorkArchive.timelineMax - 1)
    }

    @Test func retentionKeepsThe200Newest() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        var written: [URL] = []
        for i in 0...WorkArchiveFiles.keep {
            let w = Work(title: "w\(i)", terminalId: UUID(), closedAt: Date())
            written.append(try #require(WorkArchiveFiles.write(w, paddock: nil, terminal: nil, loopSummary: "", dir: dir)))
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        #expect(left.count == WorkArchiveFiles.keep)
        #expect(!left.contains(written[0].lastPathComponent) && left.contains(written.last!.lastPathComponent))
    }

    @Test func aHugeTaskTextStaysWithin1MB() throws {
        let big = String(repeating: "x", count: 50_000)
        var w = Work(title: big, terminalId: UUID(), closedAt: Date(),
                     tasks: (0..<500).map { WorkTask(id: "t\($0)", title: big, state: .deferred, reason: big, lastFailure: big) },
                     notes: (0..<200).map { _ in WorkNote(text: big) })
        w.loop = WorkLoopState(state: .finished); w.loop?.events = events(100)
        let a = WorkArchive.make(w, paddock: big, terminal: big, loopSummary: big)
        #expect(try a.encoded().count <= WorkArchive.maxBytes)
        #expect(a.tasks.count == 500 && a.tasks[0].title.hasPrefix("xxx"))
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = try #require(WorkArchiveFiles.write(w, paddock: nil, terminal: nil, loopSummary: "", dir: dir))
        #expect(try Data(contentsOf: f).count <= WorkArchive.maxBytes)
    }

    @Test func decodesAnUnknownFieldAndAWrongTypeWithoutFailing() throws {
        let json = #"{"id":"abc","version":1,"title":"T","novo":{"x":1},"tries":"três","stopReason":42,"closedAt":"2026-11-20T10:00:00Z","#
            + #""tasks":[{"id":"t1","title":"A","state":"zzz","tries":"x","extra":true},"lixo"],"timeline":[{"at":"nope","kind":"futureKind","detail":7}],"#
            + #""notes":["a",3],"reconstructed":"sim"}"#
        let a = try #require(WorkArchive.decoded(Data(json.utf8)))
        #expect(a.id == "abc" && a.title == "T" && a.stopReason == nil && a.closedAt != nil && !a.reconstructed)
        #expect(a.tasks.count == 1 && a.tasks[0].state == "zzz" && a.tasks[0].tries == 0)
        #expect(a.timeline.count == 1 && a.timeline[0].kind == "futureKind" && a.timeline[0].at == nil)
        #expect(a.notes.isEmpty)   // one of the wrong type: the list falls back to empty, the archive stands
        // stable output: the same archive, the same bytes
        #expect(try a.encoded() == WorkArchive.decoded(try a.encoded())?.encoded())
    }

    @Test func aWorkClosedBeforeSummariesIsReconstructed() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "Antigo", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) { $0.loop = WorkLoopState(state: .finished); $0.loop?.events = events(60) }
        try await s.close(w.id, by: "app")
        try FileManager.default.removeItem(at: await s.summaries)   // as a daemon before T6.1 left it
        let a = try #require(try await s.history { _ in true }.first)
        #expect(a.reconstructed && a.title == "Antigo" && a.timeline.count == WorkStore.maxClosedEvents && !a.truncated)
    }

    @Test func workHistoryIsACommandOfCLIAndMCP() throws {
        let spec = try #require(Commands.spec("work.history"))
        #expect(spec.mcpName == "work_history" && spec.exposedToMCP && !spec.shepherdOnly)
        #expect(spec.params.map(\.name) == ["limit", "id", "paddock"])
        let p = try ArgvParser.parse(["work", "history", "--limit", "3", "--id", "abc"])
        #expect(p.command == "work.history" && p.args["limit"] == .number(3) && p.args["id"] == .string("abc"))
        let names = MCPSchema.tools().compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { n } else { nil } }
        #expect(names.contains("work_history"))
    }

    @Test func workHistoryShowsOnlyTheCallersPaddock() async throws {
        try await withDaemon { d, p in
            func spawn(_ name: String) async throws -> (id: String, token: String) {
                let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                                  args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp")]), timeoutSeconds: 60)
                guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
                return (id, try await tokenOf(d, id))
            }
            let a = try await spawn("A"), b = try await spawn("B")
            func call(_ t: (id: String, token: String), _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
            }
            func rows(_ r: Response) -> [String] {
                guard case .object(let o)? = r.result, case .array(let h)? = o["history"] else { return ["?"] }
                return h.compactMap { if case .object(let x) = $0, case .string(let t)? = x["title"] { t } else { nil } }
            }
            for title in ["Um", "Dois", "Três"] {
                #expect(try await call(a, "work.start", ["title": .string(title)]).ok)
                #expect(try await call(a, "work.done").ok)
            }
            // A's work in another paddock: B (the pasture) must never see it
            #expect(try await call(b, "work.start", ["title": .string("Outro")]).ok)
            let other = try #require(try await d.router.work.active(terminal: UUID(uuidString: b.id)!))
            try await d.router.work.update(other.id) { $0.paddockId = UUID() }
            #expect(try await call(b, "work.done", ["id": .string(other.id.uuidString.lowercased())]).ok)
            #expect(rows(try await call(a, "work.history")) == ["Três", "Dois", "Um"])   // newest first, the other paddock's left out
            #expect(rows(try await call(b, "work.history")) == ["Três", "Dois", "Um"])   // same pasture
            #expect(rows(try await call(a, "work.history", ["limit": .number(2)])) == ["Três", "Dois"])
            for bad in [0, 51] { #expect(try await call(a, "work.history", ["limit": .number(Double(bad))]).error?.code == .invalidArgs) }
            // by id: one of another paddock answers as missing
            #expect(try await call(a, "work.history", ["id": .string(other.id.uuidString.lowercased())]).error?.code == .notFound)
            let mine = try await call(a, "work.history")
            guard case .object(let o)? = mine.result, case .array(let h)? = o["history"], case .object(let row)? = h.first,
                  case .string(let id)? = row["id"] else { Issue.record("\(mine)"); return }
            #expect(Set(row.keys).isSuperset(of: ["id", "title", "openedAt", "closedAt", "done", "total", "deferred", "durationSeconds"]))
            guard case .object(let full)? = try await call(a, "work.history", ["id": .string(id)]).result else { Issue.record("id"); return }
            #expect(full["title"] == .string("Três") && full["version"] == .number(1))
            // the app: the paddock it names (none: the pasture), and by id any
            #expect(rows(try await send(p, Request(id: "x", token: d.adminToken, command: "work.history"))) == ["Três", "Dois", "Um"])
            #expect(try await send(p, Request(id: "x", token: d.adminToken, command: "work.history", args: ["paddock": .string("nenhum")])).error?.code == .notFound)
            #expect(try await send(p, Request(id: "x", token: d.adminToken, command: "work.history",
                                              args: ["id": .string(other.id.uuidString.lowercased())])).ok)
        }
    }
}
