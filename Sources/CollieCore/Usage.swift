import Foundation
import CollieProtocol

/// Declarative plan-usage provider: runs `command` (argv, no implicit shell), parses stdout, reads each window by JSON pointer.
public struct UsageProvider: Codable, Sendable, Equatable {
    public enum Parse: Codable, Sendable, Equatable {
        case json                          // whole stdout is one JSON document
        case jsonlLast(contains: String)   // last stdout line containing the substring is the JSON document

        private enum K: String, CodingKey { case type, contains }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .type) {
            case "json": self = .json
            case "jsonlLast": self = .jsonlLast(contains: try c.decode(String.self, forKey: .contains))
            case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown parse type '\(t)'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .json: try c.encode("json", forKey: .type)
            case .jsonlLast(let s): try c.encode("jsonlLast", forKey: .type); try c.encode(s, forKey: .contains)
            }
        }
    }
    public struct Window: Codable, Sendable, Equatable {
        public var label: String
        public var usedPercent: String     // JSON pointer
        public var resetsAt: String?       // JSON pointer; epoch seconds or ISO-8601
        public init(label: String, usedPercent: String, resetsAt: String? = nil) {
            self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        }
    }
    public var id: String
    public var label: String
    public var enabled: Bool
    public var command: [String]
    public var timeoutSeconds: Double?     // default 30, max 120
    public var parse: Parse
    public var windows: [Window]
    public init(id: String, label: String, enabled: Bool, command: [String], timeoutSeconds: Double? = nil,
                parse: Parse, windows: [Window]) {
        self.id = id; self.label = label; self.enabled = enabled; self.command = command
        self.timeoutSeconds = timeoutSeconds; self.parse = parse; self.windows = windows
    }
}

public struct WindowValue: Codable, Sendable, Equatable {
    public var label: String
    public var usedPercent: Double?
    public var resetsAt: Date?
    public init(label: String, usedPercent: Double?, resetsAt: Date?) {
        self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct UsageReport: Codable, Sendable, Equatable {
    public var providerId: String
    public var label: String
    public var windows: [WindowValue]
    public var error: String?
    public var fetchedAt: Date
    public init(providerId: String, label: String, windows: [WindowValue] = [], error: String? = nil, fetchedAt: Date = Date()) {
        self.providerId = providerId; self.label = label; self.windows = windows; self.error = error; self.fetchedAt = fetchedAt
    }
}

/// RFC 6901 JSON Pointer over `JSONValue`.
public enum JSONPointer {
    public static func eval(_ p: String, in v: JSONValue) -> JSONValue? {
        if p.isEmpty { return v }
        guard p.hasPrefix("/") else { return nil }
        var cur = v
        for raw in p.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let tok = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch cur {
            case .object(let o): guard let n = o[tok] else { return nil }; cur = n
            case .array(let a):
                // RFC 6901: digits only, no leading zeros
                guard !tok.isEmpty, tok.allSatisfy(\.isASCII), tok.allSatisfy(\.isNumber), tok == "0" || !tok.hasPrefix("0"),
                      let i = Int(tok), i < a.count else { return nil }
                cur = a[i]
            default: return nil
            }
        }
        return cur
    }
}
