public enum ErrorCode: String, Codable, Sendable {
    case unauthorized, notFound, notConnected, notRunning, ambiguous, invalidArgs,
         timeout, deadlock, notShepherd, tooMany, unsupportedVersion, daemonUnavailable, unavailable, `internal`
}

public struct ProtocolError: Error, Codable, Sendable, Equatable {
    public var code: ErrorCode
    public var message: String
    public init(code: ErrorCode, message: String) { self.code = code; self.message = message }
}

public struct Request: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var terminalId: String?
    public var token: String?
    public var command: String
    public var args: [String: JSONValue]
    public var cwd: String?
    public init(v: Int = Protocol.version, id: String, terminalId: String? = nil, token: String? = nil,
                command: String, args: [String: JSONValue] = [:], cwd: String? = nil) {
        self.v = v; self.id = id; self.terminalId = terminalId; self.token = token
        self.command = command; self.args = args; self.cwd = cwd
    }
}

public struct Response: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: ProtocolError?
    public init(v: Int = Protocol.version, id: String, ok: Bool, result: JSONValue? = nil, error: ProtocolError? = nil) {
        self.v = v; self.id = id; self.ok = ok; self.result = result; self.error = error
    }
}

public enum Protocol { public static let version = 1 }
