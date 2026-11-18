import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil,
                     command: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// `t` nil: the app (admin token).
private func work(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}

@Suite(.serialized) struct WorkLoopCommandTests {
    @Test func taskAddStoresSpecAndCheck() async throws {
        let repo = try await makeRepo()
        try "# Spec\n".write(to: repo.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("Build it"), "check": .string("true"), "spec": .string(repo.appendingPathComponent("spec.md").path)])
            #expect(r.ok, "\(r)")
            let t = try #require(try await d.router.work.active(terminal: a.uuid)?.tasks.first)
            #expect(t.check == "true" && t.spec == SignedAppCheck.realPath(repo.appendingPathComponent("spec.md")))
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["check"] == .string("true") && o["spec"] == .string(t.spec!))
        }
    }

    @Test func taskAddRefusesSpecOutsideProject() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("true"), "spec": .string("/etc/hosts")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    @Test func taskAddRefusesMissingSpec() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "spec": .string(repo.appendingPathComponent("nope.md").path)])
            #expect(r.error?.code == .invalidArgs, "\(r)")
        }
    }

    @Test func taskAddRefusesEmptyCheck() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("x"), "check": .string("  ")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }
}
