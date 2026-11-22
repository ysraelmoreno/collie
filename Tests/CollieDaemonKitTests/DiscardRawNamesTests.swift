import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

// M9.2 (rev-onda78 B3-B6): `discard` keeps the owner's untracked files whatever their names; `work.history` lists a
// work with only notes; `work stop` reaches the loop of a closed work; a history page with no paddock is the app's only.

private struct Term { var id: String; var name: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, paddock: String? = nil) async throws -> Term {
    var args = ["name": name, "preset": "shell", "cwd": cwd.path]
    if let paddock { args["paddock"] = paddock }
    let r = try await admin(d, p, "admin.spawn", args)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
private func ids(_ r: Response) -> [String] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0, case .string(let id)? = o["id"] { id } else { nil } }
}

/// The test's seam into the router's loops (the actor's own state, set and read from inside it).
extension CommandRouter {
    func plantLoop(_ id: UUID, _ engine: WorkLoop) { workLoops[id] = (engine, Task {}, false) }
    func loopStopping(_ id: UUID) -> Bool? { workLoops[id]?.stopping }
    func unplantLoop(_ id: UUID) { workLoops[id] = nil }
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct DiscardRawNamesTests {
    /// B3, in real git: names with a space at an end or a newline, untracked before the attempt, survive its discard.
    @Test func discardKeepsTheOwnersFilesWithSpacesAndNewlinesInTheirNames() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "false")], tries: 1); defer { r.cleanup() }
        let names = [" a.txt", "b.txt ", "new\nline.txt"]
        for n in names { try "mine \(n)\n".write(to: r.repo.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        await r.host.set("w-task-a-t1", LoopScript(act: { d in try "agent\n".write(to: d.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8) }))
        _ = await r.run()
        for n in names {
            let text = try? String(contentsOf: r.repo.appendingPathComponent(n), encoding: .utf8)
            #expect(text == "mine \(n)\n", "«\(n)» was lost")
        }
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("x.txt").path), "the attempt's file goes")
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("b/x.txt") && !patch.contains("a.txt") && !patch.contains("line.txt"), "\(patch)")
    }

    /// B4: the real rule (`listed`), the one `work.history` and the app's fake both use.
    @Test func aWorkWithOnlyNotesIsListed() {
        #expect(WorkArchive(id: "n", notes: ["investiguei X"]).listed)
        #expect(!WorkArchive(id: "e").listed, "an attempt's ghost work (nothing at all) stays out")
    }

    /// B5: the terminal's closed work whose loop still runs is stopped by `work stop`, once.
    @Test func workStopReachesAClosedWorksRunningLoop() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let s = try await term(d, p, "S", cwd: repo), o = try await term(d, p, "O", cwd: repo)
            let started = try await call(p, s, "work.start", ["title": "A"])
            guard case .string(let wid)? = obj(started)["id"], let id = UUID(uuidString: wid) else { Issue.record("\(started)"); return }
            try await d.router.work.update(id) { $0.loop = WorkLoopState(state: .running) }
            try await d.router.work.close(id, by: "app")
            let none = try await call(p, s, "work.stop")
            #expect(none.error?.code == .invalidArgs, "no loop alive: \(none)")

            let engine = WorkLoop(store: d.router.work, host: LoopFakeHost(dir: repo))
            await d.router.plantLoop(id, engine)
            let other = try await call(p, o, "work.stop")
            #expect(other.error?.code == .invalidArgs, "another terminal's loop: \(other)")
            let stopped = try await call(p, s, "work.stop")
            #expect(stopped.ok && obj(stopped)["state"] == .string("stopped"), "\(stopped)")
            let asked = await engine.stopping.contains(id), marked = await d.router.loopStopping(id)
            #expect(asked && marked == true)
            let again = try await call(p, s, "work.stop")
            #expect(again.error?.code == .invalidArgs, "asked once already: \(again)")
            await d.router.unplantLoop(id)
        }
    }

    /// B6: a history page with no paddock (before M7.1) is the app's only, and `artifact.folders` names no page the
    /// caller cannot see.
    @Test func aHistoryPageWithNoPaddockIsTheAppsOnly() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": "x", "repo": repo.path]).ok)
            let tx = try await term(d, p, "TX", cwd: repo.appendingPathComponent(".collie/paddocks/x"), paddock: "x")
            let tz = try await term(d, p, "TZ", cwd: repo)   // the pasture: no paddock, like the page
            func detail(_ t: Term) async throws -> String {
                let s = try await admin(d, p, "work.start", ["terminal": t.name, "title": "W \(t.name)"])
                guard case .string(let wid)? = obj(s)["id"] else { throw ProtocolError(code: .internal, message: "\(s)") }
                #expect(try await admin(d, p, "work.done", ["terminal": t.name]).ok)
                let a = try await admin(d, p, "artifact.add", ["html": "<h1>\(t.name)</h1>", "source": "history-\(wid)", "title": "W"])
                guard case .string(let aid)? = obj(a)["id"] else { throw ProtocolError(code: .internal, message: "\(a)") }
                return aid
            }
            let none = try await detail(tz), inX = try await detail(tx)
            let rec = try await d.router.artifacts.get(try #require(UUID(uuidString: none)))
            #expect(rec.paddockId == nil)

            let lz = try await call(p, tz, "artifact.list")
            #expect(lz.ok && !ids(lz).contains(none) && !ids(lz).contains(inX), "\(lz)")
            let gz = try await call(p, tz, "artifact.get", ["id": none])
            #expect(gz.error?.code == .notFound, "\(gz)")
            #expect(!ids(try await call(p, tx, "artifact.list")).contains(none))
            #expect(ids(try await admin(d, p, "artifact.list")).contains(none))

            let fz = "\(try await call(p, tz, "artifact.folders"))", fx = "\(try await call(p, tx, "artifact.folders"))"
            let fa = "\(try await admin(d, p, "artifact.folders"))"
            #expect(!fz.contains(none) && !fz.contains(inX), "\(fz)")
            #expect(!fx.contains(none) && fx.contains(inX), "\(fx)")
            #expect(fa.contains(none) && fa.contains(inX), "\(fa)")
        }
    }
}
