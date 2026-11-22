import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M6.5, the review of wave 5's nits (A5, A6, A7, A9): a deferred notice held in the window never waits hours, the
/// orientation's wait fits the agent's shell tool, a transcript's model is an id or nothing, and the archive folder
/// is 0700 with no orphan temp file left. The app's case (a page outside the project) is in `OpenPanelSheetTests`.
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

@Suite(.timeLimit(.minutes(3))) struct Onda5NitsTests {
    // MARK: A5

    @Test func heldNoticesFlushOnlyPastTheWindow() async {
        let n = LoopNotices(), t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(await n.flush(at: t0) == nil, "nothing held: nothing to send")
        #expect(await n.offer("d1", done: false, at: t0) == "d1")
        #expect(await n.offer("d2", done: false, at: t0 + 5) == nil)
        #expect(await n.flush(at: t0 + 30) == nil, "inside the window: still held")
        // one held: its own line, not counts
        #expect(await n.flush(at: t0 + 61) == "d2")
        #expect(await n.held == 0)
        // the flush opens a window of its own
        #expect(await n.offer("d3", done: false, at: t0 + 70) == nil)
        #expect(await n.offer("d4", done: true, at: t0 + 80) == nil)
        #expect(await n.flush(at: t0 + 122) == WorkStatusText.noticeBatch(done: 1, deferred: 1))
    }

    @Test func aDeferredHeldInTheWindowGoesWithTheNextDoneTaskUnderEnd() async throws {
        let r = try await LoopRig([task("a", "false"), task("b", "false"), task("c", "test -f c.txt"), task("d", "test -f d.txt")],
                                  tries: 1, noticeWindow: LoopNotices.window)
        defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.notify = .end }
        let host = r.host
        // c's agent works for an hour (the fake clock): its task done sends no line of its own, but flushes b's
        await r.host.set("w-task-c-t1", LoopScript(act: { host.advance(3600); try await commit("c.txt", "ok\n", in: $0) }))
        await r.host.set("w-task-d-t1", LoopScript(act: { try await commit("d.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        await r.host.endedArrivals.wait(for: 2)
        let sent = await r.host.ended
        #expect(sent.count == 2 && sent[0].contains("Task a") && sent[1].contains("Task b") && sent[1].contains("adiada"), "\(sent)")
        #expect(await r.loop.notices.held == 0)
    }

    @Test func aDeferredHeldInTheWindowGoesAtTheNextAttemptsStart() async throws {
        let r = try await LoopRig([task("a", "false"), task("b", "false"), task("g", "test -f g.txt")],
                                  tries: 2, noticeWindow: LoopNotices.window)
        defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.notify = .end }
        let host = r.host
        // g's first attempt takes an hour and commits nothing (open again: no notice); its second starts past the window
        await r.host.set("w-task-g-t1", LoopScript(act: { _ in host.advance(3600) }))
        await r.host.set("w-task-g-t2", LoopScript(act: { dir in
            await host.endedArrivals.wait(for: 2)   // b's line went before this attempt's agent ran
            try await commit("g.txt", "ok\n", in: dir)
        }))
        #expect(await r.run() == .finished)
        let sent = await r.host.ended
        #expect(sent.count == 2 && sent[1].contains("Task b"), "\(sent)")
        #expect(await r.loop.notices.held == 0)
    }

    // MARK: A6

    @Test func theOrientationWaitsInTheBackgroundWithinTheToolsLimit() {
        #expect(CollieOrientation.loopNotify.contains("work wait --timeout 540") && CollieOrientation.loopNotify.contains("bg"))
        #expect(LoopCommand.body.contains("collie work wait --timeout 540") && LoopCommand.body.contains("work_wait")
                && LoopCommand.body.contains("background"))
        for text in [CollieOrientation.loopNotify, LoopCommand.body] { #expect(!text.contains("3600"), "\(text)") }
        for agent in ["claude", "cursor", "codex"] {
            for (term, peers) in [("Ana", ["Bob"]), ("Collie Main", ["Bob", "A very long peer name that goes on and on"])] {
                for shepherd in [true, false] {
                    let x = CollieOrientation.text(terminal: term, isShepherd: shepherd, paddock: "collie", peers: peers, panels: [("Home", "design")],
                                                   paddockPanels: [("Draft", "design")], morePanels: true, agent: agent, memoryTask: true, candidates: 3)
                    #expect(x.count <= 1500 && !x.contains("--timeout 3600"), "\(agent) \(shepherd) \(x.count)")
                }
            }
        }
        let codex = CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], agent: "codex")
        #expect(codex.count <= 1500 && codex.contains(CollieOrientation.loopNotify), "\(codex.count)\n\(codex)")
    }

    // MARK: A7

    @Test func aTranscriptModelThatIsNotAnIdIsNil() throws {
        let root = URL(fileURLWithPath: "/tmp/collie-onda5-\(UUID().uuidString.prefix(8))"), dir = root.appendingPathComponent("projects")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        func count(_ model: String) throws -> TokenCount? {
            let line = #"{"type":"assistant","message":{"id":"m1","model":"\#(model)","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":2}}}"#
            let f = dir.appendingPathComponent("p/\(UUID().uuidString).jsonl")
            try (line + "\n").write(to: f, atomically: true, encoding: .utf8)
            return SessionUsage.attempt(f.path, projectsDir: dir)
        }
        #expect(try count("claude-opus-5-5")?.model == "claude-opus-5-5")
        for bad in ["bad model; rm -rf", "-flag", String(repeating: "x", count: 65), "</script>"] {
            let t = try #require(try count(bad))
            #expect(t.model == nil && t.input == 3, "\(bad)")
        }
    }

    // MARK: A9

    @Test func aPreexistingArchiveFolderBecomes0700() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-onda5-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try #require(WorkArchiveFiles.write(Work(title: "w", terminalId: UUID(), closedAt: Date()), paddock: nil, terminal: nil, loopSummary: "", dir: dir))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700, "\(String(describing: mode.map { String($0, radix: 8) }))")
    }

    @Test func thePruneRemovesAnOldOrphanTempAndSparesARecentOne() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-onda5-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = dir.appendingPathComponent(".\(UUID().uuidString.lowercased()).\(UUID().uuidString).tmp")
        let young = dir.appendingPathComponent(".\(UUID().uuidString.lowercased()).\(UUID().uuidString).tmp")
        let other = dir.appendingPathComponent(".keep")   // a dot file that is not a temp: never the prune's
        for (f, age) in [(old, 3601.0), (young, 600.0), (other, 99_999.0)] {
            try Data("x".utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now - age], ofItemAtPath: f.path)
        }
        WorkArchiveFiles.prune(dir, keep: WorkArchiveFiles.keep, sparing: dir.appendingPathComponent("none.json"), now: now)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == [young.lastPathComponent, other.lastPathComponent], "\(left)")
    }
}
