import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct DesignPreferTests {
    private struct Term { var id: String; var token: String }
    private func admin(_ d: Daemon, _ p: Paths, _ args: [String: String] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "design.prefer", args: args.mapValues { .string($0) }),
                                        to: p.socket, timeoutSeconds: 30)
    }
    private func term(_ d: Daemon, _ p: Paths, shepherd: Bool, paddock: String? = nil) async throws -> Term {
        var a: [String: JSONValue] = ["name": .string(paddock != nil ? "MP" : shepherd ? "M" : "W"), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]
        if let paddock { a["paddock"] = .string(paddock) }
        let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: a),
            to: p.socket, timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        return Term(id: id, token: try await tokenOf(d, id))
    }
    private func call(_ p: Paths, _ t: Term, _ args: [String: String] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: "design.prefer", args: args.mapValues { .string($0) }),
                                        to: p.socket, timeoutSeconds: 30)
    }
    private func value(_ r: Response) -> String? { if case .object(let o)? = r.result, case .string(let s)? = o["designFirst"] { s } else { nil } }

    @Test func preferSetsValue() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, shepherd: true)
            #expect(value(try await call(p, m)) == "ask")
            #expect(value(try await call(p, m, ["value": "always"])) == "always")
            #expect(value(try await call(p, m)) == "always")
            #expect(value(try await admin(d, p, ["value": "never"])) == "never")
        }
    }
    @Test func preferRefusedForNonShepherd() async throws {
        try await withDaemon { d, p in
            let w = try await term(d, p, shepherd: false)
            #expect(try await call(p, w, ["value": "never"]).error?.code == .notShepherd)
        }
    }
    @Test func preferReadsForAnyone() async throws {
        try await withDaemon { d, p in
            let w = try await term(d, p, shepherd: false)
            #expect(value(try await call(p, w)) == "ask")
        }
    }
    @Test func preferRejectsUnknown() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, shepherd: true)
            let e = try await call(p, m, ["value": "sometimes"]).error
            #expect(e?.code == .invalidArgs && e?.message.contains("ask|always|never") == true)
        }
    }

    @Test func preferSetOnlyFromPasture() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, shepherd: true)
            #expect(try await call(p, m, ["value": "never"]).ok)
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let c = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "paddock.create", args: ["name": "u1", "repo": .string(repo.path)]), to: p.socket, timeoutSeconds: 60)
            #expect(c.ok, "\(c)")
            let mp = try await term(d, p, shepherd: true, paddock: "u1")
            #expect(try await call(p, mp, ["value": "always"]).error?.code == .notShepherd)
            #expect(value(try await call(p, mp)) == "never")
        }
    }
}
