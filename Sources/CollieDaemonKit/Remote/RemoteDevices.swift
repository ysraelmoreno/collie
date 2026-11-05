import Foundation
import CryptoKit
import Security
import CollieProtocol

/// A paired phone (remote API spec §2). Only the SHA-256 of its token is kept.
struct RemoteDevice: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case full, read }
    var id: UUID
    var name: String
    var model: String
    var scope: Scope
    var pairedAt: Date
    /// The identity fingerprint it pinned at pairing: another identity (rotated, restored) leaves it unusable.
    var fingerprint: String
    var tokenHash: String
}

/// The paired devices, in `<root>/remote/devices.json` (0600, dir 0700). Tokens are 32 random bytes (base64url) handed
/// out once; only their SHA-256 is stored and compared in constant time. Under `lock`; every change is written at once.
final class RemoteDevices: @unchecked Sendable {
    private let file: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var devices: [RemoteDevice]

    init(dir: URL, now: @escaping @Sendable () -> Date = Date.init) {
        file = dir.appendingPathComponent("devices.json"); self.now = now
        // ponytail: an unreadable store reads as no device (fail closed: every phone pairs again)
        devices = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.iso.decode([RemoteDevice].self, from: $0) } ?? []
    }

    var all: [RemoteDevice] { lock.withLock { devices } }

    /// A new device for a confirmed pairing; returns it and its token (never stored, never shown again).
    func add(_ d: RemotePairing.Device, fingerprint: String) throws -> (RemoteDevice, String) {
        let token = try Self.randomToken()
        let dev = RemoteDevice(id: UUID(), name: d.name, model: d.model, scope: .full, pairedAt: now(), fingerprint: fingerprint,
                               tokenHash: Self.hash(token))
        try change { $0.append(dev) }
        return (dev, token)
    }

    /// The device `id` when `token` is its own and it was paired with the identity `fingerprint`. Devices of another
    /// identity are dropped here (their pins can't match this Mac any more).
    func verify(id: UUID, token: String, fingerprint: String) -> RemoteDevice? {
        let h = Self.hash(token)
        return lock.withLock {
            if devices.contains(where: { $0.fingerprint != fingerprint }) {
                let before = devices
                devices.removeAll { $0.fingerprint != fingerprint }
                if (try? save(devices)) == nil { devices = before }
            }
            var hit: RemoteDevice?
            for d in devices where constantTimeEqual(d.tokenHash, h) && d.id == id { hit = d }   // no early exit on the hash
            return hit
        }
    }

    @discardableResult func revoke(_ id: UUID) throws -> Bool {
        try change { ds in let n = ds.count; ds.removeAll { $0.id == id }; return ds.count != n }
    }

    @discardableResult func setScope(_ id: UUID, _ scope: RemoteDevice.Scope) throws -> Bool {
        try change { ds in
            guard let i = ds.firstIndex(where: { $0.id == id }) else { return false }
            ds[i].scope = scope; return true
        }
    }

    /// Identity rotated: every pin broke.
    func revokeAll() throws { try change { $0.removeAll() } }

    @discardableResult private func change<T>(_ f: (inout [RemoteDevice]) -> T) throws -> T {
        try lock.withLock {
            var next = devices
            let r = f(&next)
            try save(next)
            devices = next
            return r
        }
    }

    private func save(_ ds: [RemoteDevice]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let tmp = dir.appendingPathComponent(".devices-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try JSONEncoder.iso.encode(ds), attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ProtocolError(code: .internal, message: "cannot write the remote device store")
        }
    }

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// 32 random bytes, base64url without padding (43 chars).
    static func randomToken() throws -> String {
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else {
            throw ProtocolError(code: .internal, message: "no randomness")
        }
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
