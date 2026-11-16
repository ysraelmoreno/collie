import Testing
import Foundation
@testable import CollieNetwork

private func rule(status: Int = 200, headers: [Header] = [], body: Data? = nil, delayMs: Int = 0,
                  host: String? = "api.example.com", path: String? = "/x*") -> MapRule {
    MapRule(id: MapRule.makeID(), name: nil, enabled: true,
            match: .init(method: "get", host: host, path: path, query: ["a": "1"]),
            action: .local(status: status, headers: headers, bodyB64: body?.base64EncodedString()), delayMs: delayMs)
}

private func rejects(_ rules: [MapRule], _ expected: (MapRuleError) -> Bool) {
    do { try MapRule.validate(rules); Issue.record("accepted") }
    catch { #expect(expected(error), "\(error)") }
}

@Suite struct MapRuleTests {
    @Test func jsonRoundTrip() throws {
        let a = rule(headers: [Header(name: "X-A", value: "1")], body: Data("oi".utf8), delayMs: 5)
        let b = MapRule(id: "drop01", name: "cut", enabled: false, match: .init(), action: .drop, delayMs: 100)
        let data = try JSONEncoder().encode([a, b])
        #expect(try JSONDecoder().decode([MapRule].self, from: data) == [a, b])
        #expect(a.match.method == "GET")   // stored upper-cased
        #expect(MapRule.makeID().count == 6 && MapRule.makeID().allSatisfy { $0.isLowercase || $0.isNumber })
    }

    @Test func rejectsContentEncodingAndLength() {
        for n in ["Content-Encoding", "content-length"] {
            rejects([rule(headers: [Header(name: n, value: "gzip")])]) { if case .forbiddenHeader = $0 { true } else { false } }
        }
    }

    @Test func rejectsOutOfRangeStatus() {
        for s in [99, 600] { rejects([rule(status: s)]) { if case .status = $0 { true } else { false } } }
        #expect((try? MapRule.validate([rule(status: 100), rule(status: 599)])) != nil)
    }

    @Test func rejectsDelayAbove60000() {
        rejects([rule(delayMs: 60_001)]) { if case .delay = $0 { true } else { false } }
        rejects([rule(delayMs: -1)]) { if case .delay = $0 { true } else { false } }
        #expect((try? MapRule.validate([rule(delayMs: 60_000)])) != nil)
    }

    @Test func rejectsBodyOver5MiB() {
        rejects([rule(body: Data(count: 5 << 20 + 1))]) { if case .bodyTooLarge = $0 { true } else { false } }
        #expect((try? MapRule.validate([rule(body: Data(count: 5 << 20))])) != nil)
    }

    @Test func rejectsMoreThan100Rules() {
        rejects((0...100).map { _ in rule() }) { if case .tooMany = $0 { true } else { false } }
        #expect((try? MapRule.validate((1...100).map { _ in rule() })) != nil)
    }

    @Test func rejectsEmptyOrOverlongGlob() {
        for g in ["", String(repeating: "a", count: 201)] {
            rejects([rule(host: g)]) { if case .glob = $0 { true } else { false } }
            rejects([rule(path: g)]) { if case .glob = $0 { true } else { false } }
        }
        #expect((try? MapRule.validate([rule(host: String(repeating: "a", count: 200), path: nil)])) != nil)
    }

    @Test func contentTypeGuess() {
        #expect(MapRule.guessedContentType(Data(#"{"a":[1]}"#.utf8)) == "application/json")
        #expect(MapRule.guessedContentType(Data("olá, mundo".utf8)) == "text/plain")
        #expect(MapRule.guessedContentType(Data([0xff, 0x00, 0xfe])) == "application/octet-stream")
    }
}
