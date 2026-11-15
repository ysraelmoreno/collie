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

    // the manifest adopt writes (Task 5)
    private func refused(_ f: () throws -> Void) -> ProtocolError? {
        do { try f(); return nil } catch { return error as? ProtocolError ?? ProtocolError(code: .internal, message: "\(error)") }
    }
    private func input(_ edit: (inout AppAdopt.Input) -> Void = { _ in }) -> AppAdopt.Input {
        var i = AppAdopt.Input(id: "analytics", name: "Analytics debug", url: "http://127.0.0.1:8767", cmds: [])
        edit(&i)
        return i
    }

    @Test func parseCmdsBasic() throws {
        let c = try AppAdopt.parseCmds("events=GET:/api/document, clear_analytics=POST:/api/clear/analytics")
        #expect(c.map(\.name) == ["events", "clear-analytics"] && c.map(\.runs) == ["http", "http"])
        #expect(c[0].http?.method == "GET" && c[0].http?.path == "/api/document" && !c[0].confirm && c[0].timeout == 30)
        #expect(c[1].http?.method == "POST" && c[1].http?.path == "/api/clear/analytics" && c[1].timeout == 15)
        #expect(!c[0].summary.isEmpty)
    }

    @Test func parseCmdsRejectsBadMethod() {
        for f in ["x=TRACE:/a", "x=get:/a", "x=GET", "x=GET:a", "=GET:/a", "Bad=GET:/a", "x"] {
            #expect(refused { _ = try AppAdopt.parseCmds(f) }?.code == .invalidArgs, "\(f)")
        }
    }

    @Test func parseCmdsWritesNeedConfirm() throws {
        let c = try AppAdopt.parseCmds("a=GET:/a,b=POST:/b,c=PUT:/c,d=DELETE:/d")
        #expect(c.map(\.confirm) == [false, true, true, true])
    }

    @Test func manifestRejectsNonLoopback() {
        for url in ["http://example.com", "http://10.0.0.2:8767", "http://127.0.0.1:8767/api", "file:///tmp"] {
            #expect(refused { _ = try AppAdopt.manifest(input { $0.url = url }) }?.code == .invalidArgs, "\(url)")
        }
    }

    @Test func manifestAnalyticsExample() throws {
        let data = try AppAdopt.manifest(input {
            $0.start = "./run.sh"; $0.cwd = "tools/page-load-metrics-live"; $0.health = "/api/health"
            $0.eventStream = "/api/stream"; $0.eventDiff = "analyticsEvents"
            $0.cmds = try! AppAdopt.parseCmds("events=GET:/api/document,clear_analytics=POST:/api/clear/analytics")
        })
        let m = try PluginManifest.decode(data)
        #expect(m.apiVersion == 2 && m.id == "analytics" && m.name == "Analytics debug" && m.version == "0.1.0" && m.license == "private")
        #expect(m.placements == [.canvas, .dockRight] && m.defaultPlacement == .dockRight)
        #expect(m.ui == "http://127.0.0.1:8767/")
        #expect(m.service?.base == "http://127.0.0.1:8767" && m.service?.start == "./run.sh" && m.service?.health == "/api/health"
                && m.service?.cwd == "tools/page-load-metrics-live")
        #expect(m.eventStream == "/api/stream" && m.eventDiff == "analyticsEvents" && m.events == ["analytics.event"])
        #expect(m.commands.map(\.name) == ["events", "clear-analytics"] && m.commands.map(\.confirm) == [false, true])
        // stable bytes: the same input, the same file (adopt twice is a no-op)
        #expect(try AppAdopt.manifest(input {
            $0.start = "./run.sh"; $0.cwd = "tools/page-load-metrics-live"; $0.health = "/api/health"
            $0.eventStream = "/api/stream"; $0.eventDiff = "analyticsEvents"
            $0.cmds = try! AppAdopt.parseCmds("events=GET:/api/document,clear_analytics=POST:/api/clear/analytics")
        }) == data)
        #expect(String(decoding: data, as: UTF8.self).contains("\n  "))   // pretty
        // no command, no stream: a panel only
        let bare = try PluginManifest.decode(AppAdopt.manifest(input()))
        #expect(bare.commands.isEmpty && bare.events.isEmpty && bare.eventStream == nil && bare.service?.start == nil)
    }

    @Test func collieJSONInvalidThrows() throws {
        for bad in ["nope", "[]", #"{"commands": 3}"#, #"{"commands": [{"name": "x"}]}"#] {
            #expect(refused { _ = try AppAdopt.commands(fromCollieJSON: Data(bad.utf8)) }?.code == .invalidArgs, "\(bad)")
        }
        let ok = try AppAdopt.commands(fromCollieJSON: Data(#"""
            {"commands": [{"name": "events", "summary": "Eventos", "runs": "http", "http": {"method": "GET", "path": "/api/document"},
                           "result": {"pick": ["analyticsEvents"], "tail": {"analyticsEvents": 50}}}]}
            """#.utf8))
        #expect(ok.map(\.name) == ["events"] && ok[0].result?.pick == ["analyticsEvents"])
        // a bad command (here a bad name) fails when the manifest is built
        let badName = try AppAdopt.commands(fromCollieJSON: Data(#"{"commands": [{"name": "Bad", "summary": "s", "runs": "http", "http": {"method": "GET", "path": "/a"}}]}"#.utf8))
        #expect(refused { _ = try AppAdopt.manifest(input { $0.cmds = badName }) }?.code == .invalidArgs)
    }

    @Test func openAPIMakesReadCommandsAndConfirmedWrites() throws {
        let spec = #"""
        {"openapi": "3.0.0", "paths": {
          "/api/document": {"get": {"operationId": "getDocument", "summary": "The whole document",
                                     "parameters": [{"name": "since", "in": "query"}, {"name": "X-Trace", "in": "header"}]}},
          "/api/clear/analytics": {"post": {"summary": "Clear analytics"}},
          "/api/items/{id}": {"delete": {"operationId": "deleteItem"}},
          "/api/health": {"get": {}}
        }}
        """#
        let c = AppAdopt.commands(fromOpenAPI: Data(spec.utf8))
        let byName = Dictionary(uniqueKeysWithValues: c.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["get-document", "post-api-clear-analytics", "get-api-health"], "\(c.map(\.name))")   // a templated path can't be called
        #expect(byName["get-document"]?.summary == "The whole document" && byName["get-document"]?.params.map(\.name) == ["since"])
        #expect(byName["get-document"]?.confirm == false && byName["post-api-clear-analytics"]?.confirm == true)
        #expect(byName["post-api-clear-analytics"]?.http?.method == "POST" && byName["post-api-clear-analytics"]?.http?.path == "/api/clear/analytics")
        // what it makes builds a valid manifest
        #expect(try PluginManifest.decode(AppAdopt.manifest(input { $0.cmds = c })).commands.count == 3)
    }

    @Test func openAPIGarbageReturnsEmpty() {
        for g in ["", "nope", "[]", #"{"paths": 3}"#, #"{"paths": {"/a": 3, "/b": {"get": 4}}}"#] {
            #expect(AppAdopt.commands(fromOpenAPI: Data(g.utf8)).isEmpty, "\(g)")
        }
    }

    @Test func openAPICapsAt40() throws {
        let paths = (0..<60).map { #""/api/r\#($0)": {"get": {}}"# }.joined(separator: ",")
        let c = AppAdopt.commands(fromOpenAPI: Data(#"{"paths": {\#(paths)}}"#.utf8))
        #expect(c.count == 40)
        let long = AppAdopt.commands(fromOpenAPI: Data(#"{"paths": {"/a": {"get": {"summary": "\#(String(repeating: "s", count: 300))"}}}}"#.utf8))
        #expect(long.first?.summary.count == 120)
    }

    @Test func cwdEscapeRefused() {
        for cwd in ["..", "../x", "/abs", "a/../../b"] {
            #expect(refused { _ = try AppAdopt.manifest(input { $0.start = "./run.sh"; $0.cwd = cwd }) }?.code == .invalidArgs, "\(cwd)")
        }
    }
}
