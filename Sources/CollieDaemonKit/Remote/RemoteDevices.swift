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
    /// When the current token was handed out (nil: at `pairedAt`); past `RemoteDevices.tokenLife` hello hands a new one.
    var tokenIssuedAt: Date?
    /// A rotated token not yet used: both work until the new one is, which then replaces the old.
    var pendingHash: String?
    var lastSeenAt: Date?
    var lastAddress: String?
    /// lan | tailscale
    var lastVia: String?

    /// For the app's device sheet: never the hashes.
    var publicJSON: [String: JSONValue] {
        var o: [String: JSONValue] = ["id": .string(id.uuidString.lowercased()), "name": .string(name), "model": .string(model),
                                      "scope": .string(scope.rawValue), "pairedAt": .string(pairedAt.ISO8601Format())]
        if let lastSeenAt { o["lastSeenAt"] = .string(lastSeenAt.ISO8601Format()) }
        if let lastAddress { o["lastAddress"] = .string(lastAddress) }
        if let lastVia { o["lastVia"] = .string(lastVia) }
        return o
    }
}

/// The paired devices, in `<root>/remote/devices.json` (0600, dir 0700). Tokens are 32 random bytes (base64url) handed
/// out once; only their SHA-256 is stored and compared in constant time. Under `lock`; every change is written at once.
final class RemoteDevices: @unchecked Sendable {
    static let tokenLife: TimeInterval = 90 * 86_400
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
        let t = now()
        let dev = RemoteDevice(id: UUID(), name: d.name, model: d.model, scope: .full, pairedAt: t, fingerprint: fingerprint,
                               tokenHash: Self.hash(token), tokenIssuedAt: t, lastAddress: d.address, lastVia: d.via.rawValue)
        try change { $0.append(dev) }
        return (dev, token)
    }

    /// The device `id` when `token` is its own and it was paired with the identity `fingerprint`. Devices of another
    /// identity are dropped here (their pins can't match this Mac any more).
    func verify(id: UUID, token: String, fingerprint: String) -> RemoteDevice? {
        lock.withLock { find(id, Self.hash(token), fingerprint).map { devices[$0.index] } }
    }

    /// `session.hello`: verifies like `verify`, records where it came from, and past `tokenLife` hands out a new token
    /// (`rotate`). The old token keeps working until the new one is first used, which then replaces it.
    /// ponytail: a phone that loses the rotated token keeps using the old one (no second rotation while one is pending).
    func hello(id: UUID, token: String, fingerprint: String, address: String, via: RemoteVia) -> (device: RemoteDevice, rotate: String?)? {
        let t = now()
        return lock.withLock { () -> (RemoteDevice, String?)? in
            guard let (i, pending) = find(id, Self.hash(token), fingerprint) else { return nil }
            var next = devices, d = next[i], rotate: String?
            if pending { d.tokenHash = d.pendingHash!; d.pendingHash = nil; d.tokenIssuedAt = t }
            else if d.pendingHash == nil, t.timeIntervalSince(d.tokenIssuedAt ?? d.pairedAt) > Self.tokenLife,
                    let new = try? Self.randomToken() {
                d.pendingHash = Self.hash(new); rotate = new
            }
            d.lastSeenAt = t; d.lastAddress = address; d.lastVia = via.rawValue
            next[i] = d
            guard (try? save(next)) != nil else { return rotate == nil ? (devices[i], nil) : nil }   // a token never persisted is never handed out
            devices = next
            return (d, rotate)
        }
    }

    /// Under `lock`: the device's index and whether `hash` is its pending (rotated) token. Drops other identities' devices.
    private func find(_ id: UUID, _ hash: String, _ fingerprint: String) -> (index: Int, pending: Bool)? {
        if devices.contains(where: { $0.fingerprint != fingerprint }) {
            let kept = devices.filter { $0.fingerprint == fingerprint }
            if (try? save(kept)) != nil { devices = kept }
        }
        var hit: (Int, Bool)?
        for (i, d) in devices.enumerated() {   // every hash compared: no early exit
            let cur = constantTimeEqual(d.tokenHash, hash), pend = d.pendingHash.map { constantTimeEqual($0, hash) } ?? false
            if d.id == id, d.fingerprint == fingerprint, cur || pend { hit = (i, pend && !cur) }
        }
        return hit
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
