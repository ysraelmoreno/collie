import Testing
import Foundation
import Security
import CryptoKit
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 1 (docs/superpowers/specs/2026-11-04-remote-api-design.md §1): source filter, TLS identity,
/// the WSS listener and `admin.remote`.
@Suite struct RemoteAddressTests {
    @Test func classifiesSources() {
        let cases: [(String, Bool, RemoteVia?)] = [
            ("192.168.1.23", false, .lan), ("10.0.0.5", false, .lan), ("172.16.0.1", false, .lan), ("172.31.255.1", false, .lan),
            ("172.32.0.1", false, nil), ("169.254.3.4", false, .lan),
            ("100.64.0.1", false, .tailscale), ("100.127.255.254", false, .tailscale), ("100.128.0.1", false, nil),
            ("8.8.8.8", false, nil), ("127.0.0.1", false, nil), ("0.0.0.0", false, nil),
            ("::1", false, nil), ("fe80::1", false, .lan), ("fe80::1%en0", false, .lan), ("fd12::1", false, .lan),
            ("fd7a:115c:a1e0::5", false, .tailscale), ("2001:4860::1", false, nil),
            ("::ffff:192.168.1.2", false, .lan), ("::ffff:8.8.8.8", false, nil), ("::ffff:127.0.0.1", false, nil),
            ("192.168.1.23", true, nil), ("fe80::1", true, nil), ("100.100.1.1", true, .tailscale), ("fd7a:115c:a1e0::5", true, .tailscale),
            ("nonsense", false, nil), ("", false, nil),
        ]
        for (ip, ts, want) in cases { #expect(RemoteAddress.via(ip, tailscaleOnly: ts) == want, "\(ip) tailscaleOnly=\(ts)") }
    }

    @Test func loopbackOnlyWhenAllowed() {
        #expect(RemoteAddress.via("127.0.0.1", tailscaleOnly: false, allowLoopback: true) == .lan)
        #expect(RemoteAddress.via("::1", tailscaleOnly: false, allowLoopback: true) == .lan)
        #expect(RemoteAddress.via("127.0.0.1", tailscaleOnly: true, allowLoopback: true) == nil)
    }
}

private func perms(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int) ?? -1 }

@Suite struct RemoteIdentityTests {
    @Test func createsLoadsAndRotates() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-rid-\(UUID().uuidString.prefix(8))/remote")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let a = try RemoteIdentity.loadOrCreate(dir: dir)
        #expect(a.fingerprint.count == 43 && !a.fingerprint.contains("=") && !a.fingerprint.contains("+") && !a.fingerprint.contains("/"))
        #expect(perms(dir) == 0o700)
        #expect(perms(dir.appendingPathComponent("identity.p12")) == 0o600)
        #expect(perms(dir.appendingPathComponent("identity.pass")) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["identity.p12", "identity.pass"])   // no PEM left
        #expect(try RemoteIdentity.loadOrCreate(dir: dir).fingerprint == a.fingerprint)
        let b = try RemoteIdentity.rotate(dir: dir)
        #expect(b.fingerprint != a.fingerprint)
        #expect(try RemoteIdentity.loadOrCreate(dir: dir).fingerprint == b.fingerprint)
    }

    /// Root cause of the flaky suites (2026-11-05): a P-256 scalar starting with 0x00 (1 key in 256) is written by
    /// LibreSSL into the PKCS#12 as a 31-byte private key, and SecPKCS12Import drops it silently (status 0, no item).
    /// Such keys are never used: the next one is drawn.
    @Test func leadingZeroKeysAreSkipped() throws {
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 31, &raw[1])
        let zero = try P256.Signing.PrivateKey(rawRepresentation: raw), good = P256.Signing.PrivateKey()
        var queue = [zero, zero, good]
        let k = RemoteIdentity.usableKey { queue.removeFirst() }
        #expect(k.rawRepresentation == good.rawRepresentation && queue.isEmpty)
        // and why: the same key through the real path doesn't load
        let dir = URL(fileURLWithPath: "/tmp/collie-rid-\(UUID().uuidString.prefix(8))/remote")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(throws: ProtocolError.self) { _ = try RemoteIdentity.rotate(dir: dir, key: zero) }
        #expect(try RemoteIdentity.rotate(dir: dir, key: good).fingerprint.count == 43)
    }

    /// An identity that exists but doesn't load is an error, never replaced: a silent new one would break every pin.
    @Test func unreadableIdentityIsNotReplaced() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-rid-\(UUID().uuidString.prefix(8))/remote")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        _ = try RemoteIdentity.loadOrCreate(dir: dir)
        let p12 = dir.appendingPathComponent("identity.p12")
        try Data("garbage".utf8).write(to: p12)
        #expect(throws: ProtocolError.self) { _ = try RemoteIdentity.loadOrCreate(dir: dir) }
        #expect(try Data(contentsOf: p12) == Data("garbage".utf8))
    }
}

/// A native client like the phone's: `URLSessionWebSocketTask`, trusting only the pinned SHA-256.
private final class PinnedClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let pin: String
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(pin: String) { self.pin = pin }

    /// true: the WebSocket opened (TLS with the pinned cert + upgrade accepted).
    static func opens(port: Int, pin: String, origin: String? = nil, host: String = "127.0.0.1") async -> Bool {
        let c = PinnedClient(pin: pin)
        let session = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: URL(string: "wss://\(host):\(port)/")!, timeoutInterval: 5)
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        let task = session.webSocketTask(with: req)
        return await withCheckedContinuation { k in
            c.lock.withLock { c.cont = k }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { c.finish(false) }
        }
    }
    private func finish(_ v: Bool) { lock.withLock { let k = cont; cont = nil; return k }?.resume(returning: v) }

    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = ch.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              RemoteIdentity.fingerprint(der: SecCertificateCopyData(leaf) as Data) == pin else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) { finish(true) }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { finish(false) }
}

@Suite struct RemoteAdminTests {
    private func admin(_ d: Daemon, _ p: Paths, _ args: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.remote", args: args), timeoutSeconds: 30)
        guard case .object(let o)? = r.result else { throw ProtocolError(code: .internal, message: "\(r)") }
        return o
    }
    private func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { Int(n) } else { -1 } }
    private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }

    @Test func offByDefaultAndAppOnly() async throws {
        try await withDaemon { d, p in
            let s = try await admin(d, p)
            #expect(s["enabled"] == .bool(false) && s["listening"] == .bool(false) && int(s["port"]) == 47820 && s["tailscaleOnly"] == .bool(false))
            let (id, _) = try await spawn(d, p, "T")
            let t = try await tokenOf(d, id)
            let r = try await send(p, Request(id: "t", terminalId: id, token: t, command: "admin.remote", args: ["action": "on"]))
            #expect(r.error?.code == .unauthorized)
            #expect(CollieSettings.load(p.root).remote == nil)
            let bad = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.remote", args: ["action": "on", "port": 80]))
            #expect(bad.error?.code == .invalidArgs)
        }
    }

    @Test func servesPinnedWebSocketAndStops() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let on = try await admin(d, p, ["action": "on", "port": 0])
            let port = int(on["listeningPort"]), pin = str(on["fingerprint"])
            #expect(on["enabled"] == .bool(true) && on["listening"] == .bool(true) && port > 0 && pin.count == 43, "\(on)")
            #expect(CollieSettings.load(p.root).remote?.enabled == true)
            #expect(await PinnedClient.opens(port: port, pin: pin))
            #expect(await !PinnedClient.opens(port: port, pin: String(repeating: "A", count: 43)))   // another cert: refused by the pin
            #expect(await !PinnedClient.opens(port: port, pin: pin, origin: "https://evil.example"))   // a browser page
            let off = try await admin(d, p, ["action": "off"])
            #expect(off["enabled"] == .bool(false) && off["listening"] == .bool(false))
            #expect(await !PinnedClient.opens(port: port, pin: pin))
            #expect(try await admin(d, p)["fingerprint"] == .string(pin))   // the identity outlives the listener
        }
    }

    @Test func refusesLoopbackPeers() async throws {
        try await withDaemon { d, p in
            let on = try await admin(d, p, ["action": "on", "port": 0])
            #expect(on["listening"] == .bool(true))
            #expect(await !PinnedClient.opens(port: int(on["listeningPort"]), pin: str(on["fingerprint"])))
        }
    }

    @Test func startsWithTheDaemonWhenEnabled() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-rst-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        var s = CollieSettings(); s.remote = RemoteSettings(enabled: true, port: 0, tailscaleOnly: false)
        try s.save(root)
        let d = try Daemon(config: testConfig(Paths(root: root)))
        try await d.start()
        let r = try await send(Paths(root: root), Request(id: "x", token: d.adminToken, command: "admin.remote"), timeoutSeconds: 30)
        await d.stop()
        guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
        #expect(o["listening"] == .bool(true), "\(o)")
    }

    /// A start that can't make or read the identity says why in admin.remote (it used to say only listening: false).
    @Test func startFailureIsReported() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-rsf-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        var s = CollieSettings(); s.remote = RemoteSettings(enabled: true, port: 0, tailscaleOnly: false)
        try s.save(root)
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("remote"))   // the identity can't be made
        let d = try Daemon(config: testConfig(Paths(root: root)))
        try await d.start()
        let r = try await send(Paths(root: root), Request(id: "x", token: d.adminToken, command: "admin.remote"), timeoutSeconds: 30)
        await d.stop()
        guard case .object(let o)? = r.result, case .string(let e)? = o["error"] else { Issue.record("\(r)"); return }
        #expect(o["listening"] == .bool(false) && e.contains("identity"), "\(o)")
    }
}
