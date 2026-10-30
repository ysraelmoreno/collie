import Foundation

public struct Header: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// Raw bytes as sent on the wire (still content-encoded); `data` holds at most the addon's body cap.
public struct Body: Codable, Equatable, Sendable {
    public var size: Int
    public var truncated: Bool
    public var contentEncoding: String?
    public var data: Data
    public init(size: Int, truncated: Bool = false, contentEncoding: String? = nil, data: Data) {
        self.size = size; self.truncated = truncated; self.contentEncoding = contentEncoding; self.data = data
    }
}

public struct FlowTiming: Codable, Equatable, Sendable {
    public var start: Date
    public var ttfb: Date?
    public var end: Date?
}

public struct FlowTLS: Codable, Equatable, Sendable {
    public var sni: String?
    public var alpn: String?
    public init(sni: String?, alpn: String?) { self.sni = sni; self.alpn = alpn }
}

public enum FlowState: Codable, Equatable, Sendable {
    case pending, done, failed(String), tunneled
}

public struct Flow: Codable, Equatable, Sendable {
    public var id: String
    public var serial: String?
    public var started: Date
    public var method: String
    public var url: String
    public var httpVersion: String
    public var reqHeaders: [Header]
    public var reqBody: Body?
    public var status: Int?
    public var reason: String?
    public var resHeaders: [Header]
    public var resBody: Body?
    public var timing: FlowTiming
    public var state: FlowState
    public var tls: FlowTLS?

    public var summary: FlowSummary {
        let u = URLComponents(string: url)
        var path = u?.percentEncodedPath ?? url
        if path.isEmpty { path = "/" }
        if let q = u?.percentEncodedQuery { path += "?" + q }
        return FlowSummary(
            id: id, method: method, host: u?.host ?? "", path: path, status: status, size: resBody?.size,
            durationMs: timing.end.map { Int(($0.timeIntervalSince(timing.start) * 1000).rounded()) }, state: state)
    }
}

public struct FlowSummary: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var host: String
    public var path: String
    public var status: Int?
    public var size: Int?
    public var durationMs: Int?
    public var state: FlowState
}
