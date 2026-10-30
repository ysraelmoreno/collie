import Foundation

// Wire format between the mitmdump addon (`AddonScript.source`) and collied.
//
// Run as: mitmdump -q -s <addon.py> [--set collie_body_cap=<bytes>]
// `-q` silences mitmdump's own flow dump so stdout carries only addon lines; any line
// that is not a JSON object with a known "type" is ignored by `FlowEvent.decode(line:)`.
//
// One JSON object per line (UTF-8, flushed per line). `ts`/`ttfb` are Unix epoch seconds (Double).
// Headers are ordered arrays of {"name","value"} (duplicates kept). Bodies are the raw wire
// bytes (still content-encoded), base64 in "data", cut at collie_body_cap (default 10 MiB):
//   {"size": <full byte count>, "truncated": <bool>, "contentEncoding": <string|null>, "data": "<base64>"}
//
//   {"type":"request","id":"<mitm flow id>","ts":1730000000.1,"method":"GET",
//    "url":"https://host/path?q","httpVersion":"HTTP/1.1","headers":[...],"body":<Body|null>,
//    "tls":{"sni":"host","alpn":"h2"}|null}
//   {"type":"response","id":"…","ttfb":1730000000.2,"ts":1730000000.3,"status":200,"reason":"OK",
//    "headers":[...],"body":<Body|null>}
//   {"type":"error","id":"…","ts":1730000000.4,"message":"connection reset"}
//   {"type":"tunneled","id":"…","ts":1730000000.4}      // websocket handshake completed

public enum FlowEvent: Equatable, Sendable {
    case request(Request)
    case response(Response)
    case error(id: String, ts: Date, message: String)
    case tunneled(id: String, ts: Date)

    public struct Request: Equatable, Sendable {
        public var id: String
        public var ts: Date
        public var method: String
        public var url: String
        public var httpVersion: String
        public var headers: [Header]
        public var body: Body?
        public var tls: FlowTLS?
    }

    public struct Response: Equatable, Sendable {
        public var id: String
        public var ttfb: Date?
        public var ts: Date
        public var status: Int
        public var reason: String?
        public var headers: [Header]
        public var body: Body?
    }

    private struct Wire: Decodable {
        var type: String
        var id: String
        var ts: Double
        var ttfb: Double?
        var method: String?
        var url: String?
        var httpVersion: String?
        var headers: [Header]?
        var body: Body?
        var tls: FlowTLS?
        var status: Int?
        var reason: String?
        var message: String?
    }

    /// nil for blank, non-JSON or unknown lines (mitmdump may still print its own logs).
    public static func decode(line: some StringProtocol) -> FlowEvent? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(line.utf8)) else { return nil }
        let ts = Date(timeIntervalSince1970: w.ts)
        switch w.type {
        case "request":
            guard let method = w.method, let url = w.url else { return nil }
            return .request(Request(id: w.id, ts: ts, method: method, url: url, httpVersion: w.httpVersion ?? "",
                                    headers: w.headers ?? [], body: w.body, tls: w.tls))
        case "response":
            guard let status = w.status else { return nil }
            return .response(Response(id: w.id, ttfb: w.ttfb.map(Date.init(timeIntervalSince1970:)), ts: ts,
                                      status: status, reason: w.reason, headers: w.headers ?? [], body: w.body))
        case "error": return .error(id: w.id, ts: ts, message: w.message ?? "")
        case "tunneled": return .tunneled(id: w.id, ts: ts)
        default: return nil
        }
    }
}
