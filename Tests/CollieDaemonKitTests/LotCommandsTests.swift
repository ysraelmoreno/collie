import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func lots(_ d: Daemon, _ p: Paths) async throws -> [Lot] {
    let r = try await admin(d, p, "ui.snapshot")
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result)).lots
}
private func members(_ r: Response) -> [String] {
    guard case .object(let o)? = r.result, case .array(let a)? = o["members"] else { return ["<none: \(r)>"] }
    return a.compactMap { if case .string(let s) = $0 { s } else { nil } }.sorted()
}
private func leash(_ d: Daemon, _ p: Paths, _ a: String, _ b: String) async throws {
    #expect(try await admin(d, p, "admin.leash", ["a": .string(a), "b": .string(b)]).ok)
}

@Suite(.serialized) struct LotCommandsTests {
    @Test func createAndJoin() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A"), _ = try await term(d, p, "B")
            let r = try await admin(d, p, "lot.create", ["name": .string("Login"), "goal": .string("tela de login"), "members": .string("A")])
            #expect(members(r) == ["A"], "\(r)")
            #expect(try await admin(d, p, "lot.join", ["terminal": .string("B"), "lot": .string("login")]).ok)
            let l = try #require(try await lots(d, p).first)
            #expect(l.name == "Login" && l.goal == "tela de login" && l.members.count == 2)
            #expect(members(try await call(p, a, "lot.get")) == ["A", "B"])   // default: the caller's lot
            #expect(try await admin(d, p, "lot.create", ["name": .string("LOGIN")]).error?.code == .invalidArgs)
            // a non-Shepherd may leave itself, never create or join
            #expect(try await call(p, a, "lot.create", ["name": "X"]).error?.code == .notShepherd)
            #expect(try await call(p, a, "lot.join", ["lot": "Login"]).error?.code == .notShepherd)
            #expect(try await call(p, a, "lot.leave").ok)
            #expect(try await call(p, a, "lot.get").error?.code == .notFound)
            // removing a terminal removes it from its lot; the lot stays; only an empty lot can be deleted
            #expect(try await admin(d, p, "lot.delete", ["lot": .string("Login")]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "admin.kill", ["target": .string("B")]).ok)
            #expect(try await lots(d, p).map(\.members) == [[]])
            #expect(try await call(p, a, "lot.delete", ["lot": "Login"]).error?.code == .unauthorized)
            #expect(try await admin(d, p, "lot.delete", ["lot": .string("Login")]).ok)
            #expect(try await lots(d, p).isEmpty)
        }
    }

    @Test func terminalInOneLotOnly() async throws {
        try await withDaemon { d, p in
            _ = try await term(d, p, "A")
            #expect(try await admin(d, p, "lot.create", ["name": .string("L1"), "members": .string("A")]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": .string("L2")]).ok)
            #expect(try await admin(d, p, "lot.join", ["terminal": .string("A"), "lot": .string("L2")]).ok)
            let ls = try await lots(d, p)
            #expect(ls.map(\.name) == ["L1", "L2"] && ls[0].members.isEmpty && ls[1].members.count == 1)
        }
    }

    @Test func shepherdJoinsReachedOnly() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            _ = try await term(d, p, "W"); _ = try await term(d, p, "S")
            try await leash(d, p, "M", "W")
            #expect(try await call(p, m, "lot.create", ["name": "L", "members": "S"]).error?.code == .notConnected)
            #expect(try await lots(d, p).isEmpty)   // nothing created on a refusal
            #expect(members(try await call(p, m, "lot.create", ["name": "L", "members": "M,W"])) == ["M", "W"])
            #expect(try await call(p, m, "lot.join", ["terminal": "S", "lot": "L"]).error?.code == .notConnected)
            #expect(try await call(p, m, "lot.leave", ["terminal": "S"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "lot.join", ["terminal": .string("S"), "lot": .string("L")]).ok)
            // listing never names a terminal the caller can't see: S is in M's lot, so M sees it; a stranger lot hides it
            #expect(try await admin(d, p, "lot.create", ["name": .string("Other"), "members": .string("S")]).ok)
            #expect(members(try await call(p, m, "lot.get", ["lot": "Other"])) == [])
            #expect(try await call(p, m, "lot.leave", ["terminal": "W"]).ok)
            #expect(members(try await call(p, m, "lot.get")) == ["M"])
        }
    }

    @Test func summonInheritsLot() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            #expect(try await call(p, m, "lot.create", ["name": "L", "members": "M"]).ok)
            let r = try await call(p, m, "summon", ["name": "W", "preset": "shell"])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["lot"] == .string("L"))
            #expect(members(try await call(p, m, "lot.get")) == ["M", "W"])
        }
    }

    /// A member of the Shepherd's lot that isn't leashed to it stays out of reach.
    @Test func lotGrantsNoReach() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true), x = try await term(d, p, "X")
            #expect(try await admin(d, p, "lot.create", ["name": .string("L"), "members": .string("M,X")]).ok)
            #expect(try await call(p, m, "ask", ["target": "X", "prompt": "oi", "timeout": "5"]).error?.code == .notConnected)
            #expect(try await call(p, x, "ask", ["target": "M", "prompt": "oi", "timeout": "5"]).error?.code == .notConnected)
            #expect(try await call(p, m, "check", ["target": "X"]).error?.code == .notConnected)
            #expect(try await call(p, m, "dismiss", ["target": "X"]).error?.code == .notConnected)
            guard case .array(let rows)? = try await call(p, m, "list").result else { Issue.record("list"); return }
            #expect(rows.isEmpty)
        }
    }
}
