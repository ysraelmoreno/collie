import Testing
import Foundation
import CollieCore
import CollieClient
import CollieProtocol
@testable import CollieApp

private let utc = TimeZone(identifier: "UTC")!
private let pad = UUID()

private func work(_ state: WorkLoopState.State? = .running, phase: WorkLoopState.Phase? = .agent, paddock: UUID? = pad,
                  closed: Bool = false, tasks: [WorkTask]? = nil) -> Work {
    var w = Work(title: "T", terminalId: UUID(), paddockId: paddock, tasks: tasks ?? [
        WorkTask(id: "a", title: "A", state: .done, tries: 1), WorkTask(id: "b", title: "B", state: .inProgress, tries: 2),
        WorkTask(id: "c", title: "C", state: .deferred, tries: 3), WorkTask(id: "d", title: "D")])
    if closed { w.closedAt = Date() }
    if let state {
        var l = WorkLoopState(state: state, task: "b", attempt: 2, tries: 3)
        l.show(phase, at: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 3600 + 120))   // 2023-11-15 00:15:20 UTC
        w.loop = l
    }
    return w
}

struct LoopSectionTests {
    @Test func visibility() {
        func vis(_ w: Work?, _ p: UUID? = pad) -> Bool { LoopSection.make(work: w, paddock: p, timeZone: utc).visible }
        #expect(!vis(nil))
        #expect(!vis(work(nil)))                                   // work without a loop
        #expect(vis(work(.running, phase: .agent)))
        #expect(vis(work(.running, phase: .check)))
        #expect(vis(work(.running, phase: .gate)))
        #expect(!vis(work(.finished, phase: nil)))
        #expect(!vis(work(.stopped, phase: nil)))
        #expect(!vis(work(.running, closed: true)))
        #expect(!vis(work(.running, paddock: UUID())))             // another paddock's work
        #expect(!vis(work(.running), nil))                          // the Pasto
        #expect(LoopSection.make(work: nil, paddock: pad).rows.isEmpty)
    }

    @Test func rowsInTaskOrder() {
        let s = LoopSection.make(work: work(), paddock: pad, timeZone: utc)
        #expect(s.rows.map(\.id) == ["a", "b", "c", "d"])
        #expect(s.rows.map(\.state) == [.done, .running, .deferred, .open])
        #expect(s.rows.map(\.tries) == [1, 2, 3, 0] && s.rows.allSatisfy { $0.max == 3 })
        #expect(s.header?.progress == "1/4")
    }

    @Test func rowsKeepOnlyTheTasksTheLoopTook() {
        var w = work(); w.loop?.tasks = ["a", "b"]
        w.tasks.append(WorkTask(id: "x", title: "X", state: .abandoned))
        #expect(LoopSection.make(work: w, paddock: pad).rows.map(\.id) == ["a", "b"])
    }

    @Test func headerPhaseAndSince() {
        func h(_ p: WorkLoopState.Phase?) -> LoopSection.Header? { LoopSection.make(work: work(phase: p), paddock: pad, timeZone: utc).header }
        #expect(h(.agent)?.phase == "agente" && h(.check)?.phase == "check" && h(.gate)?.phase == "portão")
        #expect(h(.agent)?.since == "desde 00:15") 
        #expect(h(nil)?.phase == "preparando" && h(nil)?.since == nil)
    }
}

struct HistoryRowTests {
    private func row(_ e: HistoryEntry) -> HistoryRow { HistoryRow(e, timeZone: utc) }
    private let t = Date(timeIntervalSince1970: 1_763_690_520)   // 2025-11-21 02:02:00 UTC

    @Test func succeeded() {
        let r = row(HistoryEntry(id: "1", title: "Laço", closedAt: t, done: 6, total: 6, durationSeconds: 6840))
        #expect(r.whenText == "21/11 02:02" && r.resultText == "6/6 feitas" && r.stopText == "concluído" && r.durationText == "1h54")
        #expect(r.title == "Laço")
    }
    @Test func deferred() {
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: t, done: 4, total: 6, deferred: 1)).resultText == "4/6 feitas · 1 adiada")
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: t, done: 3, total: 6, deferred: 2)).resultText == "3/6 feitas · 2 adiadas")
    }
    @Test func stoppedByBudgetAndUnknownReason() {
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: t, stopReason: "budgetSpent")).stopText == "orçamento esgotado")
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: t, stopReason: "algoDeUmDaemonNovo")).stopText == "motivo desconhecido")
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: t, stopReason: "unknown")).stopText == "motivo desconhecido")
    }
    @Test func durations() {
        #expect(HistoryRow.duration(0) == "<1 min" && HistoryRow.duration(59) == "<1 min" && HistoryRow.duration(-5) == "<1 min")
        #expect(HistoryRow.duration(60) == "1 min" && HistoryRow.duration(3599) == "59 min")
        #expect(HistoryRow.duration(3600) == "1h00" && HistoryRow.duration(7500) == "2h05")
        #expect(HistoryRow.duration(86_400) == "1d 0h" && HistoryRow.duration(86_400 + 3 * 3600 + 600) == "1d 3h")
    }
    @Test func yesterdayAndLocalZone() {
        let y = t.addingTimeInterval(-86_400)
        #expect(row(HistoryEntry(id: "1", title: "", closedAt: y)).whenText == "20/11 02:02")
        let sp = TimeZone(identifier: "America/Sao_Paulo")!   // UTC-3
        #expect(HistoryRow(HistoryEntry(id: "1", title: "", closedAt: t), timeZone: sp).whenText == "20/11 23:02")
    }
    @Test func decodesTolerantly() {
        let v: JSONValue = .array([
            .object(["id": .string("a"), "title": .string("X"), "closedAt": .string("2025-11-21T02:02:00Z"), "done": .number(2), "total": .number(3),
                     "stopReason": .string("novo"), "surprise": .bool(true)]),
            .object(["title": .string("sem id")]), .string("lixo")])
        let rows = WorkFeed.entries(v)
        #expect(rows.count == 1 && rows[0].done == 2 && rows[0].stopReason == "novo" && rows[0].deferred == 0)
        #expect(WorkFeed.entries(.null).isEmpty)
    }
}

@MainActor struct WorkFeedTests {
    private func iso(_ d: Date) -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try! JSONDecoder().decode(JSONValue.self, from: e.encode(d))
    }
    private func workJSON(_ w: Work) -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try! JSONDecoder().decode(JSONValue.self, from: e.encode(w))
    }
    private func feed(_ w: Work, paddocks: [UUID: Bool] = [:], log: Log, failing: Bool = false) -> WorkFeed {
        let f = WorkFeed()
        f.call = { cmd, args, _ in
            log.calls.append((cmd, args))
            if failing { throw ProtocolError(code: .daemonUnavailable, message: "down") }
            switch cmd {
            case "work.status": return .object(["works": .array([self.workJSON(w)])])
            case "work.history":
                return .array([.object(["id": .string("h"), "title": .string("Antigo"), "closedAt": .string("2025-11-21T02:02:00Z")])])
            default: throw ProtocolError(code: .internal, message: "unexpected \(cmd)")
            }
        }
        return f
    }
    final class Log { var calls: [(String, [String: JSONValue])] = [] }
    private func settle(_ f: WorkFeed, until ok: @MainActor () -> Bool) async {
        for _ in 0..<200 where !ok() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func followLoadsTheWorkAndHistory() async {
        let w = work()
        let log = Log(), f = feed(w, log: log)
        f.follow(paddock: pad, name: "collie")
        await settle(f) { f.work != nil && !f.history.isEmpty }
        #expect(f.work?.id == w.id && f.history.map(\.id) == ["h"])
        #expect(!log.calls.contains { $0.0 == "work.wait" })   // M6.2: kept fresh by the daemon's work event
        #expect(log.calls.first { $0.0 == "work.history" }?.1["limit"] == .number(Double(WorkFeed.historyFetch)))
        #expect(log.calls.first { $0.0 == "work.history" }?.1["paddock"] == .string("collie"))
        f.follow(paddock: nil, name: nil)
    }

    @Test func switchingPaddockReloads() async {
        let w = work(), log = Log(), f = feed(w, log: log)
        f.follow(paddock: pad, name: "um")
        await settle(f) { f.work != nil }
        let other = UUID()
        f.follow(paddock: other, name: "dois")
        #expect(f.work == nil && f.history.isEmpty)   // dropped at once
        await settle(f) { log.calls.contains { $0.0 == "work.history" && $0.1["paddock"] == .string("dois") } }
        #expect(log.calls.contains { $0.0 == "work.history" && $0.1["paddock"] == .string("dois") })
        #expect(f.work == nil)   // the work is of the first paddock
        f.follow(paddock: nil, name: nil)
    }

    @Test func daemonErrorIsEmptyState() async {
        let log = Log(), f = feed(work(), log: log, failing: true)
        f.follow(paddock: pad, name: "collie")
        await settle(f) { log.calls.count >= 2 }
        #expect(f.work == nil && f.history.isEmpty)
        let noCall = WorkFeed()
        noCall.follow(paddock: pad, name: "collie")   // no client at all
        try? await Task.sleep(for: .milliseconds(50))
        #expect(noCall.work == nil && noCall.history.isEmpty)
    }
}
