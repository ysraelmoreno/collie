import Testing
import Foundation
import SwiftUI
import CollieCanvas
import ColliePlugins
import CollieCore
import CollieClient
import CollieProtocol
@testable import CollieApp

private let pad = UUID()
private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed clock: no wall time in tests

/// 4 tasks taken: a done, b running its 2nd attempt (1 finished) on a live terminal, c deferred (its agent gone), d open.
private func work(state: WorkLoopState.State = .running, alive: UUID, gone: UUID) -> Work {
    var w = Work(title: "Onda 8", terminalId: UUID(), paddockId: pad, tasks: [
        WorkTask(id: "a", title: "A", state: .done, tries: 1), WorkTask(id: "b", title: "B", state: .inProgress, tries: 1),
        WorkTask(id: "c", title: "C", state: .deferred, tries: 3), WorkTask(id: "d", title: "D")])
    var l = WorkLoopState(state: state, task: "b", attempt: 2, tries: 3, timeout: 1800)
    l.show(.check, at: t0)
    w.loop = l
    w.jobs = [WorkJob(id: "b-t1", kind: .loop, label: "B", state: .finished, startedAt: t0.addingTimeInterval(-900), terminal: UUID()),
              WorkJob(id: "c-t3", kind: .loop, label: "C", state: .finished, startedAt: t0.addingTimeInterval(-2000), terminal: gone),
              WorkJob(id: "b-t2", kind: .loop, label: "B", state: .running, startedAt: t0.addingTimeInterval(-240), terminal: alive)]
    return w
}

private func record(_ id: UUID, _ name: String) -> TerminalRecord {
    TerminalRecord(id: id, name: name, preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)
}

/// A daemon that applies the real `work.history --id` rule: the closed work with that id (lowercased), even an empty
/// one (M8.1: never listed, still readable by id); anything else is `notFound`.
private struct FakeArchiveDaemon {
    var archives: [WorkArchive]
    func fetch(_ id: String) throws -> WorkArchive {
        guard let a = archives.first(where: { $0.id == id.lowercased() }) else { throw ProtocolError(code: .notFound, message: "no closed work \(id)") }
        return a
    }
}

@MainActor private final class Box { var ids: [String] = [] }

@MainActor struct LoopsModalTests {
    @Test func initialTabFollowsTheRunningLoop() {
        let w = work(alive: UUID(), gone: UUID())
        let r = LoopsModal.running(work: w, paddock: pad, terminals: [], now: t0)
        #expect(LoopsModal.initialTab(.running, running: r) == .running)
        #expect(LoopsModal.initialTab(.history, running: r) == .history)
        // nothing running here: the modal opens on Histórico, whatever was asked
        #expect(LoopsModal.initialTab(.running, running: nil) == .history)
        #expect(LoopsModal.running(work: work(state: .finished, alive: UUID(), gone: UUID()), paddock: pad, terminals: [], now: t0) == nil)
        #expect(LoopsModal.running(work: w, paddock: UUID(), terminals: [], now: t0) == nil)
        #expect(LoopsModal.running(work: nil, paddock: pad, terminals: [], now: t0) == nil)
        #expect(LoopsModal.idleText == "Nenhum laço rodando")
    }

    @Test func headerOfTheRunningLoop() throws {
        let r = try #require(LoopsModal.running(work: work(alive: UUID(), gone: UUID()), paddock: pad, terminals: [], now: t0, timeZone: utc))
        #expect(r.title == "Onda 8" && r.progress == "1/4" && r.fraction == 0.25)
        #expect(r.phase == "check rodando")
        #expect(r.since == "desde " + { let f = DateFormatter(); f.timeZone = utc; f.dateFormat = "HH:mm"; return f.string(from: t0) }())
        #expect(r.turnLimit == "turno de até 30 min")
    }

    @Test func taskLinesCarryTheRightAttemptAndAgent() throws {
        let alive = UUID(), gone = UUID()
        let r = try #require(LoopsModal.running(work: work(alive: alive, gone: gone), paddock: pad,
                                                terminals: [record(alive, "onda-8-b-t2")], now: t0))
        #expect(r.tasks.map(\.id) == ["a", "b", "c", "d"])   // the loop's order
        let b = r.tasks[1], c = r.tasks[2], d = r.tasks[3]
        // M8.1: running shows the attempt under way, never "0/3"
        #expect(b.row.state == .running && b.row.triesText == "tentativa 2/3")
        #expect(c.row.triesText == "tentativa 3/3" && d.row.triesText == "")
        // the newest attempt's agent: live → its terminal name, focusable; gone → "encerrado", nothing to focus
        #expect(b.agentText == "onda-8-b-t2" && b.terminal == alive)
        #expect(c.agentText == "c-t3 · encerrado" && c.terminal == nil)
        #expect(d.agentText == "—" && d.terminal == nil)
        // the running attempt's time, from the job's start on the given clock; none for the others
        #expect(b.elapsed == "4 min" && c.elapsed == nil && r.tasks[0].elapsed == nil)
    }

    @Test func historyIsTheLast20InTheGivenOrder() {
        let entries = (0..<25).map { i in HistoryEntry(id: "w\(i)", title: "T\(i)", closedAt: t0.addingTimeInterval(Double(-i * 60)), done: 4, total: 6) }
        let rows = HistorySection.make(entries, timeZone: utc).rows
        #expect(rows.count == 20 && rows.map(\.id) == (0..<20).map { "w\($0)" })
        #expect(rows[0].resultText == "4/6 feitas")
    }

    @Test func detailIsBuiltFromTheArchive() throws {
        let id = UUID().uuidString.lowercased()
        let a = WorkArchive(id: id, title: "Onda 7", paddock: "collie", branch: "feat/x", openedAt: t0.addingTimeInterval(-3600), closedAt: t0,
                            stopReason: "maxReached",
                            tasks: [.init(id: "M7.1", title: "Privacidade", state: "done", tries: 2, commits: ["0123456789abcdef"], evidenceNote: "ok"),
                                    .init(id: "M7.2", title: "Trava", state: "deferred", tries: 3, failure: "check falhou")],
                            timeline: [.init(at: t0, task: "M7.1", kind: "attemptStarted", detail: "tentativa 1")],
                            reconstructed: true, truncated: true)
        let daemon = FakeArchiveDaemon(archives: [a, WorkArchive(id: UUID().uuidString.lowercased())])
        let d = LoopsModal.Detail(try daemon.fetch(id.uppercased()), timeZone: utc)
        #expect(d.id == id && d.title == "Onda 7")
        #expect(d.notices == [HistoryPage.reconstructedNotice, HistoryPage.truncatedNotice])
        #expect(d.facts.first { $0.label == "Branch" }?.value == "feat/x")
        #expect(d.facts.first { $0.label == "Duração" }?.value == "1h00")
        #expect(d.tasks.map(\.state) == ["feita", "adiada"])
        #expect(d.tasks[0].commits == ["01234567"] && d.tasks[0].why == ["ok"] && d.tasks[0].tries == "2")
        #expect(d.tasks[1].why == ["check falhou"])
        #expect(d.timeline.count == 1 && d.timeline[0].task == "M7.1" && d.timeline[0].kind == "attemptStarted" && d.timeline[0].time == "08:00:00")
        // no notices for a plain one; an empty work (never listed) still opens by id; an unknown id is refused
        #expect(LoopsModal.Detail(try daemon.fetch(daemon.archives[1].id)).notices.isEmpty)
        #expect(throws: ProtocolError.self) { try daemon.fetch(UUID().uuidString) }
    }

    @Test func timelineShowsAtMost500Events() {
        let many = (0..<600).map { WorkArchive.Event(at: t0.addingTimeInterval(Double($0)), kind: "k", detail: "\($0)") }
        let d = LoopsModal.Detail(WorkArchive(id: "x", timeline: many))
        #expect(d.timeline.count == WorkArchive.timelineMax && d.timeline.last?.detail == "599")
    }

    @Test func openInCanvasCallsTheOldHookWithTheId() async {
        let got = Box()
        let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-loops-\(UUID())")))
        var ctx = ShellContext(client: client, canvas: CanvasState(), paddocks: PaddockActions(client: client), usage: UsageFeed(),
                               usageOpen: .constant(false), newTerminal: {}, openPanel: {}, fit: {}, openPalette: {},
                               herds: HerdsModel(call: { _, _ in .null }, nodeName: { _ in nil }), openHerds: { _ in })
        ctx.onOpenHistory = { got.ids.append($0) }
        #expect(await LoopsModal.openInCanvas("abc", ctx: ctx) == nil)
        #expect(got.ids == ["abc"])
    }

    @Test func textFromTheWorkStaysLiteral() throws {
        let evil = "<script>alert(1)</script> **negrito** [link](https://x.y)"
        let a = WorkArchive(id: "x", title: evil, tasks: [.init(id: evil, title: evil, state: evil, failure: evil)],
                            timeline: [.init(kind: evil, detail: evil)], notes: [evil], loopSummary: evil)
        let d = LoopsModal.Detail(a)
        #expect(d.title == evil && d.tasks[0].title == evil && d.tasks[0].state == evil && d.tasks[0].why == [evil])
        #expect(d.timeline[0].detail == evil && d.notes == [evil] && d.loopSummary == evil)
        var w = work(alive: UUID(), gone: UUID()); w.title = evil; w.tasks[0].title = evil
        let r = try #require(LoopsModal.running(work: w, paddock: pad, terminals: [], now: t0))
        #expect(r.title == evil && r.tasks[0].row.title == evil)
        // the Prévia page (M7.1) still escapes it
        #expect(!HistoryPage.html(for: a).contains("<script>"))
    }
}
