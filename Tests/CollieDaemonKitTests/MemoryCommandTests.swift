import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL? = nil, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell")]
    if let cwd { args["cwd"] = .string(cwd.path) }
    if let paddock { args["paddock"] = .string(paddock) }
    let r = try await admin(d, p, "admin.spawn", args)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { return o }; return [:] }
private func s(_ v: JSONValue?) -> String? { if case .string(let x)? = v { return x }; return nil }
private func rows(_ v: JSONValue?) -> [[String: JSONValue]] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap { if case .object(let o) = $0 { return o }; return nil }
}
private func context(_ p: Paths, _ t: Term) async throws -> String { s(obj(try await call(p, t, "memory.context"))["output"]) ?? "" }
/// The physical path, as git reports it (/var → /private/var).
private func real(_ u: URL) -> String { realpath(u.path, nil).map { c in defer { free(c) }; return String(cString: c) } ?? u.path }
private func git(_ args: [String], _ dir: URL) async throws -> String {
    try await GitRunner.run(args, in: dir).stdout
}

/// Commits everything in `repo` but Collie's own `.collie/`.
private func commitAll(_ repo: URL) async throws {
    _ = try await git(["add", "--", ".", ":!.collie"], repo)
    _ = try await git(["commit", "-q", "-m", "more"], repo)
}

@Suite(.serialized) struct MemoryCommandTests {
    @Test func terminalSavesAndSearches() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let r = try await call(p, t, "memory.save", ["kind": "decision", "subject": "Database", "title": "Use Postgres",
                                                         "body": "chosen for jsonb support\nand mature tooling"])
            let o = obj(r)
            #expect(r.ok && s(o["scope"]) == "project" && s(o["origin"]) == "T (shell)" && o["reviewed"] == .bool(false), "\(r)")
            let file = try #require(s(o["file"]))
            #expect(file.hasPrefix(real(repo) + "/.collie/memory/decision/") && FileManager.default.fileExists(atPath: file))
            #expect(s(o["createdAt"])?.hasSuffix("Z") == true)   // ISO-8601
            let hits = rows(try await call(p, t, "memory.search", ["query": "postgres"]).result)
            #expect(hits.count == 1 && hits.first?["id"] == o["id"] && hits.first?["file"] == o["file"])
            #expect(rows(try await call(p, t, "memory.search", ["query": "kubernetes"]).result).isEmpty)
            let list = obj(try await call(p, t, "memory.list"))
            #expect(rows(list["records"]).map { $0["id"] } == [o["id"]] && rows(list["problems"]).isEmpty)
            let got = obj(try await call(p, t, "memory.get", ["id": s(o["id"]) ?? ""]))
            #expect(got["title"] == .string("Use Postgres") && got["subject"] == .string("database"))
            #expect(try await call(p, t, "memory.save", ["kind": "nope", "subject": "x", "title": "y"]).error?.code == .invalidArgs)
        }
    }

    /// DX backlog 9: an agent retires a stale memory in favour of a newer one (reversible: memory restore).
    @Test func terminalSupersedesAStaleMemory() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let old = s(obj(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "empty ask", "title": "Cause unknown"]))["id"]) ?? ""
            let new = s(obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "empty ask cause", "title": "Cause found"]))["id"]) ?? ""
            let r = try await call(p, t, "memory.supersede", ["id": old, "by": new])
            #expect(r.ok && obj(r)["status"] == .string("superseded") && obj(r)["supersededBy"] == .string(new), "\(r)")
            #expect(rows(try await call(p, t, "memory.search", ["query": "cause unknown"]).result).allSatisfy { s($0["id"]) != old })
            #expect(try await call(p, t, "memory.supersede", ["id": new, "by": new]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.supersede", ["id": new, "by": UUID().uuidString]).error?.code == .notFound)
        }
    }

    /// PRD B3.1: a pitfall or decision marked as enforced by a check; `--clear` unmarks; get and search say it.
    @Test func enforceMarksAndClears() async throws {
        let repo = try await makeRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: repo.appendingPathComponent("scripts/lint.sh"))
        try await commitAll(repo)   // B3.4: --by is a file tracked in HEAD
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let since = Date().addingTimeInterval(-1)
            let pit = s(obj(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "force unwrap", "title": "Force unwrap derruba o daemon"]))["id"]) ?? ""
            let dec = s(obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "sleep", "title": "Nada de sleep em teste"]))["id"]) ?? ""
            let map = s(obj(try await call(p, t, "memory.save", ["kind": "map", "subject": "lint", "title": "Lint", "path": "scripts/lint.sh"]))["id"]) ?? ""

            let r = try await call(p, t, "memory.enforce", ["id": pit, "by": "scripts/lint.sh"])
            #expect(r.ok && s(obj(r)["enforcedBy"]) == "scripts/lint.sh" && s(obj(r)["enforced"]) == "imposta por scripts/lint.sh", "\(r)")
            #expect(try String(contentsOfFile: s(obj(r)["file"]) ?? "", encoding: .utf8).contains("\nenforced_by: scripts/lint.sh\n"))
            #expect(try await call(p, t, "memory.enforce", ["id": dec, "by": "scripts/lint.sh"]).ok)   // a decision too
            let got = obj(try await call(p, t, "memory.get", ["id": pit]))
            #expect(s(got["enforced"]) == "imposta por scripts/lint.sh", "\(got)")
            let hit = rows(try await call(p, t, "memory.search", ["query": "force unwrap daemon"]).result).first { s($0["id"]) == pit }
            #expect(s(hit?["enforced"]) == "imposta por scripts/lint.sh", "still searchable, and says so")

            // refusals: wrong kind, missing path, `..`, absolute, neither/both of --by and --clear, unknown id
            #expect(try await call(p, t, "memory.enforce", ["id": map, "by": "scripts/lint.sh"]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": pit, "by": "scripts/gone.sh"]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": pit, "by": "scripts/../scripts/lint.sh"]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": pit, "by": repo.appendingPathComponent("scripts/lint.sh").path]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": pit]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": pit, "by": "scripts/lint.sh", "clear": "true"]).error?.code == .invalidArgs)
            #expect(try await call(p, t, "memory.enforce", ["id": UUID().uuidString, "by": "scripts/lint.sh"]).error?.code == .notFound)
            #expect(s(obj(try await call(p, t, "memory.get", ["id": pit]))["enforcedBy"]) == "scripts/lint.sh")   // a refusal changes nothing

            let c = try await call(p, t, "memory.enforce", ["id": pit, "clear": "true"])
            #expect(c.ok && obj(c)["enforcedBy"] == nil && obj(c)["enforced"] == nil, "\(c)")
            #expect(obj(try await call(p, t, "memory.get", ["id": pit]))["enforced"] == nil)

            d.router.memory.events.flush()
            let evs = d.router.memory.events.read(since: since).filter { $0.type == .enforced && $0.ids == [UUID(uuidString: pit)!] }
            #expect(evs.map(\.mode) == ["set", "clear"] && evs.first?.reason == "scripts/lint.sh" && evs.first?.source == "agent", "\(evs)")
        }
    }

    /// B3.4: `--by` is a regular file tracked in HEAD; an agent enforces only a project memory of its own store, the app
    /// (with a `--repo` that is a git repo) also a global or a lot one; `--clear` on a memory no check enforces writes nothing.
    @Test func enforceScopeAndPath() async throws {
        let repo = try await makeRepo(), fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: repo.appendingPathComponent("scripts/lint.sh"))
        try fm.createSymbolicLink(atPath: repo.appendingPathComponent("link.sh").path, withDestinationPath: "scripts/lint.sh")
        try await commitAll(repo)
        try Data("#!/bin/sh\n".utf8).write(to: repo.appendingPathComponent("untracked.sh"))
        let outside = fm.temporaryDirectory.appendingPathComponent("collie-nogit-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let since = Date().addingTimeInterval(-1)
            func events(_ id: String) -> [MemoryEvent] {
                d.router.memory.events.flush()
                return d.router.memory.events.read(since: since).filter { $0.type == .enforced && $0.ids == [UUID(uuidString: id)!] }
            }
            let pit = s(obj(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "force unwrap", "title": "Force unwrap derruba o daemon"]))["id"]) ?? ""

            // not a regular file tracked in HEAD: refused, in Portuguese, nothing written
            for by in [".", ".git", "scripts", "scripts/", "link.sh", "untracked.sh", "scripts/lint.sh\n", "scripts/li\u{7}nt.sh", "scripts/lint.sh x"] {
                let r = try await call(p, t, "memory.enforce", ["id": pit, "by": by])
                #expect(r.error?.code == .invalidArgs && r.error?.message.hasPrefix("--by") == true, "\(by.debugDescription): \(r)")
            }
            #expect(obj(try await call(p, t, "memory.get", ["id": pit]))["enforcedBy"] == nil && events(pit).isEmpty)

            // --clear with no check on it: says so, no write, no event
            let file = try #require(s(obj(try await call(p, t, "memory.get", ["id": pit]))["file"]))
            let before = try fm.attributesOfItem(atPath: file)[.modificationDate] as? Date
            let c = try await call(p, t, "memory.enforce", ["id": pit, "clear": "true"])
            #expect(c.ok && s(obj(c)["message"]) == "não estava imposto", "\(c)")
            #expect(try fm.attributesOfItem(atPath: file)[.modificationDate] as? Date == before && events(pit).isEmpty)

            // a project memory and a tracked file: passes
            #expect(try await call(p, t, "memory.enforce", ["id": pit, "by": "scripts/lint.sh"]).ok)
            #expect(events(pit).map(\.mode) == ["set"])

            // an agent: neither a global memory nor its lot's
            let global = MemoryRecord(kind: .pitfall, scope: .global, subject: "global pit", title: "Armadilha global")
            try await d.router.memory.global.run { m in try m.store.write(global) }
            let gid = global.id.uuidString
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "T"]).ok)
            let saved = obj(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "lot pit", "title": "Armadilha do lote"]))
            let lid = try #require(s(saved["id"]))
            #expect(s(saved["scope"]) == "lot", "\(saved)")
            for id in [gid, lid] {
                for args in [["id": id, "by": "scripts/lint.sh"], ["id": id, "clear": "true"]] {
                    let r = try await call(p, t, "memory.enforce", args)
                    #expect(r.error?.code == .unauthorized && r.error?.message == "só o dono impõe itens globais ou de lote", "\(r)")
                }
                #expect(events(id).isEmpty)
            }
            let unknown = try await call(p, t, "memory.enforce", ["id": UUID().uuidString, "by": "scripts/lint.sh"])
            #expect(unknown.error?.code == .notFound && unknown.error?.message.contains("não encontrada") == true, "\(unknown)")

            // the app: only with a --repo that is a git repo
            let by: JSONValue = .string("scripts/lint.sh")
            #expect(try await admin(d, p, "memory.enforce", ["id": .string(gid), "by": by]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "memory.enforce", ["id": .string(gid), "by": by, "repo": .string(outside.path)]).error?.code == .invalidArgs)
            #expect(events(gid).isEmpty)
            let g = try await admin(d, p, "memory.enforce", ["id": .string(gid), "by": by, "repo": .string(repo.path)])
            #expect(g.ok && s(obj(g)["enforcedBy"]) == "scripts/lint.sh", "\(g)")
            let l = try await admin(d, p, "memory.enforce", ["id": .string(lid), "by": by, "repo": .string(repo.path), "lot": "Login"])
            #expect(l.ok && s(obj(l)["enforcedBy"]) == "scripts/lint.sh", "\(l)")
            #expect(events(gid).map(\.source) == ["user"] && events(lid).map(\.mode) == ["set"])
        }
    }

    /// PRD B3 req. 4: `memory list --candidates`: active pitfalls with 3+ hits and no check, most hits first; a Shepherd's
    /// orientation names them only while there are some.
    @Test func listCandidatesAndShepherdLine() async throws {
        let repo = try await makeRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: repo.appendingPathComponent("scripts/lint.sh"))
        try await commitAll(repo)   // B3.4: --by is a file tracked in HEAD
        try await withDaemon { d, p in
            func pit(_ title: String, _ hits: Int?, status: MemoryStatus = .active) -> MemoryRecord {
                MemoryRecord(kind: .pitfall, subject: title, title: title, status: status, hits: hits)
            }
            let three = pit("Três", 3), nine = pit("Nove", 9), five = pit("Cinco", 5)
            let store = await d.router.memory.repo(for: repo.path)
            let all = [three, nine, five, pit("Duas", 2), pit("Instância", nil), pit("Arquivada", 9, status: .archived),
                       MemoryRecord(kind: .decision, subject: "dec", title: "Decisão", hits: 9)]
            try await store.run { m in for r in all { try m.store.write(r) } }
            let t = try await term(d, p, "T", cwd: repo)
            let sr = try await admin(d, p, "admin.spawn", ["name": .string("S"), "preset": .string("shell"), "cwd": .string(repo.path), "shepherd": .bool(true)])
            let sid = try #require(s(obj(sr)["id"]))
            let shepherd = Term(id: sid, token: try await tokenOf(d, sid))
            func candidates() async throws -> [String] {
                rows(obj(try await call(p, t, "memory.list", ["candidates": "true"]))["records"]).compactMap { s($0["title"]) }
            }
            func orientation(_ who: Term) async throws -> String { s(obj(try await call(p, who, "memory.hookContext"))["output"]) ?? "" }

            #expect(try await candidates() == ["Nove", "Cinco", "Três"])
            #expect(rows(obj(try await call(p, t, "memory.list"))["records"]).count == 6)   // without the flag: every active one
            #expect(try await orientation(shepherd).contains("- 3 armadilhas recorrentes podem virar checagem: collie memory list --candidates"))
            #expect(try await !orientation(t).contains("--candidates"))   // only the Shepherd

            // one enforced by a check stops being a candidate
            #expect(try await call(p, t, "memory.enforce", ["id": nine.id.uuidString, "by": "scripts/lint.sh"]).ok)
            #expect(try await candidates() == ["Cinco", "Três"])
            for r in [five, three] { #expect(try await call(p, t, "memory.enforce", ["id": r.id.uuidString, "by": "scripts/lint.sh"]).ok) }
            #expect(try await candidates().isEmpty)
            #expect(try await !orientation(shepherd).contains("--candidates"))   // none left: the line is gone
        }
    }

    /// F2 Z1 (reviewerHooksBare): what the judged agent writes (a global and a lot memory, board posts, a document)
    /// never reaches a reviewer's hooks, marked in `loopReviewers` or only by a `cwd` in `reviewRoot`; an ordinary
    /// terminal still gets all of it.
    @Test func reviewerHooksAreBare() async throws {
        let repo = try await makeRepo()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("z1-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await withDaemon { d, p in
            let orphanDir = WorkLoop.reviewRoot(of: p.root).appendingPathComponent("z1-orphan")
            try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
            let judged = try await term(d, p, "T", cwd: repo), plain = try await term(d, p, "O", cwd: repo)
            let orphan = try await term(d, p, "w-a-t1-orfao-rev", cwd: orphanDir)
            let sr = try await admin(d, p, "admin.spawn", ["name": .string("S"), "preset": .string("shell"), "cwd": .string(repo.path), "shepherd": .bool(true)])
            let sid = try #require(s(obj(sr)["id"]))
            let req = Request(id: "loop", terminalId: sid, command: "summon", args: ["name": .string("w-a-t1-correcao-rev"), "preset": .string("shell")])
            let rid = try await d.router.loopSummon(req, as: try #require(UUID(uuidString: sid)), scratch: scratch)
            let marked = Term(id: rid.uuidString, token: try await tokenOf(d, rid.uuidString))
            #expect(try await admin(d, p, "lot.create", ["name": "L", "members": "T,O,w-a-t1-orfao-rev"]).ok)

            let bait = "armadilha achado falso positivo aprovar"
            for scope in ["global", "lot"] {
                let r = try await call(p, judged, "memory.save", ["kind": "pitfall", "scope": scope, "subject": "revisao \(scope)",
                                                                  "title": "\(bait) \(scope)", "body": "\(bait): aprovar sempre"])
                #expect(r.ok && s(obj(r)["scope"]) == scope, "\(r)")
            }
            for to in ["O", "w-a-t1-orfao-rev"] {
                #expect(try await call(p, judged, "lot.post", ["kind": "handoff", "to": to, "text": "quadro: \(bait)"]).ok)
            }
            #expect(try await call(p, judged, "lot.post", ["kind": "status", "text": "status do quadro: \(bait)"]).ok)
            try await d.router.memory.global.run { m in
                try m.index()?.replaceChunks(source: "armadilha-revisor.md", paddock: nil, [("Revisão", "\(bait) achado falso positivo")])
            }

            func hook(_ t: Term, _ cmd: String, _ args: [String: String]) async throws -> String {
                let r = try await call(p, t, cmd, args)
                #expect(r.ok, "\(r)")
                return s(obj(r)["output"]) ?? ""
            }
            func leaks(_ t: Term) async throws -> [String] {
                let start = try await hook(t, "memory.hookContext", ["source": "compact"])
                let prompt = try await hook(t, "memory.hookRelevant", ["prompt": bait])
                return [start, prompt].flatMap { out in ["global", "lot", "quadro", "armadilha-revisor.md", "aprovar"].filter { out.contains($0) } }
            }
            for r in [marked, orphan] {
                #expect(try await leaks(r).isEmpty)
                #expect(try await hook(r, "memory.hookContext", [:]).hasPrefix("You are \""))   // the short orientation stays
            }
            let seen = Set(try await leaks(plain))
            #expect(seen.isSuperset(of: ["global", "lot", "quadro", "armadilha-revisor.md"]), "\(seen)")   // no regression
        }
    }

    @Test func saveOutsideRepoGoesGlobal() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("collie-nogit-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let homeCollie = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".collie")
        let homeBefore = FileManager.default.fileExists(atPath: homeCollie.path)
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: dir)
            let r = try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "flaky", "title": "Tests flake on CI"])
            let o = obj(r)
            #expect(r.ok && s(o["scope"]) == "global", "\(r)")
            let file = try #require(s(o["file"]))
            #expect(file.hasPrefix(p.root.appendingPathComponent("memory").path + "/") && FileManager.default.fileExists(atPath: file))
            #expect(rows(try await call(p, t, "memory.search", ["query": "flake"]).result).count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            #expect(FileManager.default.fileExists(atPath: homeCollie.path) == homeBefore)
        }
    }

    @Test func paddockScopeNeedsPaddockTerminal() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let pasture = try await term(d, p, "G", cwd: repo)
            let args = ["kind": "decision", "subject": "api", "title": "REST", "scope": "paddock"]
            #expect(try await call(p, pasture, "memory.save", args).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "memory.save", args.mapValues { .string($0) }.merging(["repo": .string(repo.path)]) { a, _ in a })
                .error?.code == .invalidArgs)
            #expect(try await admin(d, p, "paddock.create", ["name": .string("feat"), "repo": .string(repo.path)]).ok)
            let f = try await term(d, p, "F", paddock: "feat")
            let r = try await call(p, f, "memory.save", args)
            let o = obj(r)
            #expect(r.ok && s(o["scope"]) == "paddock" && s(o["paddock"]) == "feat", "\(r)")
            // the paddock's worktree is its repo: the memory travels with the paddock
            #expect(s(o["file"])?.hasPrefix(real(repo) + "/.collie/paddocks/feat/.collie/memory/") == true, "\(o)")
            #expect(try await context(p, f).contains("REST"))
        }
    }

    @Test func supersedeIsImmediateInContext() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let a = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use MySQL"]))
            #expect(try await context(p, t).contains("Use MySQL"))
            let b = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "DB ", "title": "Use Postgres", "body": "jsonb"]))
            #expect(b["superseded"] == a["id"])
            let c = try await context(p, t)
            #expect(c.hasPrefix(MemoryService.header) && c.contains("\n- Use Postgres") && !c.contains("MySQL"), "\(c)")
        }
    }

    @Test func discardRemovesFromContext() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            _ = try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use MySQL"])
            let b = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use Mongo"]))
            let other = obj(try await call(p, t, "memory.save", ["kind": "pitfall", "subject": "cache", "title": "Cache is stale"]))
            for id in [b["id"], other["id"]] {
                let r = try await admin(d, p, "memory.review", ["id": id ?? .null, "action": .string("discard"), "repo": .string(repo.path)])
                #expect(r.ok && s(obj(r)["status"]) == "discarded", "\(r)")
            }
            let c = try await context(p, t)
            // discarding the replacement makes the decision it replaced current again
            #expect(!c.contains("Mongo") && !c.contains("Cache is stale") && c.contains("Use MySQL"), "\(c)")
        }
    }

    @Test func reviewIsAdminOnly() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let id = s(obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use Postgres"]))["id"]) ?? ""
            for cmd in ["memory.review", "memory.restore", "memory.pin", "memory.unpin", "memory.cleanup", "memory.purge", "memory.repos"] {
                #expect(try await call(p, t, cmd, ["id": id, "action": "approve"]).error?.code == .unauthorized, "\(cmd)")
            }
            let r = try await admin(d, p, "memory.review", ["id": .string(id), "action": .string("approve"), "repo": .string(repo.path),
                                                            "body": .string("edited body")])
            #expect(r.ok && obj(r)["reviewed"] == .bool(true), "\(r)")
            let c = try await context(p, t)
            #expect(c.contains("\n- Use Postgres"), "\(c)")   // unpinned: an index line (the body comes by relevance)
            #expect(try await admin(d, p, "memory.pin", ["id": .string(id), "repo": .string(repo.path)]).ok)
            let repos = rows(try await admin(d, p, "memory.repos").result)
            #expect(repos.map { s($0["path"]) } == [real(repo), p.root.appendingPathComponent("memory").path], "\(repos)")
        }
    }

    @Test func contextIsBounded() async throws {
        let repo = try await makeRepo()
        let store = MemoryStore(dir: repo.appendingPathComponent(".collie/memory"))
        var expected = Set<String>()
        for i in 0..<300 {
            let r = MemoryRecord(kind: .decision, subject: "s\(i)", title: "Decision number \(i)", body: "because reason \(i)\nmore detail",
                                 createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
            try store.write(r)
            expected.insert("- Decision number \(i)")   // index lines: titles only
        }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let c = try await context(p, t)
            #expect(c.utf8.count <= 4096 && c.hasPrefix(MemoryService.header))
            let items = c.split(separator: "\n").filter { $0.hasPrefix("- ") }.map(String.init)
            #expect(items.count > 10 && items.allSatisfy(expected.contains), "\(c)")
            #expect(items.first == "- Decision number 299")   // newest first
        }
    }

    @Test func relevantSkipsAlreadyInjected() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            func save(_ subject: String, _ title: String, _ body: String) async throws {
                let r = try await admin(d, p, "memory.save", ["kind": .string("decision"), "subject": .string(subject), "title": .string(title),
                                                              "body": .string(body), "repo": .string(repo.path)])
                #expect(r.ok && s(obj(r)["origin"]) == "app", "\(r)")
            }
            try await save("pool", "Postgres pool size is 20", "pgbouncer in transaction mode")
            try await save("ui", "SwiftUI canvas", "drawn with Canvas, not views")
            let mem = d.router.memory, tid = UUID()
            let prompt = "how is the postgres pool configured?"
            let first = await mem.relevant(for: tid, cwd: repo.path, prompt: prompt)
            #expect(first.hasPrefix(MemoryService.relevantHeader) && first.contains("Postgres pool size is 20") && !first.contains("SwiftUI"), "\(first)")
            #expect(first.utf8.count <= 2048)
            #expect(await mem.relevant(for: tid, cwd: repo.path, prompt: prompt).isEmpty)
            #expect(await mem.relevant(for: tid, cwd: repo.path, prompt: "hello, how are you?").isEmpty)
            await mem.endSession(tid)
            #expect(await mem.relevant(for: tid, cwd: repo.path, prompt: prompt).contains("Postgres pool"))
            // the session summary's pinned memories count as injected too (index lines are titles only: not injected)
            let ui = rows(try await admin(d, p, "memory.search", ["query": .string("swiftui"), "repo": .string(repo.path)]).result)
            let uid = try #require(ui.first.flatMap { s($0["id"]) })
            #expect(try await admin(d, p, "memory.pin", ["id": .string(uid), "repo": .string(repo.path)]).ok)
            let other = UUID()
            #expect(await mem.context(for: other, cwd: repo.path).contains("SwiftUI canvas"))
            #expect(await mem.relevant(for: other, cwd: repo.path, prompt: "the swiftui canvas").isEmpty)
        }
    }

    @Test func cacheDirIsExcludedFromGit() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            #expect(try await call(p, t, "memory.save", ["kind": "map", "subject": "router", "title": "Router", "path": "f.txt"]).ok)
            #expect(try await call(p, t, "memory.search", ["query": "router"]).ok)
            #expect(try await call(p, t, "memory.search", ["query": "router"]).ok)
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".collie/cache/memory.sqlite").path))
            let st = try await git(["status", "--porcelain", "--untracked-files=all"], repo)
            #expect(!st.contains(".collie/cache") && st.contains(".collie/memory/map/"), "\(st)")
            let exclude = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
            #expect(exclude.components(separatedBy: "\n").filter { $0 == ".collie/cache/" }.count == 1)
            #expect(try await context(p, t).contains("- f.txt — Router"))
            try FileManager.default.removeItem(at: repo.appendingPathComponent("f.txt"))
            #expect(!(try await context(p, t).contains("Router")))   // a vanished path leaves the map
        }
    }

    @Test func archiveHidesRestoresAndSurvivesPurge() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            _ = try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use MySQL"])
            let b = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use Mongo"]))
            let rp: JSONValue = .string(repo.path)
            let r = try await admin(d, p, "memory.review", ["id": b["id"] ?? .null, "action": .string("archive"), "repo": rp])
            #expect(r.ok && s(obj(r)["status"]) == "archived", "\(r)")
            let c = try await context(p, t)
            #expect(!c.contains("Mongo") && !c.contains("MySQL"), "\(c)")   // the replaced one is NOT brought back
            #expect(obj(try await admin(d, p, "memory.purge", ["repo": rp]))["deleted"] == .number(0))
            #expect(FileManager.default.fileExists(atPath: s(b["file"]) ?? ""))
            #expect(try await admin(d, p, "memory.restore", ["id": b["id"] ?? .null, "repo": rp]).ok)
            #expect(try await context(p, t).contains("Use Mongo"))
        }
    }

    @Test func approveWithEditsAppliesThem() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let a = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use Postgres", "body": "old"]))
            let r = try await admin(d, p, "memory.review", ["id": a["id"] ?? .null, "action": .string("approve"), "repo": .string(repo.path),
                                                            "title": .string("Use SQLite"), "body": .string("new body"), "subject": .string("Storage")])
            let o = obj(r)
            #expect(r.ok && s(o["title"]) == "Use SQLite" && s(o["body"]) == "new body" && s(o["subject"]) == "storage" && o["reviewed"] == .bool(true), "\(r)")
            #expect(try await context(p, t).contains("\n- Use SQLite"))
        }
    }

    @Test func purgeDeletesOnlyDiscarded() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let a = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "a", "title": "Alpha"]))
            let b = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "b", "title": "Beta"]))
            let rp: JSONValue = .string(repo.path)
            #expect(try await admin(d, p, "memory.review", ["id": a["id"] ?? .null, "action": .string("discard"), "repo": rp]).ok)
            let r = try await admin(d, p, "memory.purge", ["repo": rp])
            #expect(obj(r)["deleted"] == .number(1), "\(r)")
            #expect(!FileManager.default.fileExists(atPath: s(a["file"]) ?? "") && FileManager.default.fileExists(atPath: s(b["file"]) ?? "/x"))
            #expect(rows(obj(try await admin(d, p, "memory.list", ["status": .string("discarded"), "repo": rp]))["records"]).isEmpty)
            #expect(rows(obj(try await admin(d, p, "memory.list", ["repo": rp]))["records"]).map { $0["id"] } == [b["id"]])
        }
    }

    @Test func discardingASupersededOneKeepsTheCurrent() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            var ids: [JSONValue?] = []
            for title in ["Use A", "Use B", "Use C"] {
                ids.append(obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": title]))["id"])
            }
            let r = try await admin(d, p, "memory.review", ["id": ids[1] ?? .null, "action": .string("discard"), "repo": .string(repo.path)])
            #expect(r.ok, "\(r)")
            func status(_ id: JSONValue?) async throws -> String? {
                s(obj(try await admin(d, p, "memory.get", ["id": id ?? .null, "repo": .string(repo.path)]))["status"])
            }
            let a = try await status(ids[0]), c = try await status(ids[2])
            #expect(a == "superseded" && c == "active")
            #expect(try await context(p, t).contains("Use C"))
        }
    }

    @Test func gitInitLaterIsPickedUp() async throws {
        let dir = URL(fileURLWithPath: realpath(FileManager.default.temporaryDirectory.path, nil).map { c in defer { free(c) }; return String(cString: c) }!)
            .appendingPathComponent("collie-later-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: dir)
            let args = ["kind": "decision", "subject": "x", "title": "X"]
            #expect(s(obj(try await call(p, t, "memory.save", args))["scope"]) == "global")
            _ = try await git(["init", "-b", "main"], dir)
            let o = obj(try await call(p, t, "memory.save", args))
            #expect(s(o["scope"]) == "project" && s(o["file"])?.hasPrefix(dir.path + "/.collie/memory/") == true, "\(o)")
        }
    }

    @Test func indexFailureIsRetriedAndGlobalFailureIsTolerated() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            // a directory where the db file goes: sqlite can't open it
            let db = repo.appendingPathComponent(".collie/cache/memory.sqlite")
            try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: p.root.appendingPathComponent("cache/memory.sqlite"), withIntermediateDirectories: true)
            #expect(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use Postgres"]).ok)
            let bad = try await call(p, t, "memory.search", ["query": "postgres"])
            #expect(bad.error?.code == .unavailable && bad.error?.message.contains("memory index unavailable") == true, "\(bad)")
            #expect(rows(obj(try await call(p, t, "memory.list"))["records"]).count == 1)   // the store still works
            try FileManager.default.removeItem(at: db)
            try await Task.sleep(for: .seconds(RepoMemory.reopenDelay + 0.5))
            // the repo index reopens; the global one is still broken but only drops its hits
            let ok = try await call(p, t, "memory.search", ["query": "postgres"])
            #expect(rows(ok.result).count == 1, "\(ok)")
        }
    }

    /// Two actives with one subject (a land, a hand edit) are resolved before `memory.list` and `memory.context` read.
    @Test func twoActivesResolvedBeforeListAndContext() async throws {
        let repo = try await makeRepo()
        let store = MemoryStore(dir: repo.appendingPathComponent(".collie/memory"))
        func pair(_ subject: String, _ old: String, _ new: String) throws {
            try store.write(MemoryRecord(kind: .decision, subject: subject, title: old, createdAt: Date(timeIntervalSinceNow: -60)))
            try store.write(MemoryRecord(kind: .decision, subject: subject, title: new))
        }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try pair("db", "Use MySQL", "Use Postgres")
            let list = rows(obj(try await call(p, t, "memory.list"))["records"])
            #expect(list.map { s($0["title"]) } == ["Use Postgres"], "\(list)")
            try pair("cache", "Use Memcached", "Use Redis")
            let c = try await context(p, t)
            #expect(c.contains("Use Redis") && !c.contains("Memcached"), "\(c)")
        }
    }

    @Test func relevantSkipsMapWithMissingPath() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            #expect(try await call(p, t, "memory.save", ["kind": "map", "subject": "router", "title": "Router lives here", "path": "f.txt"]).ok)
            try FileManager.default.removeItem(at: repo.appendingPathComponent("f.txt"))
            #expect(await d.router.memory.relevant(for: UUID(uuidString: t.id)!, cwd: repo.path, prompt: "where is the router").isEmpty)
        }
    }

    @Test func mapPathMustStayInsideRepo() async throws {
        let repo = try await makeRepo()
        let outside = repo.deletingLastPathComponent().appendingPathComponent("collie-out-\(UUID().uuidString).txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            for bad in ["/etc/passwd", "../\(outside.lastPathComponent)", "a/../../x"] {
                let r = try await call(p, t, "memory.save", ["kind": "map", "subject": bad, "title": "T", "path": bad])
                #expect(r.error?.code == .invalidArgs, "\(bad): \(r)")
            }
            let ok = obj(try await call(p, t, "memory.save", ["kind": "map", "subject": "f", "title": "F file", "path": real(repo) + "/f.txt"]))
            #expect(s(ok["path"]) == "f.txt", "\(ok)")
            // a hand-written record pointing outside never has its existence probed there
            try MemoryStore(dir: repo.appendingPathComponent(".collie/memory"))
                .write(MemoryRecord(kind: .map, subject: "escape", title: "Escaping map", path: "../\(outside.lastPathComponent)"))
            let c = try await context(p, t)
            #expect(c.contains("F file") && !c.contains("Escaping map"), "\(c)")
        }
    }

    @Test func approveWithNewSubjectRestoresThePrevious() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let a = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use MySQL"]))
            let b = obj(try await call(p, t, "memory.save", ["kind": "decision", "subject": "db", "title": "Use SQLite"]))
            let rp: JSONValue = .string(repo.path)
            let r = try await admin(d, p, "memory.review", ["id": b["id"] ?? .null, "action": .string("approve"), "repo": rp,
                                                            "subject": .string("Local cache")])
            #expect(r.ok && s(obj(r)["subject"]) == "local cache" && obj(r)["supersedes"] == nil, "\(r)")
            #expect(s(obj(try await admin(d, p, "memory.get", ["id": a["id"] ?? .null, "repo": rp]))["status"]) == "active")
            let c = try await context(p, t)
            #expect(c.contains("Use MySQL") && c.contains("Use SQLite"), "\(c)")
        }
    }

    @Test func paddockDeleteEvictsItsMemory() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": .string("feat"), "repo": .string(repo.path)]).ok)
            let paddock = real(repo.appendingPathComponent(".collie/paddocks/feat"))   // as git (and the paddock record) report it
            #expect(try await admin(d, p, "memory.save", ["kind": .string("decision"), "subject": .string("x"), "title": .string("X"),
                                                          "repo": .string(paddock)]).ok)
            #expect(await d.router.memory.isCached(root: paddock))
            let del = try await admin(d, p, "paddock.delete", ["name": .string("feat"), "force": .bool(true)])
            #expect(del.ok, "\(del)")
            #expect(await !d.router.memory.isCached(root: paddock))
        }
    }

    @Test func symlinkedStoreOrCacheIsRefused() async throws {
        let repo = try await makeRepo()
        let elsewhere = repo.deletingLastPathComponent().appendingPathComponent("collie-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let collie = repo.appendingPathComponent(".collie")
        try FileManager.default.createDirectory(at: collie, withIntermediateDirectories: true)
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            let args = ["kind": "decision", "subject": "db", "title": "Use Postgres"]
            for name in ["memory", "cache"] {
                let link = collie.appendingPathComponent(name)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
                let r = try await call(p, t, "memory.save", args)
                #expect(r.error?.message.contains("is a symlink") == true, "\(name): \(r)")
                #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
                try FileManager.default.removeItem(at: link)
            }
            #expect(try await call(p, t, "memory.save", args).ok)
        }
    }

    @Test func processExitEndsSession() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            #expect(try await call(p, t, "memory.save", ["kind": "decision", "subject": "pool", "title": "Postgres pool size is 20"]).ok)
            let mem = d.router.memory, id = UUID(uuidString: t.id)!
            let prompt = "postgres pool"
            #expect(await mem.relevant(for: id, cwd: repo.path, prompt: prompt).contains("Postgres pool"))
            #expect(await mem.relevant(for: id, cwd: repo.path, prompt: prompt).isEmpty)
            try await liveProcess(d, id).write(Data("exit\n".utf8))
            #expect(await waitFor(10) { await d.process(id)?.isRunning == false })
            #expect(await waitFor(10) { await !mem.relevant(for: id, cwd: repo.path, prompt: prompt).isEmpty })
        }
    }
}
