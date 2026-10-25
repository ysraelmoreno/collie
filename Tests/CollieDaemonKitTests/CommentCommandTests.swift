import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
}
private func s(_ v: JSONValue?) -> String? { if case .string(let x)? = v { return x }; return nil }
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { return o }; return [:] }
private func rows(_ r: Response) -> [[String: JSONValue]] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0 { return o }; return nil }
}
private func messages(_ o: [String: JSONValue]) -> [String] {
    guard case .array(let a)? = o["messages"] else { return [] }
    return a.compactMap { if case .object(let m) = $0 { return s(m["body"]) }; return nil }
}
/// A project with one page.
private func project() async throws -> URL {
    let repo = try await makeRepo()
    try Data("<h1>Oi</h1>".utf8).write(to: repo.appendingPathComponent("index.html"))
    return repo
}
private func add(_ d: Daemon, _ p: Paths, _ repo: URL, panel: String? = "Prévia", body: String = "deixe maior",
                 title: String = "Início", path: String = "index.html") async throws -> Response {
    var a: [String: JSONValue] = ["root": .string(repo.path), "path": .string(path), "title": .string(title), "body": .string(body),
                                  "x": .number(0.5), "y": .number(0.2), "selector": .string("h1"), "text": .string("Oi")]
    if let panel { a["panel"] = .string(panel) }
    return try await admin(d, p, "comment.add", a)
}

extension CommandRouter {
    /// A Prévia panel without the app (plan 2U's plug-in), made by `createdBy` and leashed to `leashed`.
    func addPreviewPanel(_ name: String = "Prévia", createdBy: UUID? = nil, leashed: [UUID] = []) -> UUID {
        let p = Panel(id: UUID(), name: name, pluginId: "preview", placement: .canvas, createdBy: createdBy)
        ws.panels.append(p)
        ws.connections += leashed.map { Connection(a: $0, b: p.id) }
        return p.id
    }
}

@Suite(.serialized) struct CommentCommandTests {
    @Test func addAsAppAddressesPanelCreator() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: a.uuid, leashed: [b.uuid])
            let r = try await add(d, p, repo)
            #expect(r.ok, "\(r)")
            let o = obj(r)
            #expect(s(o["to"]) == a.id.lowercased() && s(o["toName"]) == "A" && o["undeliverable"] == .bool(false))
            #expect(messages(o) == ["deixe maior"] && s(o["short"])?.count == 8 && s(o["title"]) == "Início")
            guard case .object(let page)? = o["page"] else { Issue.record("no page"); return }
            #expect(s(page["path"]) == "index.html" && s(page["root"]) == DiagramFile.real(repo).path && s(page["key"])?.hasPrefix("page-") == true)
            // the file is in Collie data, never in the project
            let files = try FileManager.default.contentsOfDirectory(atPath: p.root.appendingPathComponent("comments").path)
            #expect(files == ["\(s(page["key"])!).json"])
            // a page outside the root, not html, or an unknown artifact
            #expect(try await add(d, p, repo, path: "../x.html").error?.code == .invalidArgs)
            #expect(try await add(d, p, repo, path: "f.txt").error?.code == .invalidArgs)
            #expect(try await admin(d, p, "comment.add", ["artifact": .string(UUID().uuidString), "title": .string("T"), "body": .string("b"),
                                                          "x": .number(0), "y": .number(0)]).error?.code == .notFound)
        }
    }

    @Test func addFallsBackToSingleLeash() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let b = try await term(d, p, "B", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: UUID(), leashed: [b.uuid])   // its creator is gone
            #expect(s(obj(try await add(d, p, repo))["to"]) == b.id.lowercased())
        }
    }

    @Test func addWithTwoLeashesHasNoAddressee() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            _ = await d.router.addPreviewPanel(leashed: [a.uuid, b.uuid])
            let o = obj(try await add(d, p, repo))
            #expect(o["to"] == .null && o["undeliverable"] == .bool(false))
            #expect(obj(try await add(d, p, repo, panel: nil))["to"] == .null)
        }
    }

    @Test func terminalCannotAdd() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: a.uuid)
            let r = try await call(p, a, "comment.add", ["root": .string(repo.path), "path": .string("index.html"), "title": .string("T"),
                                                        "body": .string("eu sou o usuário"), "x": .number(0), "y": .number(0), "panel": .string("Prévia")])
            #expect(r.error?.code == .unauthorized, "\(r)")
            #expect(rows(try await admin(d, p, "comment.list")).isEmpty)
        }
    }

    @Test func terminalCannotResolve() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: a.uuid)
            let id = try #require(s(obj(try await add(d, p, repo))["id"]))
            for cmd in ["comment.resolve", "comment.unresolve"] {
                #expect(try await call(p, a, cmd, ["id": .string(id)]).error?.code == .unauthorized)
            }
            #expect(try await call(p, a, "comment.message", ["id": .string(id), "body": .string("forjado")]).error?.code == .unauthorized)
            let o = rows(try await admin(d, p, "comment.list"))
            #expect(o.count == 1 && o[0]["resolved"] == .bool(false) && messages(o[0]) == ["deixe maior"])
            // the app resolves and reopens
            #expect(obj(try await admin(d, p, "comment.resolve", ["id": .string(id)]))["resolved"] == .bool(true))
            #expect(rows(try await admin(d, p, "comment.list", ["open": .bool(true)])).isEmpty)
            #expect(obj(try await admin(d, p, "comment.unresolve", ["id": .string(id)]))["resolved"] == .bool(false))
        }
    }

    @Test func replyFromAddressee() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let panel = await d.router.addPreviewPanel(createdBy: a.uuid)
            let c = obj(try await add(d, p, repo))
            let short = try #require(s(c["short"]))
            let r = try await call(p, a, "comment.reply", ["id": .string(short), "text": .string("feito, token=abc123")])
            #expect(r.ok, "\(r)")
            guard case .object(let m)? = obj(r)["message"] else { Issue.record("\(r)"); return }
            #expect(s(obj(r)["id"]) == s(c["id"]) && s(m["byName"]) == "A" && s(m["byTerminal"]) == a.id.lowercased())
            #expect(s(m["body"]) == "feito, [hidden]")   // scrubbed before it is stored
            #expect(messages(rows(try await admin(d, p, "comment.list"))[0]) == ["deixe maior", "feito, [hidden]"])
            let events = await d.router.panelEvents[panel] ?? []
            #expect(events.filter { $0.name == "comment.changed" }.count == 2, "\(events)")   // add + reply
        }
    }

    @Test func replyFromOtherTerminalRefused() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: a.uuid)
            let id = try #require(s(obj(try await add(d, p, repo))["id"]))
            #expect(try await call(p, b, "comment.reply", ["id": .string(id), "text": .string("eu respondo")]).error?.code == .unauthorized)
            #expect(try await admin(d, p, "comment.reply", ["id": .string(id), "text": .string("app")]).error?.code == .unauthorized)
            #expect(try await call(p, a, "comment.reply", ["id": .string("00000000"), "text": .string("x")]).error?.code == .notFound)
            #expect(messages(rows(try await admin(d, p, "comment.list"))[0]) == ["deixe maior"])
        }
    }

    @Test func listFromTerminalOnlyMine() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            _ = await d.router.addPreviewPanel("PA", createdBy: a.uuid)
            _ = await d.router.addPreviewPanel("PB", createdBy: b.uuid)
            _ = try await add(d, p, repo, panel: "PA", body: "para A")
            _ = try await add(d, p, repo, panel: "PB", body: "para B")
            _ = try await add(d, p, repo, panel: nil, body: "para ninguém")
            #expect(rows(try await call(p, a, "comment.list")).flatMap(messages) == ["para A"])
            #expect(rows(try await call(p, b, "comment.list", ["root": .string(repo.path), "path": .string("index.html")])).flatMap(messages) == ["para B"])
            #expect(rows(try await admin(d, p, "comment.list")).flatMap(messages) == ["para ninguém", "para B", "para A"])
            #expect(rows(try await admin(d, p, "comment.list", ["artifact": .string(UUID().uuidString)])).isEmpty)
        }
    }

    @Test func addresseeGone() async throws {
        let repo = try await project()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            _ = await d.router.addPreviewPanel(createdBy: a.uuid)
            let id = try #require(s(obj(try await add(d, p, repo))["id"]))
            #expect(try await admin(d, p, "admin.kill", ["target": .string("A")]).ok)
            let o = rows(try await admin(d, p, "comment.list"))
            #expect(o.count == 1 && o[0]["undeliverable"] == .bool(true) && s(o[0]["toName"]) == "A")
            #expect(obj(try await admin(d, p, "comment.resolve", ["id": .string(id)]))["resolved"] == .bool(true))
        }
    }

    @Test func mcpHidesAdminCommands() {
        let names = Set(MCPSchema.tools(shepherd: true).compactMap { t -> String? in
            if case .object(let o) = t { return s(o["name"]) }; return nil
        })
        #expect(names.isSuperset(of: ["comment_reply", "comment_list"]))
        #expect(names.isDisjoint(with: ["comment_add", "comment_message", "comment_resolve", "comment_unresolve"]))
    }
}
