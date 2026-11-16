import Foundation

/// A map-local rule: a request matching `match` gets a fabricated response (or its connection cut) without reaching the
/// server. Rules are applied by the mitmdump addon (`AddonScript`), which reads the enabled ones, in order, from the
/// rules file `{"v":1,"rules":[…]}`; the first enabled match wins.
public struct MapRule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var enabled: Bool
    public var match: Match
    public var action: Action
    /// Applied before the action (with `drop`, a timeout).
    public var delayMs: Int

    /// Empty fields match anything; an empty `Match` matches every request.
    public struct Match: Codable, Equatable, Sendable {
        /// Upper-cased.
        public var method: String?
        /// fnmatch globs; `path` has no query.
        public var host: String?
        public var path: String?
        /// Pairs the request query must contain (any order, other pairs allowed).
        public var query: [String: String]

        public init(method: String? = nil, host: String? = nil, path: String? = nil, query: [String: String] = [:]) {
            self.method = method?.uppercased(); self.host = host; self.path = path; self.query = query
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(method: try c.decodeIfPresent(String.self, forKey: .method),
                      host: try c.decodeIfPresent(String.self, forKey: .host),
                      path: try c.decodeIfPresent(String.self, forKey: .path),
                      query: try c.decodeIfPresent([String: String].self, forKey: .query) ?? [:])
        }

        public var isEmpty: Bool { method == nil && host == nil && path == nil && query.isEmpty }
    }

    /// JSON: `{"local":{"status":…,"headers":[…],"bodyB64":…}}` or `{"drop":{}}` (the addon reads this shape).
    public enum Action: Codable, Equatable, Sendable {
        case local(status: Int, headers: [Header], bodyB64: String?)
        case drop
    }

    public init(id: String, name: String?, enabled: Bool, match: Match, action: Action, delayMs: Int = 0) {
        self.id = id; self.name = name; self.enabled = enabled; self.match = match; self.action = action; self.delayMs = delayMs
    }

    public static let maxRules = 100
    public static let maxBody = 5 << 20
    public static let maxFile = 20 << 20
    public static let maxDelayMs = 60_000

    /// 6 characters of `a-z0-9`.
    public static func makeID() -> String {
        String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// The body as decoded bytes (nil: no body).
    public var body: Data? {
        guard case .local(_, _, let b64?) = action else { return nil }
        return Data(base64Encoded: b64)
    }

    public static func validate(_ rules: [MapRule]) throws(MapRuleError) {
        guard rules.count <= maxRules else { throw .tooMany(rules.count) }
        for r in rules {
            for g in [r.match.host, r.match.path].compactMap({ $0 }) where !(1...200).contains(g.count) { throw .glob(g) }
            guard (0...maxDelayMs).contains(r.delayMs) else { throw .delay(r.delayMs) }
            guard case .local(let status, let headers, let b64) = r.action else { continue }
            guard (100...599).contains(status) else { throw .status(status) }
            if let h = headers.first(where: { ["content-encoding", "content-length"].contains($0.name.lowercased()) }) {
                throw .forbiddenHeader(h.name)
            }
            if let b64 {
                guard let body = Data(base64Encoded: b64) else { throw .badBody }
                guard body.count <= maxBody else { throw .bodyTooLarge(body.count) }
            }
        }
        // ponytail: encodes once more just to measure; fine at ≤ 100 rules
        let size = (try? JSONEncoder().encode(rules).count) ?? 0
        guard size <= maxFile else { throw .fileTooLarge(size) }
    }

    /// The default `Content-Type` for a body with none given.
    public static func guessedContentType(_ body: Data) -> String {
        if (try? JSONSerialization.jsonObject(with: body)) != nil { return "application/json" }
        if let s = String(data: body, encoding: .utf8),
           !s.unicodeScalars.contains(where: { $0.value < 0x20 && !"\t\n\r".unicodeScalars.contains($0) }) {
            return "text/plain"
        }
        return "application/octet-stream"
    }
}

public enum MapRuleError: Error, Equatable, Sendable {
    case tooMany(Int), glob(String), delay(Int), status(Int), forbiddenHeader(String), badBody, bodyTooLarge(Int)
    case fileTooLarge(Int)

    public var message: String {
        switch self {
        case .tooMany(let n): "Too many rules (\(n)); at most \(MapRule.maxRules)"
        case .glob(let g): "Host and path globs must have 1 to 200 characters (got \(g.count))"
        case .delay(let d): "Delay must be 0 to \(MapRule.maxDelayMs) ms (got \(d))"
        case .status(let s): "Status must be 100 to 599 (got \(s))"
        case .forbiddenHeader(let h): "Header '\(h)' is not allowed: the body is sent as is and its length is computed"
        case .badBody: "Body is not valid base64"
        case .bodyTooLarge(let n): "Body is \(n) bytes; at most \(MapRule.maxBody) (5 MiB)"
        case .fileTooLarge(let n): "Rules take \(n) bytes; at most \(MapRule.maxFile) (20 MiB)"
        }
    }
}
