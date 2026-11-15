import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// app adopt (spec 2026-11-15): `result.pick` / `result.tail` on an http command's reply; the generated manifest.
@Suite struct AppAdoptTests {
    private func items(_ r: ClosedRange<Int>) -> JSONValue { .array(r.map { .number(Double($0)) }) }
    private let doc: JSONValue = .object(["events": .array([.string("e")]), "analyticsEvents": .array([.string("a")]), "leakEvents": .array([])])

    @Test func shapeNilIsIdentity() {
        #expect(PaddockApps.shape(doc, nil) == doc)
    }

    @Test func shapePicksKeys() {
        #expect(PaddockApps.shape(doc, .init(pick: ["analyticsEvents"])) == .object(["analyticsEvents": .array([.string("a")])]))
    }

    @Test func shapeMissingKeyIgnored() {
        #expect(PaddockApps.shape(doc, .init(pick: ["analyticsEvents", "nope"], tail: ["gone": 5])) == .object(["analyticsEvents": .array([.string("a")])]))
    }

    @Test func shapeTailKeepsLast() {
        let v: JSONValue = .object(["analyticsEvents": items(1...100), "n": .number(100)])
        #expect(PaddockApps.shape(v, .init(tail: ["analyticsEvents": 50])) ==
                .object(["analyticsEvents": items(51...100), "analyticsEventsTruncated": .bool(true), "n": .number(100)]))
        // pick before tail: the Truncated key survives the pick
        #expect(PaddockApps.shape(v, .init(pick: ["analyticsEvents"], tail: ["analyticsEvents": 50])) ==
                .object(["analyticsEvents": items(51...100), "analyticsEventsTruncated": .bool(true)]))
    }

    @Test func shapeTailShortArrayUntouched() {
        let v: JSONValue = .object(["analyticsEvents": items(1...10)])
        #expect(PaddockApps.shape(v, .init(tail: ["analyticsEvents": 50])) == v)
    }

    @Test func shapeNonObjectPassesThrough() {
        for v: JSONValue in [items(1...3), .string("x"), .null] {
            #expect(PaddockApps.shape(v, .init(pick: ["a"], tail: ["a": 1])) == v)
        }
    }
}
