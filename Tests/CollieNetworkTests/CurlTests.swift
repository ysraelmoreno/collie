import Testing
import Foundation
@testable import CollieNetwork

private func flow(_ method: String, _ url: String = "https://api.example.com/v1/x?a=1&b=2", http: String = "HTTP/1.1",
                  headers: [(String, String)] = [], body: Body? = nil) -> Flow {
    Flow(id: "f", serial: nil, started: .now, method: method, url: url, httpVersion: http,
         reqHeaders: headers.map { Header(name: $0.0, value: $0.1) }, reqBody: body, status: nil, reason: nil,
         resHeaders: [], resBody: nil, timing: FlowTiming(start: .now), state: .pending, tls: nil)
}
private func text(_ s: String) -> Body { Body(size: s.utf8.count, data: Data(s.utf8)) }

@Test func curlQuotesPOSIX() {
    #expect(Curl.quote("it's") == #"'it'\''s'"#)
    let c = Curl.render(flow("GET", headers: [("X-Name", "O'Brien")]))
    #expect(c == #"curl 'https://api.example.com/v1/x?a=1&b=2' \"# + "\n  " + #"-H 'X-Name: O'\''Brien'"#)
}

@Test func curlMethodOnlyWhenNotImplicit() {
    #expect(!Curl.render(flow("GET")).contains("-X"))
    #expect(!Curl.render(flow("POST", body: text("a"))).contains("-X"))
    #expect(Curl.render(flow("POST")).contains("-X 'POST'"))
    #expect(Curl.render(flow("GET", body: text("a"))).contains("-X 'GET'"))
    #expect(Curl.render(flow("PUT", body: text("a"))).contains("-X 'PUT'"))
    #expect(Curl.render(flow("HEAD")).contains("--head") && !Curl.render(flow("HEAD")).contains("-X"))
}

@Test func curlDropsHopByHopAndPseudoHeaders() {
    let c = Curl.render(flow("GET", http: "HTTP/2.0", headers: [
        (":authority", "api.example.com"), (":path", "/v1/x"), ("Host", "api.example.com"), ("Connection", "keep-alive"),
        ("Keep-Alive", "5"), ("Transfer-Encoding", "chunked"), ("Content-Length", "3"), ("Proxy-Connection", "x"),
        ("Proxy-Authorization", "y"), ("TE", "trailers"), ("Upgrade", "h2c"), ("Cookie", "a=1"), ("cookie", "b=2"),
        ("Accept-Encoding", "gzip, deflate, br, zstd")]))
    let headers = c.components(separatedBy: "-H ").dropFirst().map { $0.prefix { $0 != ":" } }
    #expect(headers == ["'Cookie", "'cookie"])   // Accept-Encoding: --compressed sends curl's own
    #expect(c.contains("--http2") && c.contains("--compressed"))
    #expect(!Curl.render(flow("GET")).contains("--compressed") && !Curl.render(flow("GET")).contains("--http2"))
}

@Test func curlBodies() {
    let json = Curl.render(flow("POST", body: text(#"{"n":"O'Brien"}"#)))
    #expect(json.hasSuffix(#"--data-raw '{"n":"O'\''Brien"}'"#) && json.hasPrefix("curl "))
    let multipart = "--b\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--b--\r\n"
    #expect(Curl.render(flow("POST", body: text(multipart))).contains("--data-raw " + Curl.quote(multipart)))
    let bin = Curl.render(flow("POST", body: Body(size: 3, data: Data([0, 0xFF, 1]))))
    #expect(bin.hasPrefix("printf %s 'AP8B' | base64 -d | curl ") && bin.hasSuffix("--data-binary @-"))
    let gz = Curl.render(flow("POST", body: Body(size: 2, contentEncoding: "gzip", data: Data("hi".utf8))))
    #expect(gz.contains("--data-binary @-"))
    let cut = Curl.render(flow("POST", body: Body(size: 10, truncated: true, data: Data("abc".utf8))))
    #expect(cut.hasPrefix("# warning: request body truncated (3 of 10 bytes)\n"))
}

/// Runs the generated command against a one-shot local server and compares what it received.
@Test func curlRoundTrip() throws {
    let server = #"""
import base64, json, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(4)
print(s.getsockname()[1], flush=True)
for _ in range(int(sys.argv[1])):
    c, _ = s.accept(); data = b""
    while b"\r\n\r\n" not in data: data += c.recv(65536)
    head, body = data.split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    hs = [l.split(": ", 1) for l in lines[1:]]
    n = int(dict((k.lower(), v) for k, v in hs).get("content-length", "0"))
    while len(body) < n: body += c.recv(65536)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); c.close()
    print(json.dumps({"line": lines[0], "headers": hs, "body": base64.b64encode(body).decode()}), flush=True)
"""#
    let py = Process()
    py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    py.arguments = ["-c", server, "2"]
    let out = Pipe(); py.standardOutput = out
    try py.run()
    defer { py.terminate() }
    var buffer = Data()
    func line() -> String {
        while !buffer.contains(0x0A) { let d = out.fileHandleForReading.availableData; if d.isEmpty { break }; buffer.append(d) }
        let i = buffer.firstIndex(of: 0x0A) ?? buffer.endIndex
        defer { buffer = Data(buffer[(i == buffer.endIndex ? i : i + 1)...]) }
        return String(decoding: buffer[..<i], as: UTF8.self)
    }
    let port = line()
    let json = #"{"name":"O'Brien","tags":["a b","c\"d"]}"#
    let binary = Data([0, 1, 2, 0xFF, 0x27, 0x0A])
    let flows = [
        flow("POST", "http://127.0.0.1:\(port)/items?q=it's", headers: [
            ("Host", "127.0.0.1:\(port)"), ("Content-Type", "application/json"), ("X-Quote", "it's"),
            ("Connection", "keep-alive"), ("Content-Length", "999"), ("Proxy-Connection", "x"),
            ("Accept-Encoding", "gzip, zstd")], body: text(json)),
        flow("PATCH", "http://127.0.0.1:\(port)/bin", headers: [("Content-Type", "application/octet-stream")],
             body: Body(size: binary.count, data: binary)),
    ]
    for (f, sent) in zip(flows, [Data(json.utf8), binary]) {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", Curl.render(f) + " -s -o /dev/null"]
        try sh.run(); sh.waitUntilExit()
        #expect(sh.terminationStatus == 0)
        let got = try #require(try JSONSerialization.jsonObject(with: Data(line().utf8)) as? [String: Any])
        let path = String(f.url.split(separator: "/", maxSplits: 3).last!)
        #expect(got["line"] as? String == "\(f.method) /\(path) HTTP/1.1")
        let hs = (got["headers"] as? [[String]] ?? []).map { ($0[0].lowercased(), $0[1]) }
        for h in f.reqHeaders where !["connection", "content-length", "proxy-connection", "host", "accept-encoding"].contains(h.name.lowercased()) {
            #expect(hs.contains { $0 == (h.name.lowercased(), h.value) }, "\(h.name)")
        }
        #expect(!hs.contains { $0.0 == "proxy-connection" } && hs.first { $0.0 == "content-length" }?.1 == "\(sent.count)")
        let ae = hs.filter { $0.0 == "accept-encoding" }.map(\.1)   // curl's own, once, never the client's zstd
        #expect(f.reqHeaders.contains { $0.name == "Accept-Encoding" } ? ae.count == 1 && !ae[0].contains("zstd") : ae.isEmpty)
        #expect(Data(base64Encoded: got["body"] as? String ?? "") == sent)
    }
}
