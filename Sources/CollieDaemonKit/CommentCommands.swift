import Foundation
import CollieCore
import CollieProtocol

/// `comment.*`: the user pins comments to a page in the Prévia (the app, admin) and the page's terminal answers them.
/// add, message (a user follow-up), resolve and unresolve: the app alone; reply: only the comment's addressee terminal;
/// list from a terminal: only the comments addressed to it. Bodies are scrubbed before they are stored.
extension CommandRouter {
    func commentCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the user / app)
        func appOnly() throws(ProtocolError) {
            if caller != nil { throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is app-only") }
        }
        func scrubbed(_ k: String) async throws(ProtocolError) -> String {
            LotBoards.scrub(try need(r, k), secrets: await auth.secrets())
        }

        switch r.command {
        case "comment.add":
            try appOnly()
            guard let page = try await commentPage(r, check: true) else {
                throw ProtocolError(code: .invalidArgs, message: "pass --artifact <id>, or --root <folder> with --path <file>")
            }
            let to = try str(r, "panel").flatMap { n throws(ProtocolError) in addressee(of: try findPanel(n)) }
            // the page's text, selector and title are agent-written: stored scrubbed like the bodies
            let secrets = await auth.secrets()
            let anchor = CommentAnchor(selector: str(r, "selector").flatMap { $0.isEmpty ? nil : LotBoards.scrub($0, secrets: secrets) },
                                       x: try fraction(r, "x"), y: try fraction(r, "y"), text: str(r, "text").map { LotBoards.scrub($0, secrets: secrets) })
            let title = LotBoards.scrub(try need(r, "title"), secrets: secrets)
            let c = try await comments.add(page: page, title: title, anchor: anchor, body: try await scrubbed("body"), to: to?.id, toName: to?.name)
            await commentChanged(page, c)
            return commentJSON(page, title, c)
        case "comment.message", "comment.resolve", "comment.unresolve":
            try appOnly()
            let (page, found) = try await comments.find(try need(r, "id"))
            let c = r.command == "comment.message" ? try await comments.message(found.id, body: try await scrubbed("body"))
                : try await comments.setResolved(found.id, r.command == "comment.resolve")
            await commentChanged(page, c)
            return commentJSON(page, await commentTitle(page), c)
        case "comment.reply":
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'comment.reply' is for the comment's terminal") }
            let (page, found) = try await comments.find(try need(r, "id"))
            let c = try await comments.reply(found.id, from: me.id, name: me.name, body: try await scrubbed("text"))
            await commentChanged(page, c)
            return .object(["id": .string(c.id.uuidString.lowercased()), "message": messageJSON(c.messages[c.messages.count - 1])])
        case "comment.list":
            let only = try await commentPage(r, check: false)?.key
            let open = flag(r, "open")
            var rows: [(Date, JSONValue)] = []
            for p in await comments.pagesList() where only == nil || only == p.page.key {
                for c in p.comments where (!open || !c.resolved) && (caller.map { c.to == $0.id } ?? true) {
                    rows.append((c.messages.first?.at ?? .distantPast, commentJSON(p.page, p.title, c)))
                }
            }
            return .array(rows.sorted { $0.0 > $1.0 }.map(\.1))   // newest first
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// The comment's terminal: the Prévia's creator if it still exists, else the single terminal leashed to it, else none.
    func addressee(of p: Panel) -> TerminalRecord? {
        if let c = p.createdBy, let t = ws.terminals.first(where: { $0.id == c }) { return t }
        let ends = Set(ws.connections.compactMap { $0.a == p.id ? $0.b : $0.b == p.id ? $0.a : nil })
        let leashed = ws.terminals.filter { ends.contains($0.id) }
        return leashed.count == 1 ? leashed[0] : nil
    }

    /// `--artifact`, or `--root` + `--path`: the real root and the path inside it (`..` and symlinks out refused).
    /// `check`: the artifact exists, the file exists and is .html/.htm. nil when neither is given.
    private func commentPage(_ r: Request, check: Bool) async throws -> PageRef? {
        if let a = str(r, "artifact") {
            guard let id = UUID(uuidString: a) else { throw ProtocolError(code: .invalidArgs, message: "'artifact' must be an artifact id") }
            if check { _ = try await artifacts.get(id) }
            return .artifact(id)
        }
        guard let rootArg = str(r, "root") else { return nil }
        let path = try need(r, "path")
        let root = PageRef.canonical(URL(fileURLWithPath: rootArg))
        var dir: ObjCBool = false
        guard rootArg.hasPrefix("/"), FileManager.default.fileExists(atPath: root.path, isDirectory: &dir), dir.boolValue else {
            throw ProtocolError(code: .invalidArgs, message: "'root' must be an existing folder (absolute path)")
        }
        // the Prévia's own rule (inside the root, .html/.htm, ≤ 8 MiB), then the volume's case; add needs the file to exist
        guard !path.hasPrefix("/") else { throw ProtocolError(code: .invalidArgs, message: "'path' must be relative to the root") }
        let file = PageRef.canonical(try PreviewFile.resolve(path, projectRoot: root))
        var isDir: ObjCBool = false
        guard file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
              !check || (FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && !isDir.boolValue) else {
            throw ProtocolError(code: .invalidArgs, message: "'path' must be an .html or .htm file inside the root")
        }
        return .project(root: root.path, path: String(file.path.dropFirst(root.path.count + (root.path == "/" ? 0 : 1))))
    }

    private func fraction(_ r: Request, _ k: String) throws(ProtocolError) -> Double {
        let v: Double? = switch r.args[k] { case .number(let n)?: n; case .string(let s)?: Double(s); default: nil }
        guard let v, v.isFinite else { throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be a number from 0 to 1") }
        return v
    }

    private func commentTitle(_ page: PageRef) async -> String {
        await comments.pagesList().first { $0.page.key == page.key }?.title ?? ""
    }

    /// `comment.changed {page, id}` to every Prévia panel (as `artifact.*` reach the Artifacts panel).
    private func commentChanged(_ page: PageRef, _ c: PageComment) async {
        for p in ws.panels where p.pluginId == "preview" {
            await pluginEmitted(panel: p.id, name: "comment.changed",
                                payload: .object(["page": .string(page.key), "id": .string(c.id.uuidString.lowercased())]))
        }
    }

    private func messageJSON(_ m: CommentMessage) -> JSONValue {
        .object(["id": .string(m.id.uuidString.lowercased()), "byTerminal": m.byTerminal.map { .string($0.uuidString.lowercased()) } ?? .null,
                 "byName": .string(m.byName), "body": .string(m.body), "at": .string(m.at.formatted(.iso8601))])
    }

    private func commentJSON(_ page: PageRef, _ title: String, _ c: PageComment) -> JSONValue {
        var pg: [String: JSONValue] = ["key": .string(page.key)]
        switch page {
        case .artifact(let a): pg["artifact"] = .string(a.uuidString.lowercased())
        case .project(let root, let path): pg["root"] = .string(root); pg["path"] = .string(path)
        }
        var anchor: [String: JSONValue] = ["x": .number(c.anchor.x), "y": .number(c.anchor.y)]
        if let s = c.anchor.selector { anchor["selector"] = .string(s) }
        if let t = c.anchor.text { anchor["text"] = .string(t) }
        return .object([
            "id": .string(c.id.uuidString.lowercased()), "short": .string(c.short), "page": .object(pg), "title": .string(title),
            "anchor": .object(anchor), "to": c.to.map { .string($0.uuidString.lowercased()) } ?? .null,
            "toName": c.toName.map(JSONValue.string) ?? .null,
            "undeliverable": .bool(c.to.map { id in !ws.terminals.contains { $0.id == id } } ?? false),
            "resolved": .bool(c.resolved), "messages": .array(c.messages.map(messageJSON)),
        ])
    }

    /// The user's comments for `terminal`'s next prompt (`CommentStore.inject`).
    func commentsInject(to terminal: UUID, limit: Int) async -> String { await comments.inject(to: terminal, limit: limit) }
}
