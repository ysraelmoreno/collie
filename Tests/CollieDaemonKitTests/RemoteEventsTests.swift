import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 5 (spec §3.4, "Wire details"): events.subscribe pushes projected events to a paired phone.
private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }

private struct Phone {
    let ph: RemotePhone, id: String
    /// The next pushed event whose `e.t` is `t` (and passes `match`), skipping others; nil after `timeout`.
    func event(_ t: String, timeout: Double = 10, _ match: ([String: JSONValue]) -> Bool = { _ in true }) async -> [String: JSONValue]? {
        let deadline = Date() + timeout
        while Date() < deadline, let o = await ph.next(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
            guard o["t"] == .string("event"), o["sub"] == .string("ev") else { continue }
            let e = obj(o["e"])
            if e["t"] == .string(t), match(e) { return e }
        }
        return nil
    }
}

@Suite(.serialized) struct RemoteEventsTests {
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
    }

    /// Listener on, a device paired, a session with hello done and events subscribed.
    private func subscribed(_ d: Daemon, _ p: Paths) async throws -> Phone {
        guard case .object(let on)? = try await admin(d, p, "admin.remote", ["action": "on", "port": 0]).result,
              case .number(let port)? = on["listeningPort"], case .string(let pin)? = on["fingerprint"] else { throw ProtocolError(code: .internal, message: "on") }
        guard case .object(let b)? = try await admin(d, p, "admin.remote.pair.begin").result, case .string(let qr)? = b["qr"],
              let secret = URLComponents(string: qr)?.queryItems?.first(where: { $0.name == "s" })?.value else { throw ProtocolError(code: .internal, message: "begin") }
        let ph = try await RemotePhone.connect(port: Int(port), pin: pin)
        let pid = obj(try await ph.call("pair", ["secret": .string(secret), "device": .object(["name": "P", "model": "M"])]).result)["pairingId"]!
        let w = try await ph.send("pair.wait", ["pairingId": pid])
        _ = try await admin(d, p, "admin.remote.pair.confirm", ["pairingId": pid, "decision": "accept"])
        var res: [String: JSONValue] = [:]
        while let o = await ph.next() { if o["id"] == .string(w) { res = obj(o["result"]); break } }
        guard try await ph.call("session.hello", ["deviceId": res["deviceId"]!, "token": res["token"]!]).ok else { throw ProtocolError(code: .internal, message: "hello") }
        let sub = try await ph.call("events.subscribe")
        #expect(obj(sub.result)["sub"] == "ev", "\(sub)")
        return Phone(ph: ph, id: str(res["deviceId"]))
    }

    @Test func terminalsLeashesStatusAndRemoval() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let phone = try await subscribed(d, p)
            defer { phone.ph.close() }
            let (sid, _) = try await spawn(d, p, "Boss")
            let t = await phone.event("terminal") { obj($0["terminal"])["name"] == "Boss" }
            let term = obj(t?["terminal"])
            #expect(term["id"] == .string(sid.lowercased()) && term["cwd"] == nil && term["command"] == nil, "\(String(describing: t))")
            #expect(await phone.event("status") { $0["terminalId"] == .string(sid.lowercased()) && $0["since"] != nil } != nil)
            let (wid, _) = try await spawn(d, p, "Worker")
            #expect(try await admin(d, p, "admin.leash", ["a": "Boss", "b": "Worker"]).ok)
            #expect(await phone.event("leash") { $0["on"] == .bool(true) && Set([str($0["a"]), str($0["b"])]) == [sid.lowercased(), wid.lowercased()] } != nil)
            #expect(try await admin(d, p, "admin.unleash", ["a": "Boss", "b": "Worker"]).ok)
            #expect(await phone.event("leash") { $0["on"] == .bool(false) } != nil)
            #expect(try await admin(d, p, "admin.kill", ["target": "Worker"]).ok)   // kill removes the terminal
            #expect(await phone.event("terminalRemoved") { $0["id"] == .string(wid.lowercased()) } != nil)
            let (xid, _) = try await spawn(d, p, "Short", preset: "custom", command: "sleep 0.3")   // exited: stopped
            #expect(await phone.event("status") { $0["terminalId"] == .string(xid.lowercased()) && $0["badge"] == "stopped" } != nil)
        }
    }

    @Test func cardsApprovalsChatAndWork() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let phone = try await subscribed(d, p)
            defer { phone.ph.close() }
            let (wid, _) = try await spawn(d, p, "Worker")
            let tid = try #require(UUID(uuidString: wid))
            let home = NSHomeDirectory()
            await d.router.raiseForTests(SandboxDenial(terminal: tid, op: "write", path: home + "/.claude/settings.json", requested: true))
            let card = obj(await phone.event("accessCard")?["card"])
            #expect(card["isAgentConfig"] == .bool(true) && str(card["id"]).count == 22, "\(card)")
            #expect(try await admin(d, p, "access.deny", ["terminal": .string(wid), "op": "write", "path": .string(home + "/.claude/settings.json")]).ok)
            #expect(await phone.event("accessCardRemoved") { $0["id"] == card["id"] } != nil)

            // a real prompt (the tracker raises it), cleared once answered
            let (aid, _) = try await spawn(d, p, "Asker", preset: "custom", command: "printf 'Go? (y/n) '; read x; exec cat")
            let ap = obj(await phone.event("approval") { $0["approval"] != nil }?["approval"])
            #expect(ap["terminalId"] == .string(aid.lowercased()) && ap["kind"] == "yesNo" && ap["terminal"] == "Asker" && str(ap["id"]).count == 36, "\(ap)")
            #expect(try await admin(d, p, "work.approve", ["id": ap["id"] ?? .null, "allow": true]).ok)
            #expect(await phone.event("approval") { $0["cleared"] == .bool(true) && $0["terminalId"] == .string(aid.lowercased()) } != nil)

            #expect(try await admin(d, p, "work.start", ["terminal": "Worker", "title": "T"]).ok)
            #expect(await phone.event("work") { $0["id"] != nil } != nil)
            #expect(try await admin(d, p, "work.chat.send", ["text": "o que está rodando?"]).ok)
            let chat = obj(await phone.event("chat")?["message"])
            #expect(chat["role"] != nil && chat["text"] != nil && chat["at"] != nil, "\(chat)")
        }
    }

    @Test func unsubscribeAndRevokeStopEvents() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let phone = try await subscribed(d, p)
            defer { phone.ph.close() }
            #expect(try await phone.ph.call("events.unsubscribe").ok)
            _ = try await spawn(d, p, "Quiet")
            #expect(await phone.event("terminal", timeout: 1.5) == nil)
            #expect(try await phone.ph.call("events.subscribe").ok)
            // revoked from the store alone: the next event closes the session (4001), nothing more is pushed
            #expect(try d.router.remoteDevices.revoke(UUID(uuidString: phone.id)!))
            _ = try await spawn(d, p, "Loud")
            #expect(await phone.ph.closingCode() == 4001)
        }
    }

    @Test func overflowCutsTheSubscription() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true; $0.remoteEventQueueBytes = 1 }) { d, p in
            let phone = try await subscribed(d, p)
            defer { phone.ph.close() }
            _ = try await spawn(d, p, "A")
            var overflow = false
            while let o = await phone.ph.next(timeout: 5) { if o["t"] == .string("overflow") { overflow = o["sub"] == .string("ev"); break } }
            #expect(overflow)
            #expect(try await phone.ph.call("workspace.snapshot").ok)   // the session stays; the phone re-snapshots and re-subscribes
            #expect(try await phone.ph.call("events.subscribe").ok)
        }
    }
}
