import Testing
import Foundation
@testable import CollieNetwork

private let req = #"{"type":"request","id":"f1","ts":100.0,"method":"POST","url":"https://api.example.com/v1/items?x=1","httpVersion":"HTTP/2.0","headers":[{"name":"Cookie","value":"a=1"},{"name":"cookie","value":"b=2"}],"body":{"size":5,"truncated":false,"contentEncoding":null,"data":"aGVsbG8="},"tls":{"sni":"api.example.com","alpn":"h2"}}"#
private let res = #"{"type":"response","id":"f1","ttfb":100.2,"ts":100.25,"status":201,"reason":"Created","headers":[{"name":"Content-Encoding","value":"gzip"}],"body":{"size":20,"truncated":true,"contentEncoding":"gzip","data":"AAE="}}"#

private func request(_ id: String) -> FlowEvent {
    FlowEvent.decode(line: #"{"type":"request","id":"\#(id)","ts":1,"method":"GET","url":"http://h/"}"#)!
}

@Test func decodesRequestAndResponseLines() throws {
    guard case .request(let r) = FlowEvent.decode(line: req) else { Issue.record("request"); return }
    #expect(r.headers.map(\.value) == ["a=1", "b=2"])
    #expect(r.body?.data == Data("hello".utf8) && r.tls?.alpn == "h2")
    guard case .response(let s) = FlowEvent.decode(line: res) else { Issue.record("response"); return }
    #expect(s.status == 201 && s.body?.truncated == true && s.body?.contentEncoding == "gzip")
    #expect(s.body?.data == Data([0, 1]))
}

@Test func ignoresJunkLines() {
    for line in ["", "127.0.0.1:5555: GET https://x/", "{}", #"{"type":"nope","id":"a","ts":1}"#,
                 #"{"type":"request","id":"a","ts":1}"#] {
        #expect(FlowEvent.decode(line: line) == nil)
    }
}

@Test func storeAppliesLifecycle() throws {
    var store = FlowStore(serial: "emulator-5554")
    let pending = store.apply(FlowEvent.decode(line: req)!)
    #expect(pending?.state == .pending && pending?.host == "api.example.com" && pending?.path == "/v1/items?x=1")
    let applied = store.apply(FlowEvent.decode(line: res)!)
    let done = try #require(applied)
    #expect(done.state == .done && done.status == 201 && done.size == 20 && done.durationMs == 250)
    let f = try #require(store.flow("f1"))
    #expect(f.serial == "emulator-5554" && f.reqHeaders.count == 2 && f.resHeaders[0].name == "Content-Encoding")
    let ghost = store.apply(.response(.init(id: "ghost", ts: .now, status: 200, headers: [])))
    #expect(ghost == nil)
}

@Test func storeErrorAndTunnel() {
    var store = FlowStore()
    store.apply(request("e"))
    #expect(store.apply(FlowEvent.decode(line: #"{"type":"error","id":"e","ts":3,"message":"reset"}"#)!)?.state == .failed("reset"))
    store.apply(request("w"))
    store.apply(.tunneled(id: "w", ts: Date(timeIntervalSince1970: 2)))
    #expect(store.apply(.error(id: "w", ts: .now, message: "closed"))?.state == .tunneled)
}

@Test func storeRingEvictsOldestAndClears() {
    var store = FlowStore(capacity: 2)
    for id in ["a", "b", "c"] { store.apply(request(id)) }
    #expect(store.summaries.map(\.id) == ["b", "c"] && store.flow("a") == nil)
    store.apply(request("b"))  // replay of a live id does not duplicate
    #expect(store.summaries.map(\.id) == ["b", "c"])
    store.clear()
    #expect(store.summaries.isEmpty)
}

@Test func flowRoundTripsCodable() throws {
    var store = FlowStore()
    store.apply(FlowEvent.decode(line: req)!)
    store.apply(.error(id: "f1", ts: Date(timeIntervalSince1970: 101), message: "x"))
    let f = try #require(store.flow("f1"))
    #expect(try JSONDecoder().decode(Flow.self, from: JSONEncoder().encode(f)) == f)
}
