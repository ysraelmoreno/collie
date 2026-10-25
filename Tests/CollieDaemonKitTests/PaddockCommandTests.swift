import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false) async throws -> Term {
    let r = try await admin(d, p, "admin.spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path),
                                                  "shepherd": .bool(shepherd)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func snapshot(_ d: Daemon, _ p: Paths) async throws -> WorkspaceSnapshot {
    let r = try await admin(d, p, "ui.snapshot")
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
}
private func paddockList(_ r: Response) -> [[String: JSONValue]] {
    guard case .array(let rows)? = r.result else { return [] }
    return rows.compactMap { if case .object(let o) = $0 { return o }; return nil }
}

@Suite(.serialized) struct PaddockCommandTests {
    @Test func shepherdCreatesPaddockAndSummonsIntoIt() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            let c = try await call(p, m, "paddock.create", ["name": "feat"])
            guard case .object(let o)? = c.result, case .string(let path)? = o["path"] else { Issue.record("\(c)"); return }
            #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == repo.appendingPathComponent(".collie/paddocks/feat"))   // /private/var vs /var
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).error?.code == .invalidArgs)
            let r = try await call(p, m, "summon", ["name": "dev", "preset": "shell", "paddock": "feat",
                                                     "prompt": "pwd; env | grep COLLIE_ | grep -v TOKEN"])
            guard case .object(let ro)? = r.result, case .string(let did)? = ro["id"] else { Issue.record("\(r)"); return }
            let dev = UUID(uuidString: did)!
            #expect(await waitFor(10) { await d.scrollbackText(dev).contains("COLLIE_BRANCH_NAME=collie/feat") })
            let text = await d.scrollbackText(dev)
            #expect(text.contains("\n\(path)") && text.contains("COLLIE_PADDOCK_NAME=feat") && text.contains("COLLIE_PADDOCK_PATH=\(path)"), "\(text)")
            var got = false
            while !got, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if case .paddock(let f) = e, f.name == "feat", f.createdBy?.uuidString == m.id { got = true }
            }
            #expect(got)
            // the list carries ISO-8601 dates for agents
            let rows = paddockList(try await call(p, m, "paddock.list"))
            #expect(rows.count == 1 && rows[0]["name"] == .string("feat") && rows[0]["status"] == .string("working"))
        }
    }

    @Test func adminCreateNeedsRepoAndSpawnsIntoPaddock() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": .string("x")]).error?.code == .invalidArgs)
            let c = try await admin(d, p, "paddock.create", ["name": .string("x"), "repo": .string(repo.path)])
            #expect(c.ok, "\(c)")
            let s = try await admin(d, p, "admin.spawn", ["name": .string("W"), "preset": .string("shell"), "paddock": .string("x")])
            #expect(s.ok, "\(s)")
            let snap = try await snapshot(d, p)
            let f = try #require(snap.paddocks.first)
            let w = try #require(snap.terminals.first { $0.name == "W" })
            #expect(w.paddockId == f.id && w.cwd == f.path && f.createdBy == nil)
        }
    }

    @Test func onlyCreatorShepherdLands() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m1 = try await term(d, p, "M1", cwd: repo, shepherd: true)
            let m2 = try await term(d, p, "M2", cwd: repo, shepherd: true)
            #expect(try await call(p, m1, "paddock.create", ["name": "feat"]).ok)
            let path = repo.appendingPathComponent(".collie/paddocks/feat")
            try await commit("g.txt", "two\n", in: path)
            #expect(try await call(p, m2, "paddock.land", ["name": "feat"]).error?.code == .notShepherd)
            #expect(try await call(p, m2, "paddock.delete", ["name": "feat"]).error?.code == .notShepherd)
            let r = try await admin(d, p, "paddock.land", ["name": .string("feat"), "mode": .string("squash")])
            guard case .object(let o)? = r.result, case .string? = o["commit"] else { Issue.record("\(r)"); return }
            let f = try #require(try await snapshot(d, p).paddocks.first)
            #expect(f.status == .done && f.landedAt != nil)
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("g.txt").path))
            #expect(try await call(p, m1, "paddock.delete", ["name": "feat"]).ok)
            #expect(try await snapshot(d, p).paddocks.isEmpty)
        }
    }

    @Test func shepherdCannotLandAsPR() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).ok)
            let r = try await call(p, m, "paddock.land", ["name": "feat", "mode": "pr"])
            #expect(r.error?.code == .notShepherd && r.error?.message == "pr land is user-only", "\(r)")
            #expect(try await call(p, m, "paddock.land", ["name": "feat"]).ok)   // merge is fine
        }
    }

    /// A land in flight holds the paddock: status/delete/land/summon into it are refused as busy.
    @Test func busyPaddockRefusesConcurrentOps() async throws {
        let repo = try await makeRepo()
        // holds the --no-ff merge until the test removes GATE; SENT says the land is in flight
        let sent = repo.appendingPathExtension("sent"), gate = repo.appendingPathExtension("gate")   // outside the worktree
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: gate); try? FileManager.default.removeItem(at: sent) }
        // the daemon's git runs no hooks (R4): a smudge filter on the merged-in file holds the merge instead
        let gateFilter = "sh -c 'touch \"\(sent.path)\"; while [ -e \"\(gate.path)\" ]; do sleep 0.05; done; cat'"
        let cfg = Process()
        cfg.executableURL = URL(fileURLWithPath: "/usr/bin/git"); cfg.arguments = ["-C", repo.path, "config", "filter.gate.smudge", gateFilter]
        try cfg.run(); cfg.waitUntilExit()
        try "g.txt filter=gate\n".write(to: repo.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).ok)
            try await commit("g.txt", "two\n", in: repo.appendingPathComponent(".collie/paddocks/feat"))
            async let land = call(p, m, "paddock.land", ["name": "feat"])
            #expect(await waitFor(30) { FileManager.default.fileExists(atPath: sent.path) })
            for (cmd, args) in [("paddock.status", ["name": "feat", "status": "review"]), ("paddock.delete", ["name": "feat"]),
                                ("paddock.land", ["name": "feat"]), ("summon", ["name": "w", "preset": "shell", "paddock": "feat"])] {
                let r = try await call(p, m, cmd, args)
                #expect(r.error?.message == "paddock 'feat' is busy", "\(cmd): \(r)")
            }
            try FileManager.default.removeItem(at: gate)   // let the land finish
            #expect(try await land.ok)
            #expect(try await snapshot(d, p).paddocks.first?.status == .done)
        }
    }

    /// The paddock's memory is committed (alone) and lands; the pasture's own memory files never block the land.
    @Test func landCarriesPaddockMemory() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let g = try await term(d, p, "G", cwd: repo)
            #expect(try await call(p, g, "memory.save", ["kind": "pitfall", "subject": "pasture", "title": "Pasture note"]).ok)
            #expect(try await admin(d, p, "paddock.create", ["name": .string("feat"), "repo": .string(repo.path)]).ok)
            let paddock = repo.appendingPathComponent(".collie/paddocks/feat")
            try "scratch\n".write(to: paddock.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            _ = try await GitRunner.run(["add", "f.txt"], in: paddock)   // staged by the user: must not ride along
            let f = try await term(d, p, "F", cwd: paddock)
            let saved = try await call(p, f, "memory.save", ["kind": "decision", "subject": "api", "title": "Use REST"])
            guard case .object(let o)? = saved.result, case .string(let id)? = o["id"] else { Issue.record("\(saved)"); return }
            // a staged non-memory change still blocks the land
            #expect(try await admin(d, p, "paddock.land", ["name": .string("feat")]).error?.message == "paddock has uncommitted changes")
            _ = try await GitRunner.run(["reset", "-q", "--hard", "HEAD"], in: paddock)
            let land = try await admin(d, p, "paddock.land", ["name": .string("feat")])
            #expect(land.ok, "\(land)")
            let subjects = try await GitRunner.run(["log", "--format=%s", "collie/feat"], in: repo).stdout
            #expect(subjects.hasPrefix("collie: memory\n"), "\(subjects)")
            let tracked = try await GitRunner.run(["ls-files", ".collie/memory"], in: repo).stdout
            #expect(tracked.contains("decision/api-") && !tracked.contains("pitfall/"), "\(tracked)")   // pasture's note stays uncommitted
            #expect(try String(contentsOf: repo.appendingPathComponent("f.txt"), encoding: .utf8) == "one\n")
            let list = try await call(p, g, "memory.list")
            guard case .object(let lo)? = list.result, case .array(let recs)? = lo["records"] else { Issue.record("\(list)"); return }
            #expect(recs.contains { if case .object(let r) = $0 { return r["id"] == .string(id) }; return false }, "\(recs)")
        }
    }

    @Test func paddockTerminalSetsOwnStatus() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            let out = try await term(d, p, "out", cwd: repo)
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).ok)
            #expect(try await call(p, m, "summon", ["name": "dev", "preset": "shell", "paddock": "feat"]).ok)
            let devId = try #require(try await snapshot(d, p).terminals.first { $0.name == "dev" }).id.uuidString
            let dev = Term(id: devId, token: try await tokenOf(d, devId))
            #expect(try await call(p, dev, "paddock.status", ["name": "feat", "status": "review"]).ok)
            #expect(try await snapshot(d, p).paddocks.first?.status == .review)
            #expect(try await call(p, out, "paddock.status", ["name": "feat", "status": "done"]).error?.code == .notShepherd)
            #expect(try await call(p, out, "paddock.create", ["name": "x"]).error?.code == .notShepherd)
            #expect(try await call(p, dev, "paddock.status", ["name": "feat", "status": "nope"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "paddock.status", ["name": "feat", "status": "blocked"]).ok)
            #expect(paddockList(try await call(p, out, "paddock.list")).first?["status"] == .string("blocked"))
        }
    }

    @Test func deleteRefusedWithRunningTerminals() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(p, m, "paddock.create", ["name": "feat"]).ok)
            #expect(try await call(p, m, "summon", ["name": "dev", "preset": "shell", "paddock": "feat"]).ok)
            for args in [["name": "feat"], ["name": "feat", "force": "true"]] {
                let r = try await call(p, m, "paddock.delete", args)
                #expect(r.error?.code == .invalidArgs && r.error?.message == "paddock has running terminals", "\(r)")
            }
            #expect(try await call(p, m, "dismiss", ["target": "dev"]).ok)
            // a stopped record on the paddock is moved back to the pasture
            #expect(try await admin(d, p, "admin.spawn", ["name": .string("S"), "preset": .string("custom"),
                                                          "command": .string("exit 0"), "paddock": .string("feat")]).ok)
            let sid = try #require(try await snapshot(d, p).terminals.first { $0.name == "S" }).id
            #expect(await waitFor(10) { await d.process(sid)?.isRunning == false })
            #expect(try await call(p, m, "paddock.delete", ["name": "feat", "force": "true"]).ok)
            let s = try #require(try await snapshot(d, p).terminals.first { $0.name == "S" })
            #expect(s.paddockId == nil && URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath() == repo, "\(s)")
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".collie/paddocks/feat").path))
        }
    }

    @Test func paddocksSurviveDaemonRestart() async throws {
        let repo = try await makeRepo()
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let d1 = try Daemon(config: testConfig(paths, wsId))
        try await d1.start()
        let before: [[String: JSONValue]]
        do {
            #expect(try await admin(d1, paths, "paddock.create", ["name": .string("feat"), "repo": .string(repo.path)]).ok)
            before = paddockList(try await admin(d1, paths, "paddock.list"))
        } catch { await d1.stop(); throw error }
        await d1.stop()
        let d2 = try Daemon(config: testConfig(paths, wsId))
        try await d2.start()
        do {
            #expect(!before.isEmpty)
            #expect(paddockList(try await admin(d2, paths, "paddock.list")) == before)
            #expect(try await snapshot(d2, paths).paddocks.map(\.name) == ["feat"])
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }
}
