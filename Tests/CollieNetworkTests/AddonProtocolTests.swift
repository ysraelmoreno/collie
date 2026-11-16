import Testing
import Foundation
@testable import CollieNetwork

@Suite struct AddonProtocolTests {
    @Test func decodesMappedBy() {
        let req = #"{"type":"request","id":"a","ts":1,"method":"GET","url":"http://h/","mappedBy":"abc123"}"#
        let res = #"{"type":"response","id":"a","ts":2,"status":418,"headers":[],"mappedBy":"abc123"}"#
        guard case .request(let r)? = FlowEvent.decode(line: req), case .response(let s)? = FlowEvent.decode(line: res)
        else { Issue.record("not decoded"); return }
        #expect(r.mappedBy == "abc123" && s.mappedBy == "abc123")
        guard case .request(let plain)? = FlowEvent.decode(line: #"{"type":"request","id":"b","ts":1,"method":"GET","url":"http://h/"}"#)
        else { Issue.record("not decoded"); return }
        #expect(plain.mappedBy == nil)
    }
}
