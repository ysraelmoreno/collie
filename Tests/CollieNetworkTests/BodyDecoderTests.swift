import Testing
import Foundation
@testable import CollieNetwork

private let json = Data(#"{"ok":true,"n":[1,2]}"#.utf8)
private func body(_ b64: String, _ enc: String?) -> Body {
    let d = Data(base64Encoded: b64)!
    return Body(size: d.count, contentEncoding: enc, data: d)
}

// Fixtures from `gzip -c`, `brotli -c`, python zlib.compress, and `gzip -N` (header carries a file name).
@Test func decodesContentEncodings() {
    #expect(BodyDecoder.decode(body("H4sIAPob5GoAA6tWys9WsiopKk3VUcpTsoo21DGKrQUA1IlKSBUAAAA=", "gzip")) == json)
    #expect(BodyDecoder.decode(body("DwqAeyJvayI6dHJ1ZSwibiI6WzEsMl19Aw==", "br")) == json)
    #expect(BodyDecoder.decode(body("eJyrVsrPVrIqKSpN1VHKU7KKNtQxiq0FAEl+BnA=", "deflate")) == json)
    #expect(BodyDecoder.decode(body("H4sICPsb5GoAA24udHh0AEtMSgYAwkEkNQMAAAA=", "GZIP")) == Data("abc".utf8))
    #expect(BodyDecoder.decode(Body(size: 2, data: Data("hi".utf8))) == Data("hi".utf8))
    #expect(BodyDecoder.decode(Body(size: 2, contentEncoding: "identity", data: Data("hi".utf8))) == Data("hi".utf8))
}

@Test func decodeRejectsUnsupportedTruncatedAndCorrupt() {
    #expect(BodyDecoder.decode(Body(size: 2, contentEncoding: "zstd", data: Data("hi".utf8))) == nil)
    var cut = body("H4sIAPob5GoAA6tWys9WsiopKk3VUcpTsoo21DGKrQUA1IlKSBUAAAA=", "gzip"); cut.truncated = true
    #expect(BodyDecoder.decode(cut) == nil)
    #expect(BodyDecoder.decode(body("H4sIAPob5GoAA6tWys9W", "gzip")) == nil)   // stream ends early
    #expect(BodyDecoder.decode(Body(size: 4, contentEncoding: "gzip", data: Data("nope".utf8))) == nil)
}

@Test func prettyJSON() {
    #expect(BodyDecoder.prettyJSON(Data(#"{"a":"x/y"}"#.utf8)) == "{\n  \"a\" : \"x/y\"\n}")
    #expect(BodyDecoder.prettyJSON(Data("not json".utf8)) == nil)
}
