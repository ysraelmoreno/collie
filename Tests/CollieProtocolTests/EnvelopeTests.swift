import Foundation
import Testing
@testable import CollieProtocol

@Test func requestRoundTrips() throws {
    let r = Request(v: 1, id: "i", terminalId: "t", token: "k", command: "read",
                    args: ["target": .string("Reviewer"), "raw": .bool(true), "lines": .number(50)], cwd: "/x")
    let d = try JSONEncoder().encode(r)
    #expect(try JSONDecoder().decode(Request.self, from: d) == r)
}

@Test func jsonValueDecodesNested() throws {
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,"x",null,{"b":false}]}"#.utf8))
    #expect(v == .object(["a": .array([.number(1), .string("x"), .null, .object(["b": .bool(false)])])]))
}

@Test func errorResponseShape() throws {
    let r = Response(v: 1, id: "x", ok: false, result: nil, error: .init(code: .notConnected, message: "m"))
    let s = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
    #expect(s.contains(#""code":"notConnected""#))
}
