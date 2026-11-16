import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A terminal's map rule (rule-add, rule-enable) waits for the user's card (the apps' `confirm` card); the app's does not.
private struct Term { var id: String; var token: String }

private func shepherd(_ d: Daemon, _ p: Paths) async throws -> Term {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
        args: ["name": "M", "preset": "shell", "cwd": "/tmp", "shepherd": true]), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    let t = Term(id: id, token: try await tokenOf(d, id))
    #expect(try await call(p, t, "panel.open", ["plugin": "network"]).ok)
    return t
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "t", terminalId: t.id, token: t.token, command: cmd, args: args, cwd: "/tmp"), timeoutSeconds: 60)
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
}
private func cards(_ d: Daemon, _ p: Paths) async throws -> [AppCard] {
    let r = try await admin(d, p, "admin.app.cards")
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try dec.decode([AppCard].self, from: JSONEncoder().encode(r.result))
}
private func card(_ d: Daemon, _ p: Paths) async throws -> AppCard {
    #expect(await waitFor(10) { (try? await cards(d, p).first) != nil })
    return try #require(try await cards(d, p).first)
}
private func rules(_ d: Daemon, _ p: Paths) async throws -> [[String: JSONValue]] {
    guard case .array(let a)? = try await admin(d, p, "network.rule-list").result else { return [] }
    return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
}
private let add: [String: JSONValue] = ["method": "GET", "host": "api.example.com", "path": "/pdp", "status": 418, "body": "oi", "delay": 300]

@Suite(.serialized) struct NetworkRuleApprovalTests {
    @Test func agentRuleAddRaisesCardAndStaysDisabledUntilAllowed() async throws {
        try await withDaemon { d, p in
            let t = try await shepherd(d, p)
            let pending = Task { try await call(p, t, "network.rule-add", add) }
            let c = try await card(d, p)
            #expect(c.kind == .confirm && c.app == "network" && c.by?.uuidString == t.id)
            #expect(try await rules(d, p).map { $0["enabled"] } == [.bool(false)])   // off while the card waits
            #expect(try await admin(d, p, "admin.app.answer", ["id": .string(c.id.uuidString), "allow": .bool(true)]).ok)
            let r = try await pending.value
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["enabled"] == .bool(true))
            #expect(try await rules(d, p).map { $0["enabled"] } == [.bool(true)])
            // rule-enable by an agent asks too
            #expect(try await call(p, t, "network.rule-disable", ["id": o["id"]!]).ok)
            let again = Task { try await call(p, t, "network.rule-enable", ["id": o["id"]!]) }
            let c2 = try await card(d, p)
            #expect(try await admin(d, p, "admin.app.answer", ["id": .string(c2.id.uuidString), "allow": .bool(true)]).ok)
            #expect(try await again.value.ok)
            #expect(try await rules(d, p).map { $0["enabled"] } == [.bool(true)])
        }
    }

    @Test func denyKeepsRuleDisabled() async throws {
        try await withDaemon { d, p in
            let t = try await shepherd(d, p)
            let pending = Task { try await call(p, t, "network.rule-add", add) }
            let c = try await card(d, p)
            #expect(try await admin(d, p, "admin.app.answer", ["id": .string(c.id.uuidString), "allow": .bool(false)]).ok)
            #expect(try await pending.value.error?.code == .unauthorized)
            #expect(try await rules(d, p).map { $0["enabled"] } == [.bool(false)])
        }
    }

    @Test func timeoutIsDeny() async throws {
        try await withDaemon(configure: { $0.ruleCardWait = 1 }) { d, p in
            let t = try await shepherd(d, p)
            let r = try await call(p, t, "network.rule-add", add)
            #expect(r.error?.code == .unauthorized, "\(r)")
            #expect(try await rules(d, p).map { $0["enabled"] } == [.bool(false)])
            #expect(try await cards(d, p).isEmpty)
        }
    }

    @Test func adminRuleAddNeedsNoCard() async throws {
        try await withDaemon { d, p in
            let r = try await admin(d, p, "network.rule-add", add)
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            let none = try await cards(d, p)
            #expect(o["enabled"] == .bool(true) && none.isEmpty)
        }
    }

    @Test func agentRemoveAndDisableNeedNoCard() async throws {
        try await withDaemon { d, p in
            let t = try await shepherd(d, p)
            var ids: [JSONValue] = []
            for _ in 0..<2 {
                guard case .object(let o)? = try await admin(d, p, "network.rule-add", add).result else { return }
                ids.append(o["id"]!)
            }
            #expect(try await call(p, t, "network.rule-disable", ["id": ids[0]]).ok)
            #expect(try await call(p, t, "network.rule-remove", ["id": ids[1]]).ok)
            #expect(try await call(p, t, "network.rule-list").ok)
            // created off by the agent itself: nothing turns on, nothing to ask
            #expect(try await call(p, t, "network.rule-add", ["path": "/x", "disabled": true]).ok)
            #expect(try await call(p, t, "network.rule-clear").ok)
            #expect(try await cards(d, p).isEmpty)
            #expect(try await rules(d, p).isEmpty)
        }
    }

    @Test func cardTextNamesMethodHostPathStatusSizeDelay() async throws {
        try await withDaemon { d, p in
            let t = try await shepherd(d, p)
            var big = add; big["body"] = .string(String(repeating: "x", count: 2048))
            let pending = Task { try await call(p, t, "network.rule-add", big) }
            let c = try await card(d, p)
            #expect(c.call == "responder GET api.example.com/pdp com 418 (corpo 2 KB, atraso 300 ms)", "\(c.call ?? "")")
            _ = try await admin(d, p, "admin.app.answer", ["id": .string(c.id.uuidString)])
            _ = try await pending.value
            let drop = Task { try await call(p, t, "network.rule-add", ["drop": true]) }
            let c2 = try await card(d, p)
            #expect(c2.call == "cortar a conexão de qualquer requisição", "\(c2.call ?? "")")
            _ = try await admin(d, p, "admin.app.answer", ["id": .string(c2.id.uuidString)])
            _ = try await drop.value
        }
    }
}
