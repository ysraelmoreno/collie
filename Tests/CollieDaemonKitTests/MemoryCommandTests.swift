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
            try await d.process(id)!.write(Data("exit\n".utf8))
            #expect(await waitFor(10) { await d.process(id)?.isRunning == false })
            #expect(await waitFor(10) { await !mem.relevant(for: id, cwd: repo.path, prompt: prompt).isEmpty })
        }
    }
}
