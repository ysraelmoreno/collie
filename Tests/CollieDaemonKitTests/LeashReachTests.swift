import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// DX backlog 5: a terminal of the paddock that isn't leashed to you is visible, and every refusal says what to do.
private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false, sandbox: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]
    if let sandbox { args["sandbox"] = .string(sandbox) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}

private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "c", terminalId: t.id, token: t.token, command: cmd, args: args))
}

private func rows(_ r: Response) -> [[String: JSONValue]] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
}

/// S (Shepherd) leashed to B; C in the same pasture, not leashed; F free.
private func rig(_ d: Daemon, _ p: Paths) async throws -> (s: Term, b: Term) {
    let s = try await term(d, p, "S", shepherd: true), b = try await term(d, p, "B")
    _ = try await term(d, p, "C"); _ = try await term(d, p, "F", sandbox: "free")
    #expect(try await send(p, Request(id: "l", token: d.adminToken, command: "admin.leash", args: ["a": "S", "b": "B"])).ok)
    return (s, b)
}

private func requests(_ d: Daemon, _ p: Paths) async throws -> [[String: JSONValue]] {
    rows(try await send(p, Request(id: "r", token: d.adminToken, command: "admin.leash.requests")))
}

private let quiet = "echo T=$COLLIE_TOKEN; exec cat >/dev/null"

/// Shepherd S (an agent preset: notices are typed into it) and C, not leashed.
private func requestRig(_ d: Daemon, _ p: Paths) async throws -> Term {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: [
        "name": "S", "preset": "claude", "command": .string(quiet), "cwd": "/tmp", "shepherd": true]))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    _ = try await term(d, p, "C")
    return Term(id: id, token: try await tokenOf(d, id, echo: false))
}

@Suite(.serialized) struct LeashReachTests {
    @Test func listAllShowsThePaddocksUnleashedTerminals() async throws {
        try await withDaemon { d, p in
            let (s, _) = try await rig(d, p)
            #expect(rows(try await call(p, s, "list")).map { $0["name"] } == [.string("B")])
            let all = rows(try await call(p, s, "list", ["all": .bool(true)]))
            try #require(all.map { $0["name"] } == [.string("B"), .string("C")], "free terminals stay out: \(all)")
            #expect(all[0]["reachable"] == .bool(true) && all[1]["reachable"] == .bool(false))
            guard case .string(let hint)? = all[1]["hint"] else { Issue.record("no hint: \(all)"); return }
            #expect(hint.contains("collie leash request C"), "\(hint)")
        }
    }

    @Test func refusalsSayWhatToDo() async throws {
        try await withDaemon { d, p in
            let (s, b) = try await rig(d, p)
            let ask = try await call(p, s, "ask", ["target": "C", "prompt": "hi"])
            #expect(ask.error?.code == .notConnected && ask.error?.message.contains("collie leash request C") == true, "\(ask)")
            let summon = try await call(p, s, "summon", ["name": "C"])
            #expect(summon.error?.message.contains("collie leash request C") == true, "\(summon)")
            let leashed = try await call(p, s, "summon", ["name": "B"])
            #expect(leashed.error?.message.contains("collie ask B") == true, "\(leashed)")
            let leash = try await call(p, s, "leash", ["a": "B", "b": "C"])
            #expect(leash.error?.message.contains("collie leash request C") == true, "\(leash)")
            // not a Shepherd: only the user leashes it, on the canvas
            let other = try await call(p, b, "ask", ["target": "C", "prompt": "hi"])
            #expect(other.error?.message.contains("canvas") == true && other.error?.message.contains("leash request") == false, "\(other)")
        }
    }

    @Test func leashRequestBecomesACardTheUserAnswers() async throws {
        try await withDaemon { d, p in
            let s = try await requestRig(d, p)
            let r = try await call(p, s, "leash.request", ["target": "C", "reason": "need its design"])
            guard case .object(let o)? = r.result, case .string(let id)? = o["requestId"] else { Issue.record("\(r)"); return }
            let again = try await call(p, s, "leash.request", ["target": "C"])
            #expect(again.result == r.result, "one card per pair")
            let cards = try await requests(d, p)
            #expect(cards.count == 1 && cards.first?["reason"] == .string("need its design") && cards.first?["id"] == .string(id), "\(cards)")
            let ok = try await send(p, Request(id: "a", token: d.adminToken, command: "admin.leash.answer", args: ["id": .string(id), "allow": true]))
            #expect(ok.ok, "\(ok)")
            #expect(try await requests(d, p).isEmpty)
            #expect(rows(try await call(p, s, "list")).map { $0["name"] } == [.string("C")])
            let sid = UUID(uuidString: s.id)!
            #expect(await waitFor(10) { await d.scrollbackText(sid).contains("[collie] The user leashed you to C") })
            let dup = try await call(p, s, "leash.request", ["target": "C"])
            #expect(dup.error?.message.contains("already leashed") == true, "\(dup)")
        }
    }

    @Test func declinedLeashRequestTellsTheShepherd() async throws {
        try await withDaemon { d, p in
            let s = try await requestRig(d, p)
            let r = try await call(p, s, "leash.request", ["target": "C"])
            guard case .object(let o)? = r.result, case .string(let id)? = o["requestId"] else { Issue.record("\(r)"); return }
            #expect(try await send(p, Request(id: "a", token: d.adminToken, command: "admin.leash.answer", args: ["id": .string(id), "allow": false])).ok)
            #expect(rows(try await call(p, s, "list")).isEmpty)
            let sid = UUID(uuidString: s.id)!
            #expect(await waitFor(10) { await d.scrollbackText(sid).contains("[collie] The user declined your leash to C") })
            // a removed end drops its card
            _ = try await call(p, s, "leash.request", ["target": "C"])
            #expect(try await requests(d, p).count == 1)
            #expect(try await send(p, Request(id: "x", token: d.adminToken, command: "admin.kill", args: ["target": "C"])).ok)
            #expect(try await requests(d, p).isEmpty)
        }
    }
}
