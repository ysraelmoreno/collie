import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// M1.1: every way out of the loop leaves a typed `stopReason` and one `[loop] laço parado: <label>` note.
@Suite struct LoopStopReasonTests {
    typealias Stop = WorkLoopState.Stop

    /// The loop ended `stopped` by `code`, with exactly one summary note, the last one.
    private func expectStop(_ w: Work, _ code: Stop.Code, detail: String? = nil, _ at: SourceLocation = #_sourceLocation) {
        #expect(w.loop?.state == .stopped, sourceLocation: at)
        #expect(w.loop?.stopReason == Stop(code, detail: detail), "\(String(describing: w.loop?.stopReason))", sourceLocation: at)
        let summaries = w.notes.filter { $0.text.hasPrefix("[loop] laço parado: ") }
        #expect(summaries.map(\.text) == [Stop(code, detail: detail).note], "\(w.notes.map(\.text))", sourceLocation: at)
        #expect(w.notes.last?.text == Stop(code, detail: detail).note, sourceLocation: at)
    }

    @Test func maxReached() async throws {
        let r = try await LoopRig([task("a", "false")], tries: 3, max: 1); defer { r.cleanup() }
        #expect(await r.run() == .stopped)
        expectStop(try await r.get(), .maxReached)
    }

    @Test func budgetSpent() async throws {
        let r = try await LoopRig([task("a", "sleep 1.2; false")], tries: 3, budget: 1); defer { r.cleanup() }
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        expectStop(w, .budgetSpent)
        #expect(w.notes.contains { $0.text.hasPrefix("[loop] orçamento de tempo usado") })   // its own note stays
    }

    @Test func starterGone() async throws {
        let r = try await LoopRig([task("a", "false"), task("b", "true")]); defer { r.cleanup() }
        await r.host.setStarterGone(after: "loop-a-1")
        #expect(await r.run() == .stopped)
        expectStop(try await r.get(), .starterGone)
    }

    @Test func workGone() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        let store = r.store, id = r.work
        await r.host.set("loop-a-1", LoopScript(act: { _ in try await store.close(id, by: "app") }))
        #expect(await r.run() == .stopped)
        expectStop(try await r.get(), .workGone)
    }

    @Test func gitFailed() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        let notARepo = URL(fileURLWithPath: "/tmp/collie-norepo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }
        #expect(await r.loop.run(work: r.work, dir: notARepo) == .stopped)
        let w = try await r.get()
        expectStop(w, .gitFailed)
        #expect(await r.host.summoned.isEmpty && w.notes.contains { $0.text.hasPrefix("[loop] git falhou em") })
    }

    @Test func dirtyTree() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        try "someone's\n".write(to: r.repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        expectStop(w, .dirtyTree)
        #expect(w.notes.contains { $0.text.contains("dirty") })   // the long note stays, before the summary
    }

    @Test func othersWorkingNamesTheTerminal() async throws {
        let r = try await LoopRig([task("a", "false"), task("b", "true")]); defer { r.cleanup() }
        await r.host.setBusy("dev")
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        expectStop(w, .othersWorking, detail: "dev")
        #expect(w.loop?.stopReason?.label == "'dev' trabalhando no cercado")
    }

    @Test func requested() async throws {
        let r = try await LoopRig([task("a", "true"), task("b", "true")]); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.set("loop-a-1", LoopScript(act: { d in await loop.stop(work: id); try await commit("done.txt", "ok\n", in: d) }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        expectStop(w, .requested)
        #expect(w.tasks.map(\.state) == [.done, .open])
    }

    @Test func cancelled() async throws {
        let r = try await LoopRig([task("a", "false")]); defer { r.cleanup() }
        final class Box: @unchecked Sendable { var task: Task<WorkLoopState.State, Never>? }
        let box = Box(), loop = r.loop, id = r.work, repo = r.repo
        await r.host.set("loop-a-1", LoopScript(act: { _ in box.task?.cancel() }))
        box.task = Task { await loop.run(work: id, dir: repo) }
        #expect(await box.task!.value == .stopped)
        expectStop(try await r.get(), .cancelled)
    }

    /// The start sweep's pure part (`stopLoopsLeftRunning` applies it to every work a daemon left `running`).
    @Test func daemonRestartBySweep() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var w = Work(title: "W", terminalId: UUID(), tasks: [WorkTask(id: "a", title: "A", state: .inProgress)],
                     jobs: [WorkJob(id: "loop-a-1", kind: .loop, label: "A")])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        CommandRouter.sweepLeftRunning(&w, now: now)
        expectStop(w, .daemonRestart)
        #expect(w.loop?.endedAt == now && w.loop?.task == nil && w.tasks[0].state == .open && w.jobs[0].state == .gone)
    }

    @Test func finishedHasNoStopReason() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        // a reason left by an earlier run is cleared when the loop starts
        try await r.store.update(r.work) { $0.loop?.stopReason = Stop(.maxReached) }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.loop?.state == .finished && w.loop?.stopReason == nil)
        #expect(!w.notes.contains { $0.text.hasPrefix("[loop] laço parado") })
    }

    /// A work written by the daemon before this field still opens.
    @Test func decodesAWorkWithoutTheField() throws {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(state: .stopped, used: 2)
        let old = try JSONEncoder().encode(w)
        #expect(!String(decoding: old, as: UTF8.self).contains("stopReason"))   // nil is not written: the old shape
        let back = try JSONDecoder().decode(Work.self, from: old)
        #expect(back.loop?.state == .stopped && back.loop?.used == 2 && back.loop?.stopReason == nil)
    }

    @Test func stopRoundTripsAndBoundsItsDetail() throws {
        let s = Stop(.othersWorking, detail: String(repeating: "x", count: 500))
        #expect(s.detail?.count == 200)
        #expect(try JSONDecoder().decode(Stop.self, from: JSONEncoder().encode(s)) == s)
        // a code from a newer daemon: the reserve, not a loop that fails to decode
        #expect(try JSONDecoder().decode(Stop.self, from: Data(#"{"code":"somethingNew"}"#.utf8)).code == .unknown)
    }

    @Test func everyCodeHasAnOwnersLabel() {
        let labels = Stop.Code.allCases.map { Stop($0, detail: "dev").label }
        #expect(Set(labels).count == labels.count && labels.allSatisfy { !$0.isEmpty })
        #expect(Stop(.maxReached).label == "limite de tentativas (--max) atingido")
        #expect(Stop(.requested).note == "[loop] laço parado: pedido pelo dono (work stop)")
    }

    /// `unknown` is a reserve: no path of the engine or of the router's loop commands produces it. Sweeps the sources
    /// for every code they name.
    @Test func noPathProducesUnknown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var used: Set<String> = []
        for f in ["Sources/CollieDaemonKit/Work/WorkLoop.swift", "Sources/CollieDaemonKit/WorkLoopCommands.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            #expect(!src.contains(".unknown"), "\(f)")
            for c in Stop.Code.allCases where src.contains(".\(c.rawValue)") { used.insert(c.rawValue) }
        }
        // every other code is produced by one of them
        #expect(used == Set(Stop.Code.allCases.map(\.rawValue)).subtracting(["unknown"]), "\(used.sorted())")
    }
}
