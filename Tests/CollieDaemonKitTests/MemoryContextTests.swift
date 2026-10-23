import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var name: String; var token: String
    func env(_ p: Paths) -> [String: String] { ["COLLIE_SOCKET": p.socket.path, "COLLIE_TERMINAL_ID": id, "COLLIE_TOKEN": token] }
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }), to: p.socket, timeoutSeconds: 60)
}
private func work(_ d: Daemon, _ p: Paths, _ cmd: String, _ t: Term, _ args: [String: String] = [:]) async throws {
    let r = try await admin(d, p, cmd, args.merging(["terminal": t.name]) { a, _ in a })
    #expect(r.ok, "\(cmd): \(r)")
}
private func hook(_ p: Paths, _ t: Term, _ source: String?) async throws -> String {
    var a: [String: JSONValue] = [:]
    if let source { a["source"] = .string(source) }
    let r = try await UnixSocketClient.send(Request(id: "h", terminalId: t.id, token: t.token, command: "memory.hookContext", args: a), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let s)? = o["output"] else { return "<\(r)>" }
    return s
}

@Suite(.serialized) struct MemoryContextTests {
    /// Two lot members; A has an active work with tasks and notes; B handed A something and the lot has status posts.
    private func setup(_ d: Daemon, _ p: Paths, _ repo: URL) async throws -> (a: Term, b: Term) {
        let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
        #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A,B"]).ok)
        try await work(d, p, "work.start", a, ["title": "Tela de login"])
        try await work(d, p, "work.task.add", a, ["title": "Escrever o teste do botão"])
        for n in ["um", "dois", "tres", "quatro"] { try await work(d, p, "work.note", a, ["text": "nota \(n)"]) }
        #expect(try await call(p, b, "lot.post", ["kind": "handoff", "to": "A", "text": "Endpoint pronto em /api/login"]).ok)
        for i in 1...4 { #expect(try await call(p, b, "lot.post", ["kind": "status", "text": "status \(i)"]).ok) }
        return (a, b)
    }

    @Test func compactInjectsWorkStatus() async throws {   // Review Focus 4
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let (a, _) = try await setup(d, p, repo)
            let t = try await hook(p, a, "compact")
            #expect(t.contains("Escrever o teste do botão") && t.contains("nota quatro") && t.contains("nota dois") && !t.contains("nota um"), "\(t)")
            #expect(t.range(of: "Tela de login")!.lowerBound < t.range(of: "Quadro do lote")!.lowerBound)   // work status before the board
        }
    }

    @Test func compactInjectsLatestHandoff() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let (a, _) = try await setup(d, p, repo)
            let t = try await hook(p, a, "compact")
            #expect(t.contains("Endpoint pronto em /api/login") && t.contains("status 4") && t.contains("status 2") && !t.contains("status 1"), "\(t)")
            // delivered with the compact context: the next prompt does not repeat it
            let r = try await call(p, a, "memory.hookRelevant", ["prompt": "ok"])
            if case .object(let o)? = r.result, case .string(let s)? = o["output"] { #expect(!s.contains("Endpoint pronto")) }
        }
    }

    @Test func startupUnchanged() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let (a, _) = try await setup(d, p, repo)
            let plain = try await hook(p, a, nil)
            for s in ["startup", "clear", "bogus"] { #expect(try await hook(p, a, s) == plain) }
            #expect(!plain.contains("Escrever o teste do botão") && !plain.contains("Endpoint pronto"))
            #expect(try await hook(p, a, "resume").contains("Escrever o teste do botão"))
        }
    }

    @Test func compactFitsBudget() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let (a, b) = try await setup(d, p, repo)
            for i in 0..<60 {
                #expect(try await call(p, a, "memory.save", ["kind": "decision", "subject": "s\(i)", "title": String(repeating: "x", count: 150) + "\(i)", "body": "b",
                                                              "scope": "lot"]).ok)
            }
            try await work(d, p, "work.note", a, ["text": String(repeating: "n", count: 1900)])
            #expect(try await call(p, b, "lot.post", ["kind": "handoff", "to": "A", "text": String(repeating: "h", count: 3000)]).ok)
            let all = try await hook(p, a, "compact")
            let orientation = try await hook(p, a, "startup").utf8.count
            #expect(all.contains("Tela de login") && all.contains("Quadro do lote"))
            #expect(all.contains("[handoff]") && all.contains("hhhhhhhh"), "a long handoff comes back cut, not skipped")
            // orientation (≤ 1300) is outside the 4096 context budget (R4)
            #expect(all.utf8.count <= 4096 + 1300 + 4, "\(all.utf8.count) / \(orientation)")
        }
    }

    @Test func sessionSourceFromPayload() {
        func src(_ j: String) -> String? { HookPayload.claudeSessionSource(stdinJSON: Data(j.utf8)) }
        #expect(src(#"{"source":"compact"}"#) == "compact" && src(#"{"source":"resume"}"#) == "resume")
        #expect(src(#"{"source":"weird"}"#) == nil && src("{}") == nil && src("not json") == nil)
    }
}
