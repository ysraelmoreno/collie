import Testing
import Foundation
import Security
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 3 (spec §2, §3.1, §3.2): pair, pair.wait and session.hello end to end, with a real pinned
/// `URLSessionWebSocketTask` like the phone's, plus the app's admin.remote.* commands.
final class RemotePhone: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let pin: String
    private let lock = NSLock()
    private var opened: CheckedContinuation<Bool, Never>?
    private var session: URLSession!
    private(set) var task: URLSessionWebSocketTask!
    private var seq = 0

    private init(pin: String) { self.pin = pin }

    static func connect(port: Int, pin: String) async throws -> RemotePhone {
        let c = RemotePhone(pin: pin)
        c.session = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        c.task = c.session.webSocketTask(with: URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/")!, timeoutInterval: 10))
        let ok = await withCheckedContinuation { k in
            c.lock.withLock { c.opened = k }
            c.task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { c.open(false) }
        }
        guard ok else { c.close(); throw ProtocolError(code: .notConnected, message: "websocket did not open") }
        return c
    }
    func close() { task?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel() }

    /// The next JSON object the Mac sent; nil once the socket is closed.
    func next(timeout: Double = 15) async -> [String: JSONValue]? {
        let t = task!
        return await withTaskGroup(of: [String: JSONValue]?.self) { g in
            g.addTask {
                guard case .string(let s)? = try? await t.receive(),
                      case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) else { return nil }
                return o
            }
            g.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r
        }
    }

    func send(_ command: String, _ args: [String: JSONValue] = [:], v: Int = 1) async throws -> String {
        let id = lock.withLock { seq += 1; return "c-\(seq)" }
        let req = Request(v: v, id: id, command: command, args: args)
        try await task.send(.string(String(decoding: try JSONEncoder().encode(req), as: UTF8.self)))
        return id
    }

    /// Sends and returns the reply with the same id (skipping pushed frames).
    func call(_ command: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        let id = try await send(command, args)
        while let o = await next() {
            guard case .string(let rid)? = o["id"], rid == id else { continue }
            return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(JSONValue.object(o)))
        }
        throw ProtocolError(code: .notConnected, message: "closed before replying to \(command)")
    }

    /// The `closing` frame the Mac sends before it closes the socket: its code.
    func closingCode(timeout: Double = 15) async -> Int? {
        while let o = await next(timeout: timeout) {
            if o["t"] == .string("closing"), case .number(let n)? = o["code"] { return Int(n) }
        }
        return nil
    }

    private func open(_ v: Bool) { lock.withLock { let k = opened; opened = nil; return k }?.resume(returning: v) }
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = ch.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              RemoteIdentity.fingerprint(der: SecCertificateCopyData(leaf) as Data) == pin else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) { open(true) }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { open(false) }
}

private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
private func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { Int(n) } else { -1 } }

@Suite(.serialized) struct RemoteSessionTests {
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
    }
    private func on(_ d: Daemon, _ p: Paths) async throws -> (port: Int, pin: String) {
        let o = obj(try await admin(d, p, "admin.remote", ["action": "on", "port": 0]))
        return (int(o["listeningPort"]), str(o["fingerprint"]))
    }
    /// Hello deadline: short for the deadline test, long enough that an idle phone survives a loaded machine.
    private func config(_ c: inout DaemonConfig) { c.remoteAllowLoopback = true; c.remoteHelloDeadline = .seconds(2) }
    private let device: JSONValue = .object(["name": "iPhone de Teste", "model": "iPhone 16"])

    /// QR → pair → the app's click → token → hello, then the device sheet sees it.
    private func pair(_ d: Daemon, _ p: Paths, _ port: Int, _ pin: String, events: StreamClient? = nil) async throws -> (id: String, token: String) {
        let begin = obj(try await admin(d, p, "admin.remote.pair.begin"))
        let qr = try #require(URLComponents(string: str(begin["qr"])))
        let q = Dictionary(uniqueKeysWithValues: (qr.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(qr.scheme == "collie" && qr.host == "pair" && q["v"] == "1" && q["fp"] == pin && q["p"] == "\(port)" && q["s"]?.count == 43)
        #expect(q["id"].flatMap(UUID.init(uuidString:)) != nil && q["n"]?.isEmpty == false)
        let phone = try await RemotePhone.connect(port: port, pin: pin)
        defer { phone.close() }
        let offer = obj(try await phone.call("pair", ["secret": .string(q["s"]!), "device": device]))
        let code = str(offer["code"]), pairingId = str(offer["pairingId"])
        #expect(code.count == 6 && pairingId == str(begin["pairingId"]) && offer["via"] == .string("lan"), "\(offer)")
        if let events {   // the app's dialog
            var seen = false
            while !seen, case .event(let e)? = try await events.next(timeoutSeconds: 10) {
                if case .remotePairing(let r) = e { seen = true; #expect(r.code == code && r.name == "iPhone de Teste" && r.address == "127.0.0.1") }
            }
            #expect(seen)
        }
        let waiting = try await phone.send("pair.wait", ["pairingId": .string(pairingId)])
        #expect(try await admin(d, p, "admin.remote.pair.confirm", ["pairingId": .string(pairingId), "decision": "accept"]).ok)
        var got: [String: JSONValue] = [:]
        while let o = await phone.next() { if o["id"] == .string(waiting) { got = o; break } }
        guard case .object(let r)? = got["result"] else { Issue.record("pair.wait: \(got)"); return ("", "") }
        #expect(str(r["token"]).count == 43 && int(r["pairedAt"]) == -1 && str(r["pairedAt"]).hasSuffix("Z"))
        guard case .object(let mac)? = r["mac"] else { Issue.record("\(r)"); return ("", "") }
        #expect(mac["keyFingerprint"] == .string(pin))
        return (str(r["deviceId"]), str(r["token"]))
    }

    @Test func pairThenHello() async throws {
        try await withDaemon(configure: config) { d, p in
            let (port, pin) = try await on(d, p)
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let (id, token) = try await pair(d, p, port, pin, events: ev)
            let phone = try await RemotePhone.connect(port: port, pin: pin)
            defer { phone.close() }
            let hello = try await phone.call("session.hello", ["deviceId": .string(id), "token": .string(token),
                                                               "app": .object(["version": "1.0", "build": "1"])])
            let h = obj(hello)
            guard case .object(let dev)? = h["device"], case .object(let mac)? = h["mac"] else { Issue.record("\(hello)"); return }
            #expect(int(h["protocol"]) == 1 && dev["scope"] == .string("full") && dev["name"] == .string("iPhone de Teste") && h["rotate"] == nil)
            #expect(mac["installId"] != nil && mac["name"] != nil)
            // after hello: commands off the allowlist are refused, the socket stays (RemoteSurfaceTests has the rest)
            #expect(try await phone.call("admin.spawn").error?.code == .invalidArgs)
            #expect(try await phone.call("workspace.snapshot").ok)
            let list = try await admin(d, p, "admin.remote.devices")
            guard case .array(let ds)? = list.result, case .object(let row)? = ds.first else { Issue.record("\(list)"); return }
            #expect(ds.count == 1 && row["id"] == .string(id) && row["lastAddress"] == .string("127.0.0.1") && row["lastVia"] == .string("lan"))
            #expect(row["lastSeenAt"] != nil && row["live"] == .number(1) && row["tokenHash"] == nil)
        }
    }

    @Test func helloIsRequiredFirstAndOnTime() async throws {
        try await withDaemon(configure: config) { d, p in
            let (port, pin) = try await on(d, p)
            let a = try await RemotePhone.connect(port: port, pin: pin)
            defer { a.close() }
            #expect(await a.closingCode() == 4000)   // said nothing within the deadline
            let b = try await RemotePhone.connect(port: port, pin: pin)
            defer { b.close() }
            #expect(try await b.call("workspace.snapshot").error?.code == .unauthorized)
            #expect(await b.closingCode() == 4000)
            let c = try await RemotePhone.connect(port: port, pin: pin)
            defer { c.close() }
            let bad = try await c.call("session.hello", ["deviceId": .string(UUID().uuidString), "token": "nope"])
            #expect(bad.error?.code == .unauthorized)
            #expect(await c.closingCode() == 4000)
            let e = try await RemotePhone.connect(port: port, pin: pin)
            defer { e.close() }
            _ = try await e.send("session.hello", [:], v: 2)
            #expect(await e.next()?["error"].map { if case .object(let x) = $0 { x["code"] == .string("unsupportedVersion") } else { false } } == true)
        }
    }

    @Test func refusedTimedOutAndForeignWaits() async throws {
        try await withDaemon(configure: config) { d, p in
            let (port, pin) = try await on(d, p)
            let begin = obj(try await admin(d, p, "admin.remote.pair.begin"))
            let secret = try #require(URLComponents(string: str(begin["qr"]))?.queryItems?.first { $0.name == "s" }?.value)
            let phone = try await RemotePhone.connect(port: port, pin: pin)
            defer { phone.close() }
            let other = try await RemotePhone.connect(port: port, pin: pin)
            defer { other.close() }
            let pid = str(obj(try await phone.call("pair", ["secret": .string(secret), "device": device]))["pairingId"])
            #expect(try await other.call("pair.wait", ["pairingId": .string(pid)]).error?.code == .notFound)   // not its pairing
            #expect(try await phone.call("pair", ["secret": .string(secret), "device": device]).error?.code == .unauthorized)   // used
            let w = try await phone.send("pair.wait", ["pairingId": .string(pid)])
            #expect(try await admin(d, p, "admin.remote.pair.confirm", ["pairingId": .string(pid), "decision": "refuse"]).ok)
            var got: [String: JSONValue] = [:]
            while let o = await phone.next() { if o["id"] == .string(w) { got = o; break } }
            #expect(got["error"].map { if case .object(let x) = $0 { x["code"] == .string("conflict") } else { false } } == true, "\(got)")
            #expect((try await admin(d, p, "admin.remote.devices")).result == .array([]))
            #expect(try await admin(d, p, "admin.remote.pair.confirm", ["pairingId": .string(pid), "decision": "accept"]).error?.code == .notFound)
        }
    }

    @Test func revokeScopeAndRotation() async throws {
        try await withDaemon(configure: config) { d, p in
            let (port, pin) = try await on(d, p)
            let (id, token) = try await pair(d, p, port, pin)
            #expect(try await admin(d, p, "admin.remote.devices.scope", ["id": .string(id), "scope": "read"]).ok)
            let a = try await RemotePhone.connect(port: port, pin: pin)
            defer { a.close() }
            let h = obj(try await a.call("session.hello", ["deviceId": .string(id), "token": .string(token)]))
            #expect(h["device"].map { if case .object(let x) = $0 { x["scope"] == .string("read") } else { false } } == true)
            #expect(try await admin(d, p, "admin.remote.devices.revoke", ["id": .string(id)]).ok)
            #expect(await a.closingCode() == 4001)   // the live socket goes at once
            let b = try await RemotePhone.connect(port: port, pin: pin)
            defer { b.close() }
            #expect(try await b.call("session.hello", ["deviceId": .string(id), "token": .string(token)]).error?.code == .unauthorized)
            // a new identity: devices revoked, old pin no longer opens
            let (id2, token2) = try await pair(d, p, port, pin)
            let c = try await RemotePhone.connect(port: port, pin: pin)
            defer { c.close() }
            #expect(try await c.call("session.hello", ["deviceId": .string(id2), "token": .string(token2)]).ok)
            let rot = obj(try await admin(d, p, "admin.remote.identity.rotate"))
            let newPin = str(rot["fingerprint"]), newPort = int(rot["listeningPort"])
            #expect(newPin.count == 43 && newPin != pin && rot["listening"] == .bool(true))
            #expect(await c.closingCode() == 4003)
            #expect((try await admin(d, p, "admin.remote.devices")).result == .array([]))
            await #expect(throws: ProtocolError.self) { _ = try await RemotePhone.connect(port: newPort, pin: pin) }
            let n = try await RemotePhone.connect(port: newPort, pin: newPin)
            defer { n.close() }
            #expect(try await n.call("session.hello", ["deviceId": .string(id2), "token": .string(token2)]).error?.code == .unauthorized)
        }
    }

    @Test func offClosesSessionsAndAdminOnly() async throws {
        try await withDaemon(configure: config) { d, p in
            #expect(try await admin(d, p, "admin.remote.pair.begin").error?.code == .unavailable)   // listener off
            let (port, pin) = try await on(d, p)
            let (id, token) = try await pair(d, p, port, pin)
            let a = try await RemotePhone.connect(port: port, pin: pin)
            defer { a.close() }
            #expect(try await a.call("session.hello", ["deviceId": .string(id), "token": .string(token)]).ok)
            _ = try await admin(d, p, "admin.remote", ["action": "off"])
            #expect(await a.closingCode() == 4003)
            let (tid, _) = try await spawn(d, p, "T")
            let t = try await tokenOf(d, tid)
            for cmd in ["admin.remote.pair.begin", "admin.remote.devices", "admin.remote.identity.rotate"] {
                let r = try await send(p, Request(id: "t", terminalId: tid, token: t, command: cmd))
                #expect(r.error?.code == .unauthorized, "\(cmd)")
            }
        }
    }
}

@Suite struct RemoteTokenRotationTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }
    private let phone = RemotePairing.Device(name: "P", model: "M", address: "10.0.0.2", via: .lan)

    @Test func rotatesAfterNinetyDaysAndPromotesOnUse() throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-rtok-\(UUID().uuidString.prefix(8))/remote")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let clock = Clock()
        let s = RemoteDevices(dir: dir, now: { clock.now })
        let (d, t1) = try s.add(phone, fingerprint: "FP")
        let h1 = try #require(s.hello(id: d.id, token: t1, fingerprint: "FP", address: "10.0.0.9", via: .tailscale))
        #expect(h1.rotate == nil && h1.device.lastAddress == "10.0.0.9" && h1.device.lastVia == "tailscale" && h1.device.lastSeenAt == clock.now)
        clock.advance(91 * 86_400)
        let h2 = try #require(s.hello(id: d.id, token: t1, fingerprint: "FP", address: "10.0.0.9", via: .lan))
        let t2 = try #require(h2.rotate)
        #expect(t2 != t1)
        #expect(s.hello(id: d.id, token: t1, fingerprint: "FP", address: "x", via: .lan) != nil)   // the old one until the new is used
        let h3 = try #require(s.hello(id: d.id, token: t2, fingerprint: "FP", address: "x", via: .lan))
        #expect(h3.rotate == nil)
        #expect(s.hello(id: d.id, token: t1, fingerprint: "FP", address: "x", via: .lan) == nil)   // promoted: the old one is gone
        #expect(RemoteDevices(dir: dir, now: { clock.now }).hello(id: d.id, token: t2, fingerprint: "FP", address: "x", via: .lan) != nil)
    }
}
