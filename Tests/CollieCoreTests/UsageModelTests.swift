import Testing
import Foundation
import CollieProtocol
@testable import CollieCore

@Suite struct UsageModelTests {
    @Test func jsonPointerRFC6901() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":{"b":[10,20]},"a/b":1,"m~n":2}"#.utf8))
        #expect(JSONPointer.eval("/a/b/0", in: v) == .number(10))
        #expect(JSONPointer.eval("/a/b/1", in: v) == .number(20))
        #expect(JSONPointer.eval("/a~1b", in: v) == .number(1))
        #expect(JSONPointer.eval("/m~0n", in: v) == .number(2))
        #expect(JSONPointer.eval("", in: v) == v)
        #expect(JSONPointer.eval("/a/b/2", in: v) == nil)
        #expect(JSONPointer.eval("/a/x", in: v) == nil)
        #expect(JSONPointer.eval("/a/b/01", in: v) == nil)
        #expect(JSONPointer.eval("a", in: v) == nil)
    }

    @Test func providerRoundTripsDeclarativeJSON() throws {
        let src = #"""
        {"id":"x","label":"X","enabled":true,"command":["echo"],"parse":{"type":"jsonlLast","contains":"rate"},
         "windows":[{"label":"5h","usedPercent":"/a","resetsAt":"/b"}]}
        """#
        let p = try JSONDecoder().decode(UsageProvider.self, from: Data(src.utf8))
        #expect(p.parse == .jsonlLast(contains: "rate") && p.windows[0].resetsAt == "/b" && p.timeoutSeconds == nil)
        let q = try JSONDecoder().decode(UsageProvider.self, from: JSONEncoder().encode(p))
        #expect(q.parse == p.parse)
    }
}
