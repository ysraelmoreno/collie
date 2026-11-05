import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 2 (spec §2): the device store and the pairing state machine. No network, no sleep: a test clock.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

private func tempDir() -> URL { URL(fileURLWithPath: "/tmp/collie-rdev-\(UUID().uuidString.prefix(8))/remote") }
private func perms(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int) ?? -1 }
private let phone = RemotePairing.Device(name: "iPhone de Teste", model: "iPhone 16", address: "192.168.1.23", via: .lan)

@Suite struct RemoteDevicesTests {
    @Test func storesOnlyTheTokenHash() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let clock = TestClock()
        let s = RemoteDevices(dir: dir, now: { clock.now })
        let (d, token) = try s.add(phone, fingerprint: "FP1")
        #expect(token.count == 43 && d.scope == .full && d.name == "iPhone de Teste" && d.pairedAt == clock.now)
        let file = dir.appendingPathComponent("devices.json")
        #expect(perms(file) == 0o600 && perms(dir) == 0o700)
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains(token))
        #expect(s.verify(id: d.id, token: token, fingerprint: "FP1")?.id == d.id)
        #expect(s.verify(id: d.id, token: token + "x", fingerprint: "FP1") == nil)
        #expect(s.verify(id: d.id, token: String(token.dropLast()) + (token.last == "A" ? "B" : "A"), fingerprint: "FP1") == nil)
        #expect(s.verify(id: UUID(), token: token, fingerprint: "FP1") == nil)
        // reloaded from disk
        #expect(RemoteDevices(dir: dir, now: { clock.now }).verify(id: d.id, token: token, fingerprint: "FP1") != nil)
    }

    @Test func revokeAndScope() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = RemoteDevices(dir: dir)
        let (a, ta) = try s.add(phone, fingerprint: "FP1"), (b, tb) = try s.add(phone, fingerprint: "FP1")
        #expect(try s.setScope(b.id, .read))
        #expect(s.verify(id: b.id, token: tb, fingerprint: "FP1")?.scope == .read)
        #expect(try s.revoke(a.id))
        #expect(try !s.revoke(a.id))
        #expect(s.verify(id: a.id, token: ta, fingerprint: "FP1") == nil)
        let again = RemoteDevices(dir: dir)
        #expect(again.all.map(\.id) == [b.id] && again.all.first?.scope == .read)
        #expect(try !again.setScope(a.id, .full))
    }

    @Test func anotherIdentityInvalidatesEveryDevice() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = RemoteDevices(dir: dir)
        let (a, ta) = try s.add(phone, fingerprint: "FP1")
        _ = try s.add(phone, fingerprint: "FP1")
        #expect(s.verify(id: a.id, token: ta, fingerprint: "FP2") == nil)   // the Mac's identity changed: pins broke
        #expect(s.all.isEmpty && RemoteDevices(dir: dir).all.isEmpty)
        _ = try s.add(phone, fingerprint: "FP2")
        try s.revokeAll()
        #expect(s.all.isEmpty)
    }

    @Test func rotatingTheIdentityRevokesDevices() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let id = try RemoteIdentity.loadOrCreate(dir: dir)
        let s = RemoteDevices(dir: dir)
        let (d, t) = try s.add(phone, fingerprint: id.fingerprint)
        let new = try RemoteIdentity.rotate(dir: dir, devices: s)
        #expect(new.fingerprint != id.fingerprint && s.all.isEmpty)
        #expect(s.verify(id: d.id, token: t, fingerprint: id.fingerprint) == nil)
    }
}

@Suite struct RemotePairingTests {
    private func pairing(_ c: TestClock) -> RemotePairing { RemotePairing(now: { c.now }) }

    @Test func happyPath() throws {
        let c = TestClock(), p = pairing(c)
        let offer = p.begin()
        #expect(offer.secret.count == 43 && offer.expiresAt == c.now + 300)
        c.advance(299)
        let claim = try p.claim(secret: offer.secret, device: phone)
        #expect(claim.pairingId == offer.pairingId && claim.code.count == 6 && claim.code.allSatisfy(\.isNumber))
        #expect(p.awaiting?.code == claim.code && p.awaiting?.device == phone)
        #expect(p.outcome(offer.pairingId) == .pending)
        let used = try #require(throwing(try p.claim(secret: offer.secret, device: phone)))   // single use
        #expect(used.code == .unauthorized)
        #expect(try p.decide(offer.pairingId, accept: true) == phone)
        #expect(p.outcome(offer.pairingId) == .accepted(phone) && p.awaiting == nil)
        #expect(throwing(try p.decide(offer.pairingId, accept: true))?.code == .notFound)   // once
    }

    @Test func sameRefusalForWrongExpiredOrUsed() throws {
        let c = TestClock(), p = pairing(c)
        let none = try #require(throwing(try p.claim(secret: "x", device: phone)))   // nothing begun
        let o = p.begin()
        let wrong = try #require(throwing(try p.claim(secret: "nope", device: phone)))
        c.advance(301)
        let expired = try #require(throwing(try p.claim(secret: o.secret, device: phone)))
        #expect([none, wrong, expired].allSatisfy { $0.code == .unauthorized && $0.message == wrong.message })
    }

    @Test func fiveFailuresKillTheSecret() throws {
        let c = TestClock(), p = pairing(c)
        let o = p.begin()
        for _ in 0..<4 { #expect(throwing(try p.claim(secret: "bad", device: phone))?.code == .unauthorized) }
        #expect(throwing(try p.claim(secret: "bad", device: phone))?.code == .tooMany)
        #expect(throwing(try p.claim(secret: o.secret, device: phone))?.code == .unauthorized)   // dead now
    }

    @Test func oneLivePairingAtATime() throws {
        let c = TestClock(), p = pairing(c)
        let a = p.begin(), b = p.begin()
        #expect(a.pairingId != b.pairingId && a.secret != b.secret)
        #expect(throwing(try p.claim(secret: a.secret, device: phone))?.code == .unauthorized)
        _ = try p.claim(secret: b.secret, device: phone)
        let c2 = p.begin()   // a new one also drops a pairing waiting for its click
        #expect(p.outcome(b.pairingId) == .refused && p.awaiting == nil)
        _ = c2
    }

    @Test func refusedOnTheMac() throws {
        let c = TestClock(), p = pairing(c)
        let o = p.begin()
        _ = try p.claim(secret: o.secret, device: phone)
        #expect(try p.decide(o.pairingId, accept: false) == nil)
        #expect(p.outcome(o.pairingId) == .refused)
    }

    @Test func confirmationTimesOut() throws {
        let c = TestClock(), p = pairing(c)
        let o = p.begin()
        _ = try p.claim(secret: o.secret, device: phone)
        c.advance(60)
        #expect(p.outcome(o.pairingId) == .pending)
        c.advance(1)
        #expect(p.outcome(o.pairingId) == .timedOut && p.awaiting == nil)
        #expect(throwing(try p.decide(o.pairingId, accept: true))?.code == .timeout)
        #expect(throwing(try p.decide(UUID(), accept: true))?.code == .notFound)
    }

    @Test func deviceNamesAreBounded() throws {
        let c = TestClock(), p = pairing(c)
        let o = p.begin()
        let long = RemotePairing.Device(name: String(repeating: "n", count: 80), model: " " + String(repeating: "m", count: 50), address: "10.0.0.2", via: .lan)
        _ = try p.claim(secret: o.secret, device: long)
        #expect(p.awaiting?.device.name.count == 60 && p.awaiting?.device.model.count == 40)
        let o2 = p.begin()
        let blank = RemotePairing.Device(name: "  \n", model: "", address: "10.0.0.2", via: .lan)
        #expect(throwing(try p.claim(secret: o2.secret, device: blank))?.code == .invalidArgs)
    }
}

/// The error a throwing call raised (nil: it didn't throw).
private func throwing<T>(_ f: @autoclosure () throws -> T) -> ProtocolError? {
    do { _ = try f(); return nil } catch let e as ProtocolError { return e } catch { return ProtocolError(code: .internal, message: "\(error)") }
}
