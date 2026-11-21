import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

// M7.1 (rev-onda6 A1): the HISTÓRICO detail is kept in the work's paddock, in the "Histórico" folder, seen only by the
// app and that paddock's terminals, and opening it again replaces its one version.

private struct Term { var id: String; var name: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, paddock: String) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": name, "preset": "shell", "cwd": cwd.path, "paddock": paddock])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
private func ids(_ r: Response) -> [String] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0, case .string(let id)? = o["id"] { id } else { nil } }
}

@Suite(.serialized) struct HistoryArtifactPrivacyTests {
    /// Two paddocks (x, y), a terminal in each, and a closed work of x's terminal: its id.
    private func withTwoPaddocks(_ body: (Daemon, Paths, Term, Term, String, URL) async throws -> Void) async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            for n in ["x", "y"] { #expect(try await admin(d, p, "paddock.create", ["name": n, "repo": repo.path]).ok) }
            let px = repo.appendingPathComponent(".collie/paddocks/x"), py = repo.appendingPathComponent(".collie/paddocks/y")
            let tx = try await term(d, p, "TX", cwd: px, paddock: "x"), ty = try await term(d, p, "TY", cwd: py, paddock: "y")
            let start = try await admin(d, p, "work.start", ["terminal": tx.name, "title": "Segredo do cliente X"])
            guard case .string(let wid)? = obj(start)["id"] else { Issue.record("\(start)"); return }
            #expect(try await admin(d, p, "work.done", ["terminal": tx.name]).ok)
            try await body(d, p, tx, ty, wid, py)
        }
    }
    private func openDetail(_ d: Daemon, _ p: Paths, _ wid: String, _ n: Int = 1) async throws -> [String: JSONValue] {
        let r = try await admin(d, p, "artifact.add", ["html": "<h1>Segredo \(n)</h1>", "source": "history-\(wid)", "title": "Segredo do cliente X"])
        #expect(r.ok, "\(r)")
        return obj(r)
    }

    @Test func otherPaddockNeitherListsNorReads() async throws {
        try await withTwoPaddocks { d, p, tx, ty, wid, _ in
            guard case .string(let aid)? = try await openDetail(d, p, wid)["id"] else { Issue.record("no id"); return }
            // the other paddock's terminal: not in the list (nor its path), not by id, not exported
            let ly = try await call(p, ty, "artifact.list")
            #expect(ly.ok && !ids(ly).contains(aid), "\(ly)")
            #expect(!"\(ly)".contains(aid) && !"\(ly)".contains("history-"))
            #expect(try await call(p, ty, "artifact.get", ["id": aid]).error?.code == .notFound)
            // the work's paddock's terminal and the app see it, in the Histórico folder of paddock x
            #expect(ids(try await call(p, tx, "artifact.list")).contains(aid))
            #expect(ids(try await admin(d, p, "artifact.list")).contains(aid))
            let got = obj(try await call(p, tx, "artifact.get", ["id": aid]))
            #expect(got["folder"] == .string("Histórico"), "\(got)")
            let rec = try await d.router.artifacts.get(try #require(UUID(uuidString: aid)))
            let x = await d.router.ws.paddocks.first { $0.name == "x" }?.id
            #expect(rec.paddockId != nil && rec.paddockId == x)
            #expect(obj(try await admin(d, p, "artifact.get", ["id": aid]))["id"] == .string(aid))
        }
    }

    @Test func openingAgainKeepsOneVersion() async throws {
        try await withTwoPaddocks { d, p, _, _, wid, _ in
            var aid = ""
            for n in 1...3 {
                let r = try await openDetail(d, p, wid, n)
                guard case .string(let id)? = r["id"] else { Issue.record("\(r)"); return }
                if n > 1 { #expect(id == aid) }
                aid = id
                #expect(r["version"] == .number(1), "\(r)")
            }
            let a = try await d.router.artifacts.get(try #require(UUID(uuidString: aid)))
            let same = try await d.router.artifacts.list().filter { $0.origin == "history-\(wid)" }
            #expect(a.version == 1 && same.count == 1)
            let root = await d.router.artifacts.dir
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(aid).path)
            #expect(!names.contains { $0.wholeMatch(of: /r[0-9]+/) != nil }, "\(names)")   // no r<N> versions kept
            let page = try String(contentsOf: root.appendingPathComponent(try #require(a.source)), encoding: .utf8)
            #expect(page.contains("Segredo 3"))
        }
    }

    @Test func ordinaryArtifactsUnchanged() async throws {
        try await withTwoPaddocks { d, p, tx, ty, _, py in
            try Data("<h1>comum</h1>".utf8).write(to: py.appendingPathComponent("p.html"))
            let r = try await call(p, ty, "artifact.add", ["path": "p.html"], cwd: py.path)
            guard case .string(let aid)? = obj(r)["id"] else { Issue.record("\(r)"); return }
            // a terminal's ordinary page: every terminal still lists and reads it (as before)
            #expect(ids(try await call(p, tx, "artifact.list")).contains(aid))
            #expect(try await call(p, tx, "artifact.get", ["id": aid]).ok)
            #expect(obj(try await call(p, tx, "artifact.get", ["id": aid]))["path"] != nil)
            // a terminal cannot forge a history source: it stays an ordinary claude.ai-link check
            #expect(try await call(p, ty, "artifact.add", ["path": "p.html", "source": "history-\(UUID().uuidString)"], cwd: py.path).error != nil)
        }
    }
}
