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

// mitmproxy's CA; `openssl@3 x509 -noout -subject_hash_old` prints c8750f0d.
private let mitmCA = "MIIDNTCCAh2gAwIBAgIUIEzN5XFvyoexgSQpqhVvYPjuXB0wDQYJKoZIhvcNAQELBQAwKDESMBAGA1UEAwwJbWl0bXByb3h5MRIwEAYDVQQKDAltaXRtcHJveHkwHhcNMjYxMDI4MDEyMTUwWhcNMzYxMDI1MDEyMTUwWjAoMRIwEAYDVQQDDAltaXRtcHJveHkxEjAQBgNVBAoMCW1pdG1wcm94eTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJv9SQjsJyTbXzl5JM/7CHIkmmDme7NcQNLsYC49Ms1kZD4KVBLDoraP77NR+560TQTMlx6nbFiPqAvLMMlHAMb8ZvmEFw3xDrQIBH294vQ4kYwRn9Bz34XZLCVvBjabb4jiczN5PUk/SUNAyWXkkUPgyEqhCGdjMcbYmLNXyTVLvXxxTzZeJqqHUK0DZ7+uuKnjoqGanpfHB++sEvzQQM5ynARCLuADwXRGO8IUmY16bcS10lC3S+K9LZu7i6dBDojUKvL3Moe+9anIBkIbIDW0WrRStjJHNvKDbLlqfimrzVRzncj8rrRlzTzm9+ziiLLTtj+MP6/So8yCS+T/7tECAwEAAaNXMFUwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUEDDAKBggrBgEFBQcDATAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFILZc1MnxK/bVnvrSf3W3OuTkpLVMA0GCSqGSIb3DQEBCwUAA4IBAQCac+S/g7+pMa2J597KUZImp0mqONFes+yUIVqKoBO6vUM9sj7EIzicdkOFnoleR6iDDKl+AWYIK4yx5gYBNkMaB98luAHbGvmb5FfS/sYKvAf/DsW2nC/BQJ2vwBzr9KHiqDUJalzUrrattQvwMojPsuBXLvP/9jmpmPj+VcalGcW2G42U0VEoovNqFgRPqJ5dHhMN5/4b7LyroSzMForTpYiZS1Jr3kcJS6bkbUVzGj6VBsefJpimsMMIEKnKDMICxnUJcF9CE6ymt7H5s+4B4jo9FOp/+1++x3+Vk2yFa8WjHTKibrmRdwcLayBpeRMDcPCM0Ps68dy1oP7z0Yp5"

@Test func subjectHashOldMatchesOpenSSL() throws {
    let subject = try #require(SubjectHash.subject(certificateDER: Data(base64Encoded: mitmCA)!))
    #expect(subject.first == 0x30 && subject.count == 42)
    #expect(SubjectHash.old(derSubject: subject) == "c8750f0d")
    #expect(SubjectHash.subject(certificateDER: Data([0x30, 0x82, 0xFF])) == nil)
}
