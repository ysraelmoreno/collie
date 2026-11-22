import Testing
import Foundation
import CollieProtocol
@testable import CollieDevice

@Suite struct HelperProtocolTests {
    private func json(_ d: Data) throws -> [String: Any] {
        #expect(d.last == 0x0A)
        return try #require(try JSONSerialization.jsonObject(with: d.dropLast()) as? [String: Any])
    }

    @Test func encodesEveryRequestAsOneLine() throws {
        #expect(String(decoding: HelperProtocol.encode(.hello, id: 7), as: UTF8.self) == "{\"id\":7,\"op\":\"hello\"}\n")
        let tap = try json(HelperProtocol.encode(.tap(x: 10, y: 20.5), id: 1))
        #expect(tap["op"] as? String == "tap" && tap["x"] as? Double == 10 && tap["y"] as? Double == 20.5)
        let sw = try json(HelperProtocol.encode(.swipe(x1: 1, y1: 2, x2: 3, y2: 4, ms: 300), id: 2))
        #expect(sw["op"] as? String == "swipe" && sw["x2"] as? Double == 3 && sw["ms"] as? Int == 300)
        #expect(try json(HelperProtocol.encode(.click(path: [0, 2, 1]), id: 3))["path"] as? [Int] == [0, 2, 1])
        let sc = try json(HelperProtocol.encode(.scroll(path: [1], forward: false), id: 4))
        #expect(sc["op"] as? String == "scroll" && sc["dir"] as? String == "back")
        let tx = try json(HelperProtocol.encode(.text("a \"b\"\nc/d"), id: 5))
        #expect(tx["value"] as? String == "a \"b\"\nc/d")   // the newline is escaped: still one line
        #expect(try json(HelperProtocol.encode(.global("back"), id: 6))["action"] as? String == "back")
        #expect(try json(HelperProtocol.encode(.subscribe, id: 8))["op"] as? String == "subscribe")
        #expect(try json(HelperProtocol.encode(.dump, id: 9))["op"] as? String == "dump")
    }

    @Test func decodesHelloAndDump() throws {
        let hello = Data(#"{"ok":true,"version":1,"sdk":37,"w":1080,"h":2400,"id":1}"#.utf8)
        #expect(try HelperProtocol.decode(hello, as: HelperProtocol.Hello.self) == .init(version: 1, sdk: 37, w: 1080, h: 2400))
        let dump = Data(#"""
        {"ok":true,"root":true,"id":2,"nodes":[{"p":[0,1],"text":"Combos","desc":"","id":"com.x:id/tab","cls":"android.widget.TextView",
        "b":[0,100,200,180],"clk":true,"sel":true,"chk":false,"en":true,"foc":false,"scr":false,"pw":false}]}
        """#.utf8)
        let d = try HelperProtocol.decode(dump, as: HelperProtocol.Dump.self)
        #expect(d.root && d.nodes.count == 1)
        let n = d.nodes[0]
        #expect(n.path == [0, 1] && n.text == "Combos" && n.id == "com.x:id/tab" && n.bounds == [0, 100, 200, 180])
        #expect(n.clickable && n.selected && !n.checked && n.enabled && !n.password)
    }

    @Test func errorsAndEvents() throws {
        let bad = #expect(throws: ProtocolError.self) {
            try HelperProtocol.decode(Data(#"{"ok":false,"error":"node gone","id":3}"#.utf8), as: HelperProtocol.Dump.self)
        }
        #expect(bad?.message == "helper: node gone")
        #expect(try HelperProtocol.message(Data(#"{"ev":"window","t":1700000000123}"#.utf8)) == .event(.init(ev: "window", t: 1_700_000_000_123)))
        #expect(try HelperProtocol.message(Data(#"{"ok":true,"id":4}"#.utf8)) == .reply(.init(id: 4, ok: true, error: nil)))
        #expect(throws: ProtocolError.self) { try HelperProtocol.decode(Data(#"{"ev":"content","t":1}"#.utf8), as: HelperProtocol.Hello.self) }
        #expect(throws: ProtocolError.self) { try HelperProtocol.message(Data("not json".utf8)) }
        #expect(throws: ProtocolError.self) { try HelperProtocol.decode(Data(#"{"ok":true}"#.utf8), as: HelperProtocol.Hello.self) }
    }

    @Test func servicesListIsAppendedNeverOverwritten() {
        let me = HelperProtocol.service
        #expect(HelperProtocol.enabling("null\n") == me)
        #expect(HelperProtocol.enabling("") == me)
        #expect(HelperProtocol.enabling("com.a/.Talk:com.b/com.b.Svc\n") == "com.a/.Talk:com.b/com.b.Svc:\(me)")
        #expect(HelperProtocol.enabling("com.a/.Talk:\(me)") == "com.a/.Talk:\(me)")   // already there: unchanged
        #expect(HelperProtocol.enabling("com.collie.helper/com.collie.helper.HelperService") == "com.collie.helper/com.collie.helper.HelperService")
        #expect(HelperProtocol.removing("com.a/.Talk:\(me):com.b/.X") == "com.a/.Talk:com.b/.X")
        #expect(HelperProtocol.removing(me) == "")
        #expect(HelperProtocol.removing("null") == "")
    }
}
