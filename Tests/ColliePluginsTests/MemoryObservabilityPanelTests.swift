import Foundation
import Testing
import CollieCore
import CollieProtocol
@testable import ColliePlugins
@testable import CollieDaemonKit

private let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
private func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
private func ev(_ t: MemoryEvent.Kind, _ at: Date, _ f: (inout MemoryEvent) -> Void = { _ in }) -> MemoryEvent {
    var e = MemoryEvent(type: t); e.at = at; f(&e); return e
}
/// A daemon report (the real aggregator) as `memory.stats` sends it.
private func reportJSON(_ es: [MemoryEvent], records: [MemoryRecord] = [], queued: Int = 0, failed: Int = 0) throws -> JSONValue {
    let r = MemoryObservability.compute(events: es, since: ago(7), now: now, records: records, scores: [:], openDigest: [],
                                        curator: CuratorStatus(available: true, reason: nil, today: 0, cap: 40, queued: queued, failed: failed,
                                                               inputTokens: 0, outputTokens: 0, costUSD: 0))
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: e.encode(r))
}
private final class Calls: @unchecked Sendable {   // `lock` guards `args`
    let lock = NSLock(); var args: [[String: JSONValue]] = []
    var all: [[String: JSONValue]] { lock.withLock { args } }
}
@MainActor private func model(_ stats: JSONValue) -> (MemoryPanelModel, Calls) {
    let calls = Calls()
    let m = MemoryPanelModel(call: { c, a throws(ProtocolError) in
        guard c == "memory.stats" else { return .null }
        calls.lock.withLock { calls.args.append(a) }
        return stats
    })
    return (m, calls)
}

@MainActor @Suite struct MemoryObservabilityPanelTests {
    @Test func tabSitsNextToLearning() {
        #expect(MemoryPanelModel.Tab.allCases.prefix(2) == [.learning, .observability])
        #expect(MemoryPanelModel.Tab.observability.rawValue == "Observabilidade")
    }

    @Test func loadsWithFiltersAndExports() async throws {
        let json = try reportJSON([ev(.injected, ago(1)) { $0.where = "prompt"; $0.ids = [UUID()] }, ev(.noHit, ago(1))])
        let (m, calls) = model(json)
        m.statsSince = "30d"; m.statsProject = "/r"; m.statsLot = "pagamentos"
        await m.loadStats()
        #expect(calls.all == [["since": .string("30d"), "project": .string("/r"), "lot": .string("pagamentos")]])
        let r = try #require(m.stats)
        #expect(r.usage.coverage == 0.5 && r.caveat.contains("não medida diretamente"))
        let back = try JSONDecoder().decode(JSONValue.self, from: try #require(m.statsExport()))
        #expect(back == json)   // exported as received
    }

    @Test func alertsOnlyWhenWarranted() async throws {
        let quiet = try reportJSON([ev(.curatorRun, ago(0.5)) { $0.ok = true }], queued: 1)
        let (m, _) = model(quiet)
        await m.loadStats()
        #expect(MemoryPanelModel.alerts(try #require(m.stats), now: now).isEmpty)   // a queue that ran recently is not stuck

        var es = (0..<4).map { i in ev(.correction, ago(Double(i) + 0.1)) { $0.subject = "banco" } }   // 3 repeats this week
        es += (0..<3).map { _ in ev(.curatorRun, ago(2)) { $0.ok = false } }
        var old = MemoryRecord(kind: .decision, subject: "a", title: "Velha"); old.createdAt = ago(40)
        es.append(ev(.searched, ago(31)))   // the log covers 30 days
        let (m2, _) = model(try reportJSON(es, records: [old], queued: 2, failed: 1))
        await m2.loadStats()
        let a = MemoryPanelModel.alerts(try #require(m2.stats), now: now)
        #expect(a.count == 4, "\(a)")
        #expect(a[0].hasPrefix("3 correções repetidas") && a[1].hasPrefix("Curador falhando") && a[2].hasPrefix("Fila do curador parada")
                && a[3].hasPrefix("100%"))
    }

    @Test func trendLinesAndNumbers() {
        #expect(MemoryPanelModel.trendLine("Tokens por tarefa", current: 9_000, previous: 12_000) { MemoryPanelModel.tokens(Int($0)) }
                == "Tokens por tarefa: 12 mil → 9 mil (−25%)")
        #expect(MemoryPanelModel.trendLine("X", current: 2, previous: nil) { "\($0)" } == "X: sem dados para comparar")
        #expect(MemoryPanelModel.tokens(812) == "812" && MemoryPanelModel.tokens(1_250_000) == "1,2 mi" && MemoryPanelModel.usd(0.04) == "US$ 0,04")
    }
}
