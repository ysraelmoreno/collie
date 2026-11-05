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
}
