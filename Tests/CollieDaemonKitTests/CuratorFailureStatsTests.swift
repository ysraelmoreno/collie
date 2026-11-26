import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let t0 = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
private func run(ok: Bool, reason: String? = nil, provider: String? = "claude", test: Bool? = nil) -> MemoryEvent {
    var e = MemoryEvent(type: .curatorRun); e.at = t0.addingTimeInterval(-3600); e.job = "correction"; e.ok = ok
    e.reason = reason; e.provider = provider; e.test = test
    return e
}
private func stats(_ es: [MemoryEvent]) -> MemoryObservability.Maintenance {
    MemoryObservability.compute(events: es, since: t0.addingTimeInterval(-7 * 86_400), now: t0, records: [], verified: { _ in true },
                                scores: [:], openDigest: [], curator: nil).maintenance
}
private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cfs-\(UUID().uuidString)") }

/// ma4: the curator's `failed/` pruned each consolidation cycle, failures by reason and provider, "Testar" calls out of the counts.
@Suite(.serialized) struct CuratorFailureStatsTests {
    /// 2a: a job parked 8 days ago leaves `failed/` after one consolidation cycle, with the same daemon; a 1-day one stays.
    @Test func consolidationCyclePrunesFailed() async throws {
        let repo = try await makeRepo()
        try await withDaemon(configure: { $0.curatorRunner = FakeCurator() }) { d, _ in
            let failed = d.router.curator.dir.appendingPathComponent("failed")
            let old = failed.appendingPathComponent("old.json"), fresh = failed.appendingPathComponent("fresh.json")
            for (u, days) in [(old, 8.0), (fresh, 1.0)] {
                #expect(FileManager.default.createFile(atPath: u.path, contents: Data("{}".utf8)))
                try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-days * 86_400)], ofItemAtPath: u.path)
            }
            let store = await d.router.memory.repo(for: repo.path)
            await d.router.consolidate(store, now: t0)
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: fresh.path))
        }
    }

    @Test func reasonBucketHeads() {
        #expect(MemoryObservability.reasonBucket("claude saiu com 1: erro qualquer") == "claude saiu com 1")
        #expect(MemoryObservability.reasonBucket("curator: junk answer (ops)") == "junk answer")
        #expect(MemoryObservability.reasonBucket("curador bloqueado pelo sandbox: /x") == "curador bloqueado pelo sandbox")
        #expect(MemoryObservability.reasonBucket("") == "unknown" && MemoryObservability.reasonBucket(nil) == "unknown")
        #expect(MemoryObservability.reasonBucket("  \n") == "unknown")
    }

    /// 2b: two reasons and one empty: three buckets; by provider too (a missing provider is "unknown").
    @Test func failuresByReasonAndProvider() {
        let m = stats([run(ok: false, reason: "claude saiu com 1: a", provider: "claude"),
                       run(ok: false, reason: "resposta ilegível: b", provider: "cursor"),
                       run(ok: false, reason: "", provider: nil),
                       run(ok: true, provider: "claude")])
        #expect(m.curatorRunFailures == 3)
        #expect(m.curatorFailuresByReason == ["claude saiu com 1": 1, "resposta ilegível": 1, "unknown": 1])
        #expect(m.curatorFailuresByProvider == ["claude": 1, "cursor": 1, "unknown": 1])
    }

    @Test func sameReasonSharesBucket() {
        let m = stats([run(ok: false, reason: "claude saiu com 1: a"), run(ok: false, reason: "claude saiu com 1: b")])
        #expect(m.curatorFailuresByReason == ["claude saiu com 1": 2] && m.curatorFailuresByProvider == ["claude": 2])
    }

    /// 2d: test-marked runs, ok or not, change neither runs nor failures (nor the buckets).
    @Test func testRunsOutOfCounts() {
        let base = [run(ok: true), run(ok: false, reason: "x: y")]
        let m = stats(base + [run(ok: true, test: true), run(ok: false, reason: "z: w", test: true)])
        let b = stats(base)
        #expect(m.curatorRuns == b.curatorRuns && m.curatorRunFailures == b.curatorRunFailures)
        #expect(m.curatorRuns == 2 && m.curatorRunFailures == 1 && m.curatorFailuresByReason == ["x": 1])
    }

    /// 2d end to end: "Testar com uma chamada" logs its calls marked `test`, and the stats leave them out.
    @Test(arguments: [false, true]) func testCallsMarkedAndUncounted(failing: Bool) async throws {
        let dir = scratch(), fake = FakeCurator()
        if failing { fake.failOn = "teste" }
        let log = MemoryEventLog(dir: dir.appendingPathComponent("metrics"), now: { t0 })
        let c = Curator(dir: dir.appendingPathComponent("curator"), runner: fake, clock: ManualClock(), now: { t0 }, events: log)
        let out = try await c.testCalls()
        #expect(out.count == 3 && fake.calls == 3)
        log.flush()
        let es = log.read(since: .distantPast).filter { $0.type == .curatorRun }
        #expect(es.count == 3 && es.allSatisfy { $0.test == true && $0.ok == !failing })
        let m = stats(es)
        #expect(m.curatorRuns == 0 && m.curatorRunFailures == 0 && m.curatorFailuresByReason.isEmpty)
    }
}
