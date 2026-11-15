import Testing
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct AppEventDiffTests {
    private func doc(_ items: [String]) -> JSONValue { .object(["analyticsEvents": .array(items.map(JSONValue.string)), "other": .number(1)]) }
    private func s(_ items: [String]) -> [JSONValue] { items.map(JSONValue.string) }

    @Test func firstDocumentIsBaseline() {
        var d = AppEventDiff(key: "analyticsEvents")
        #expect(d.newItems(in: doc(["a", "b", "c"])) == [])
    }

    @Test func appendedItemsAreNew() {
        var d = AppEventDiff(key: "analyticsEvents")
        _ = d.newItems(in: doc(["a", "b"]))
        #expect(d.newItems(in: doc(["a", "b", "c", "d"])) == s(["c", "d"]))
        #expect(d.newItems(in: doc(["a", "b", "c", "d"])) == [])   // same document again: nothing
    }

    @Test func clearedLogResetsBaseline() {
        var d = AppEventDiff(key: "analyticsEvents")
        _ = d.newItems(in: doc(["a", "b", "c"]))
        #expect(d.newItems(in: doc([])) == [])
        #expect(d.newItems(in: doc(["x"])) == s(["x"]))
    }

    @Test func shorterWithoutLastResetsQuietly() {
        var d = AppEventDiff(key: "analyticsEvents")
        _ = d.newItems(in: doc(["a", "b", "c"]))
        #expect(d.newItems(in: doc(["d"])) == [])
        #expect(d.newItems(in: doc(["d", "e"])) == s(["e"]))
    }

    @Test func rotatedWindowStillFindsTail() {
        var d = AppEventDiff(key: "analyticsEvents")
        _ = d.newItems(in: doc(["a", "b", "c"]))
        #expect(d.newItems(in: doc(["b", "c", "d"])) == s(["d"]))
    }

    @Test func missingOrNonArrayKeyKeepsBaseline() {
        var d = AppEventDiff(key: "analyticsEvents")
        #expect(d.newItems(in: .object([:])) == [])   // no baseline yet either
        _ = d.newItems(in: doc(["a"]))
        #expect(d.newItems(in: .object(["other": .number(2)])) == [])
        #expect(d.newItems(in: .object(["analyticsEvents": .string("x")])) == [])
        #expect(d.newItems(in: .string("not a document")) == [])
        #expect(d.newItems(in: doc(["a", "b"])) == s(["b"]))
    }

    @Test func capsAt100Newest() {
        var d = AppEventDiff(key: "analyticsEvents")
        _ = d.newItems(in: doc(["a"]))
        let new = d.newItems(in: doc(["a"] + (1...150).map { "e\($0)" }))
        #expect(new.count == 100 && new.first == .string("e51") && new.last == .string("e150"))
    }
}
