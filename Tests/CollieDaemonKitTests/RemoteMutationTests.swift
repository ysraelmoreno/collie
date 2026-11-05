import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 7 (spec §3.7, §4.2, §4.3): answers, access cards, audit and limits from a paired phone.
private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
private func arr(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { a } else { [] } }

private func until(_ seconds: Double = 10, _ ok: () async throws -> Bool) async rethrows -> Bool {
    let end = Date() + seconds
    while Date() < end { if try await ok() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
    return false
}

/// The audit lines (spec §4.3).
private func audit(_ p: Paths) -> [[String: JSONValue]] {
    let f = p.root.appendingPathComponent("remote/audit.jsonl")
    guard let s = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").compactMap { obj(try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))) }
}

@Suite(.serialized) struct RemoteMutationTests {
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
    }

    @Test func answerAnApprovalFromThePhone() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, dev) = try await helloPhone(d, p)
            defer { ph.close() }
            let (tid, _) = try await spawn(d, p, "Asker", preset: "custom", command: "printf 'Go? (y/n) '; read x; echo GOT=$x; exec cat")
            var ap: [String: JSONValue] = [:]
            #expect(try await until { ap = obj(arr(try await ph.call("approvals.list").result).first); return !ap.isEmpty })
            let r = obj(try await ph.call("approval.answer", ["id": ap["id"] ?? .null, "allow": true]).result)
            #expect(r["sent"] == .bool(true), "\(r)")
            #expect(try await until { await d.scrollbackText(UUID(uuidString: tid)!).contains("GOT=y") })
            // the chat says who answered, from where
            #expect(try await until {
                arr(try await ph.call("chat.history").result).contains { str(obj($0)["text"]) == "Aprovado do P (rede local)" }
            })
            // single use: a second answer is stale, with a stable code
            let again = obj(try await ph.call("approval.answer", ["id": ap["id"] ?? .null, "allow": true]).result)
            #expect(again["sent"] == .bool(false) && again["code"] == "stale" && again["reason"] != nil, "\(again)")
            #expect(obj(try await ph.call("approval.dismiss", ["id": .string(UUID().uuidString)]).result)["dismissed"] == .bool(false))
            #expect(try await ph.call("approval.answer", ["id": "x", "allow": true]).error?.code == .invalidArgs)

            let lines = audit(p).filter { $0["command"] == "approval.answer" }
            #expect(lines.count == 3, "\(audit(p))")
            let first = lines.first ?? [:]
            #expect(first["device"] == .string(dev) && first["deviceName"] == "P" && first["via"] == "lan" && first["address"] == "127.0.0.1"
                    && first["target"] == ap["id"] && first["result"] == "ok" && first["at"] != nil, "\(first)")
            #expect(lines.last?["result"] == "invalidArgs")
            #expect(audit(p).contains { $0["command"] == "pair" } && audit(p).contains { $0["command"] == "session.hello" })
            let raw = (try? String(contentsOf: p.root.appendingPathComponent("remote/audit.jsonl"), encoding: .utf8)) ?? ""
            #expect(!raw.contains("token"), "never the token")
            let mode = (try? FileManager.default.attributesOfItem(atPath: p.root.appendingPathComponent("remote/audit.jsonl").path)[.posixPermissions]) as? Int
            #expect(mode == 0o600)
        }
    }

    @Test func grantAndDenyAccessCards() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, dev) = try await helloPhone(d, p)
            defer { ph.close() }
            let (wid, _) = try await spawn(d, p, "Worker", preset: "custom", command: "sleep 60")
            let tid = try #require(UUID(uuidString: wid))
            let dir = "/private/tmp/collie-grant-\(UUID().uuidString.prefix(6))"
            try FileManager.default.createDirectory(atPath: dir + "/a", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: dir + "/b", withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            await d.router.raiseForTests(SandboxDenial(terminal: tid, op: "write", path: dir + "/a/f.txt", requested: true))
            await d.router.raiseForTests(SandboxDenial(terminal: tid, op: "write", path: dir + "/b/g.txt", requested: true))
            let cards = arr(obj(try await ph.call("access.cards").result)["cards"]).map(obj)
            let a = try #require(cards.first { str($0["path"]).hasSuffix("/a/f.txt") }), b = try #require(cards.first { str($0["path"]).hasSuffix("/b/g.txt") })

            #expect(try await ph.call("access.grant", ["card": a["id"] ?? .null, "lot": true]).error?.code == .invalidArgs, "lot scope: D3")
            #expect(try await ph.call("access.grant", ["card": "nope"]).error?.code == .notFound)
            #expect(try await ph.call("access.deny", ["card": b["id"] ?? .null]).ok)
            // the grant restarts the terminal (its other cards go with the old launch)
            let g = try await ph.call("access.grant", ["card": a["id"] ?? .null])
            let grant = obj(obj(g.result)["grant"])
            #expect(g.ok && grant["path"] == .string(dir + "/a/f.txt") && grant["scope"] == "terminal" && grant["access"] == "write", "\(g)")
            #expect(obj(grant["by"]) == ["device": .string(dev), "deviceName": "P", "via": "lan"], "\(grant)")
            #expect(obj(g.result)["restarted"] == .bool(true))
            let left = arr(obj(try await ph.call("access.cards").result)["cards"]).map(obj)
            #expect(!left.contains { $0["id"] == a["id"] || $0["id"] == b["id"] }, "\(left)")
            #expect(try await ph.call("access.deny", ["card": b["id"] ?? .null]).error?.code == .notFound)
            let lines = audit(p).filter { str($0["command"]).hasPrefix("access.") }
            #expect(lines.map { str($0["result"]) } == ["invalidArgs", "notFound", "ok", "ok", "notFound"], "\(lines)")
            #expect(lines.dropFirst(3).first?["target"] == .string(dir + "/a/f.txt"), "the path, not the card id")
        }
    }

    @Test func requestAndMutationLimits() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            // 30 mutating per minute: the 31st is refused, with when to retry
            var ids: [String] = []
            for _ in 0..<31 { ids.append(try await ph.send("approval.dismiss", ["id": .string(UUID().uuidString)])) }
            var replies: [String: [String: JSONValue]] = [:]
            while replies.count < ids.count, let o = await ph.next(timeout: 10) { if case .string(let id)? = o["id"] { replies[id] = o } }
            let refused = ids.compactMap { replies[$0] }.filter { obj($0["error"])["code"] == "tooMany" }
            #expect(refused.count == 1, "\(refused)")
            if case .number(let s)? = obj(refused.first?["error"])["retryAfter"] { #expect(s > 0 && s <= 60) } else { Issue.record("no retryAfter") }
            // 30 requests/s, burst 60 (refilled after 2 s): 100 at once → some refused, reads work again a second later
            try await Task.sleep(for: .seconds(2))
            ids = []
            for _ in 0..<100 { ids.append(try await ph.send("approvals.list")) }
            replies = [:]
            while replies.count < ids.count, let o = await ph.next(timeout: 10) { if case .string(let id)? = o["id"] { replies[id] = o } }
            let tooMany = replies.values.filter { obj($0["error"])["code"] == "tooMany" }.count
            #expect(tooMany >= 10 && tooMany <= 50, "\(tooMany) refused")
            try await Task.sleep(for: .seconds(1))
            #expect(try await ph.call("approvals.list").ok)
        }
    }

    @Test func failedHellosBlockTheAddress() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            ph.close()
            guard case .object(let on)? = try await admin(d, p, "admin.remote").result, case .number(let port)? = on["listeningPort"],
                  case .string(let pin)? = on["fingerprint"] else { Issue.record("status"); return }
            for _ in 0..<10 {
                let bad = try await RemotePhone.connect(port: Int(port), pin: pin)
                #expect(try await bad.call("session.hello", ["deviceId": .string(UUID().uuidString), "token": "x"]).error?.code == .unauthorized)
                bad.close()
            }
            // the 11th connection from the same address within the minute: refused before TLS
            await #expect(throws: (any Error).self) { try await RemotePhone.connect(port: Int(port), pin: pin) }
            #expect(audit(p).filter { $0["command"] == "session.hello" && $0["result"] == "unauthorized" }.count == 10)
        }
    }
}
