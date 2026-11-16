import Testing
import Foundation
import CollieNetwork
import CollieProtocol
@testable import CollieDaemonKit

private func dir() -> URL { URL(fileURLWithPath: "/tmp/collie-rules-\(UUID().uuidString.prefix(8))") }

private func rule(_ id: String, enabled: Bool = true) -> MapRule {
    MapRule(id: id, name: id, enabled: enabled, match: .init(path: "/\(id)"), action: .local(status: 200, headers: [], bodyB64: nil))
}

private struct ActiveFile: Decodable { var v: Int; var rules: [MapRule] }

private func active(_ url: URL) throws -> ActiveFile { try JSONDecoder().decode(ActiveFile.self, from: Data(contentsOf: url)) }

@Suite struct RuleStoreTests {
    @Test func startsAllDisabled() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let file = d.appendingPathComponent("root/rules.json"), act = d.appendingPathComponent("run/rules.json")
        let a = RuleStore(file: file, active: act)
        _ = try await a.add(rule("a")); _ = try await a.add(rule("b"))
        let b = RuleStore(file: file, active: act)   // the daemon started again
        let loaded = await b.all()
        #expect(loaded.map(\.id) == ["a", "b"] && loaded.allSatisfy { !$0.enabled })
        #expect(try active(act).rules.isEmpty)
    }

    @Test func activeFileHasOnlyEnabledRulesInOrder() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let act = d.appendingPathComponent("run/rules.json")
        let s = RuleStore(file: d.appendingPathComponent("rules.json"), active: act)
        for (id, on) in [("a", true), ("b", false), ("c", true)] { _ = try await s.add(rule(id, enabled: on)) }
        let first = try active(act)
        #expect(first.v == 1 && first.rules.map(\.id) == ["a", "c"])
        try await s.setEnabled("b", true); try await s.setEnabled("a", false)
        #expect(try active(act).rules.map(\.id) == ["b", "c"])
        for f in [act, d.appendingPathComponent("rules.json")] {
            #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o600)
        }
        await #expect(throws: ProtocolError.self) { try await s.setEnabled("nope", true) }
    }

    @Test func activeFileIsWrittenAtomically() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let act = d.appendingPathComponent("run/rules.json")
        let s = RuleStore(file: d.appendingPathComponent("rules.json"), active: act)
        let big = MapRule(id: "big", name: nil, enabled: true, match: .init(),
                          action: .local(status: 200, headers: [], bodyB64: Data(count: 1 << 20).base64EncodedString()))
        _ = try await s.add(big)
        let reader = Task.detached {
            var bad = 0, reads = 0
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: act) {
                    reads += 1
                    if (try? JSONDecoder().decode(ActiveFile.self, from: data)) == nil { bad += 1 }
                }
            }
            return (bad, reads)
        }
        for i in 0..<200 { try await s.setEnabled("big", i % 2 == 0) }
        reader.cancel()
        let (bad, reads) = await reader.value
        #expect(bad == 0 && reads > 0)
    }

    @Test func persistsAcrossInstances() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let file = d.appendingPathComponent("rules.json"), act = d.appendingPathComponent("run/rules.json")
        let r = MapRule(id: "keep", name: "PDP", enabled: true, match: .init(method: "GET", host: "*.example.com", path: "/pdp*", query: ["sku": "1"]),
                        action: .local(status: 500, headers: [Header(name: "X", value: "1")], bodyB64: "b2k="), delayMs: 300)
        _ = try await RuleStore(file: file, active: act).add(r)
        var off = r; off.enabled = false
        #expect(await RuleStore(file: file, active: act).all() == [off])
    }

    @Test func removeAndClear() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let act = d.appendingPathComponent("run/rules.json")
        let s = RuleStore(file: d.appendingPathComponent("rules.json"), active: act)
        for id in ["a", "b", "c"] { _ = try await s.add(rule(id)) }
        try await s.remove("b")
        let left = await s.all()
        #expect(try left.map(\.id) == ["a", "c"] && active(act).rules.map(\.id) == ["a", "c"])
        await #expect(throws: ProtocolError.self) { try await s.remove("b") }
        await s.clear()
        let none = await s.all()
        #expect(try none.isEmpty && active(act).rules.isEmpty)
        // over the limits: refused, nothing changed
        let tooSlow = MapRule(id: "x", name: nil, enabled: true, match: .init(), action: .drop, delayMs: 60_001)
        await #expect(throws: ProtocolError.self) { try await s.add(tooSlow) }
        #expect(await s.all().isEmpty)
    }
}
