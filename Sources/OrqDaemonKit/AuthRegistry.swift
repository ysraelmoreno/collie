import Foundation
import Security

func randomHex(_ n: Int = 32) -> String {
    var b = [UInt8](repeating: 0, count: n)
    precondition(SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess)
    return b.map { String(format: "%02x", $0) }.joined()
}

/// Constant-time for equal lengths; length itself is not secret (fixed 64 hex chars).
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var d: UInt8 = 0
    for i in 0..<x.count { d |= x[i] ^ y[i] }
    return d == 0
}

public actor AuthRegistry {
    public let adminToken: String
    private var tokens: [UUID: String] = [:]

    private let adminTokenFile: URL

    /// Generates the admin token; `persist()` writes it once the daemon owns the socket.
    public init(adminTokenFile: URL) {
        adminToken = randomHex()
        self.adminTokenFile = adminTokenFile
    }

    /// Writes the token to `adminTokenFile` (0600, root dir 0700).
    public func persist() throws {
        let dir = adminTokenFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(adminTokenFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600) // file may pre-exist with looser mode
        let bytes = Array(adminToken.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    public func issue(for terminal: UUID) -> String {
        let t = randomHex(); tokens[terminal] = t; return t
    }
    public func verify(terminal: UUID, token: String) -> Bool {
        guard let t = tokens[terminal] else { return false }
        return constantTimeEqual(t, token)
    }
    public func revoke(_ terminal: UUID) { tokens[terminal] = nil }
    public func revokeAll() { tokens.removeAll() }
}
