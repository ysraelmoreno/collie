import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

// M8.1: `work.history` lists real works only: one with tasks, or one a loop ran. A work with no task and no loop (what a
// loop attempt's terminal used to open implicitly) is filtered when read; nothing on disk is deleted.

private func closed(_ title: String, tasks: [WorkTask] = [], loop: WorkLoopState? = nil) -> Work {
    var w = Work(title: title, terminalId: UUID(), closedAt: Date(timeIntervalSince1970: 2_000_000), tasks: tasks)
    w.loop = loop
    return w
}
private func archive(_ w: Work) -> WorkArchive {
    WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: WorkStatusText.statsLine(w) ?? "")
}

/// A `work.history` stand-in that applies the daemon's own rule (`WorkArchive.listed`), not a copy of it.
private struct FakeHistory {
    var archives: [WorkArchive]
    func titles() -> [String] { archives.filter(\.listed).map(\.title) }
}

@Suite(.serialized) struct HistoryRealWorksTests {
    @Test func aWorkWithNoTaskAndNoLoopIsNotListed() {
        #expect(!archive(closed("onda-6-achados-da-m6-5-ponte-t1 — 2026-11-21")).listed)
    }

    @Test func aWorkALoopRanIsListedEvenWithNoneDone() {
        var l = WorkLoopState(state: .stopped, tries: 3); l.stopReason = .init(.maxReached)
        #expect(archive(closed("Laço", tasks: [WorkTask(id: "a", title: "A", state: .deferred, tries: 3)], loop: l)).listed)
        // a loop with no task at all (stopped at once): still a loop, listed
        var bare = WorkLoopState(state: .stopped); bare.stopReason = .init(.requested)
        #expect(archive(closed("Laço vazio", loop: bare)).listed)
        var journal = WorkLoopState(state: .finished)
        journal.events = [LoopEvent(at: Date(timeIntervalSince1970: 1_000_000), kind: .turnEnded, task: "a", attempt: 1)]
        #expect(archive(closed("Só diário", loop: journal)).listed)
    }

    @Test func aWorkWithTasksAndNoLoopIsListed() {
        #expect(archive(closed("Manual", tasks: [WorkTask(id: "a", title: "A", state: .done, tries: 0)])).listed)
    }

    @Test func theFakeAppliesTheRealRule() {
        var l = WorkLoopState(state: .finished); l.stopReason = .init(.requested)
        let f = FakeHistory(archives: [archive(closed("Real", tasks: [WorkTask(id: "a", title: "A", state: .done)])),
                                       archive(closed("tentativa-t1 — 2026-11-21")), archive(closed("Laço", loop: l))])
        #expect(f.titles() == ["Real", "Laço"])
    }

    @Test func aLoopAttemptTerminalIsRecognisedByTerminalOrName() {
        let tid = UUID()
        var starter = Work(title: "Pastor", terminalId: UUID())
        starter.jobs = [WorkJob(id: "onda-8-m8-1-t1", kind: .loop, label: "M8.1", terminal: tid)]
        #expect(CommandRouter.isLoopAttempt(tid, name: "x", in: [starter]))
        #expect(CommandRouter.isLoopAttempt(UUID(), name: "onda-8-m8-1-t1", in: [starter]))   // before the loop marks it
        #expect(!CommandRouter.isLoopAttempt(UUID(), name: "outro", in: [starter]))
        starter.jobs[0].state = .finished
        #expect(!CommandRouter.isLoopAttempt(tid, name: "onda-8-m8-1-t1", in: [starter]))      // the attempt ended
        starter.jobs = [WorkJob(id: "onda-8-m8-1-t1", kind: .shell, label: "swift test", terminal: tid)]
        #expect(!CommandRouter.isLoopAttempt(tid, name: "onda-8-m8-1-t1", in: [starter]))      // a shell job is not an attempt
    }

    @Test func storedEmptyWorksAreFilteredWhenReadNotDeleted() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-realworks-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let empty = try await s.start(title: "vazio", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.close(empty.id, by: "app")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: await s.summaries.path)) ?? []
        #expect(files.contains("\(empty.id.uuidString.lowercased()).json"))   // its summary is still written and kept
        #expect(try await s.history { _ in true }.filter(\.listed).isEmpty)
    }

    @Test func endToEndARealClosedWorkIsListedAnEmptyOneIsNot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            func admin(_ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
                try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                                to: p.socket, timeoutSeconds: 60)
            }
            #expect(try await admin("paddock.create", ["name": "x", "repo": repo.path]).ok)
            let cwd = repo.appendingPathComponent(".collie/paddocks/x").path
            for n in ["Real", "Vazio"] { #expect(try await admin("admin.spawn", ["name": n, "preset": "shell", "cwd": cwd, "paddock": "x"]).ok) }
            #expect(try await admin("work.start", ["terminal": "Real", "title": "Trabalho real"]).ok)
            #expect(try await admin("work.task.add", ["terminal": "Real", "title": "Uma tarefa"]).ok)
            #expect(try await admin("work.task.done", ["terminal": "Real", "task": "Uma tarefa"]).ok)
            #expect(try await admin("work.done", ["terminal": "Real"]).ok)
            #expect(try await admin("work.start", ["terminal": "Vazio", "title": "Terminal de tentativa"]).ok)
            #expect(try await admin("work.done", ["terminal": "Vazio"]).ok)
            let r = try await admin("work.history", ["paddock": "x"])
            #expect(r.ok, "\(r)")
            guard case .object(let o)? = r.result, case .array(let rows)? = o["history"] else { Issue.record("\(r)"); return }
            let titles = rows.compactMap { if case .object(let e) = $0, case .string(let t)? = e["title"] { t } else { nil } }
            #expect(titles == ["Trabalho real"])
        }
    }
}
