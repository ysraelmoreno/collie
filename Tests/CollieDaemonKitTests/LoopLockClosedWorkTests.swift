import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ d: Daemon, _ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}
/// The owner says no to the loop's card (nothing runs; the paddock is free again).
private func refuseCard(_ d: Daemon, _ p: Paths) async throws {
    _ = await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } }
    let card = await d.router.appCards.first(where: { $0.app == "work-loop" })
    let c = try #require(card, "no approval card")
    let r = try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                      args: ["id": .string(c.id.uuidString), "allow": .bool(false), "always": .bool(false)]))
    #expect(r.ok, "\(r)")
}

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
private func write(_ text: String, _ file: String, in dir: URL) throws {
    let u = dir.appendingPathComponent(file)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: u, atomically: true, encoding: .utf8)
}

/// M7.2: one loop per paddock holds with a closed work's loop still running (A2); a loop empties only its own
/// quarantine; the serial loop's `discard` and gate guard read names literally (A5); a parent swapped for a symlink
/// keeps its file out of the quarantine (A6).
@Suite(.serialized, .timeLimit(.minutes(5))) struct LoopLockClosedWorkTests {
    @Test func aClosedWorksRunningLoopHoldsThePaddockUntilItEnds() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            let created = try await call(d, p, m, "paddock.create", ["name": .string("feat")])
            #expect(created.ok, "\(created)")
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
            let pad = await d.router.ws.paddocks.first { $0.name == "feat" }
            let pid = try #require(pad?.id)
            // work A, in the same paddock: closed while its loop still runs (M6.4)
            let a = try await d.router.work.start(title: "A", terminal: UUID(), paddockId: pid, branch: nil)
            try await d.router.work.update(a.id) { $0.loop = WorkLoopState(state: .running) }
            try await d.router.work.close(a.id, by: "app")
            let started = try await call(d, p, s, "work.start", ["title": .string("B")])
            let added = try await call(d, p, s, "work.task.add", ["title": .string("T"), "check": .string("true")])
            #expect(started.ok && added.ok, "\(started) \(added)")

            let refused = try await call(d, p, s, "work.run", ["max": .number(1)])
            #expect(refused.error?.code == .invalidArgs && refused.error?.message.contains("a loop is already running in paddock 'feat'") == true, "\(refused)")

            try await d.router.work.update(a.id) { $0.loop?.state = .stopped }
            let accepted = try await call(d, p, s, "work.run", ["max": .number(1)])
            #expect(accepted.ok, "\(accepted)")
            if accepted.ok { try await refuseCard(d, p) }
        }
    }

    @Test func aLoopNeverEmptiesAnotherLoopsQuarantine() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let base = try await git(repo, "rev-parse", "HEAD")
        let workA = UUID(), workB = UUID()
        let a = LaneIntegrator(host: host, dir: repo, work: workA)
        let lane = try await LaneWorktree.create(repoRoot: repo, base: base, work: workA, task: "a", host: host)
        try await commit("a.txt", "a\n", in: lane.path)
        let r = try await a.integrate(lane, title: "T a", attempt: 1, tries: 3, gate: "echo r > report.txt", gateTimeout: .seconds(60))
        #expect(r.outcome == .integrated, "\(r.outcome)")
        let s = await a.sweep()
        #expect(s.moved == ["report.txt"], "\(s)")
        let root = repo.appendingPathComponent(".git/\(LaneIntegrator.quarantineDir)")
        let boxA = root.appendingPathComponent("1/report.txt")
        #expect(FileManager.default.fileExists(atPath: boxA.path))
        // an unmarked box (an older daemon's): nobody's to empty
        try write("old\n", "9/x.txt", in: root)

        await LaneIntegrator(host: host, dir: repo, work: workB).clearQuarantine()
        await LaneIntegrator(host: host, dir: repo).clearQuarantine()
        #expect(FileManager.default.fileExists(atPath: boxA.path), "B's loop leaves A's box")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("9/x.txt").path), "no mark: not touched")

        await LaneIntegrator(host: host, dir: repo, work: workA).clearQuarantine()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1").path), "A's next loop empties its own")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1.work").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("9/x.txt").path))
    }

    @Test func aParentSwappedForASymlinkKeepsTheOutsideFileWhereItIs() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let base = try await git(repo, "rev-parse", "HEAD")
        let integ = LaneIntegrator(host: host, dir: repo, work: UUID())
        let lane = try await LaneWorktree.create(repoRoot: repo, base: base, work: UUID(), task: "a", host: host)
        try await commit("a.txt", "a\n", in: lane.path)
        let r = try await integ.integrate(lane, title: "T a", attempt: 1, tries: 3, gate: "mkdir -p out; echo g > out/b.txt", gateTimeout: .seconds(60))
        #expect(r.left == ["out/b.txt"], "\(r.left)")
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("g\n", "b.txt", in: outside)   // same content: the hash taken before the swap still matches
        let dir = repo.appendingPathComponent("out"), target = outside
        // right after the sweep hashes the file, `out/` becomes a symlink to a folder outside the tree
        await host.setGitProbe { args in
            guard args.contains("hash-object") else { return }
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createSymbolicLink(at: dir, withDestinationURL: target)
        }
        let s = await integ.sweep()
        #expect(s.moved.isEmpty && s.spared == ["out/b.txt"], "\(s)")
        #expect((try? String(contentsOf: outside.appendingPathComponent("b.txt"), encoding: .utf8)) == "g\n", "the outside file stays")
        #expect(LaneIntegrator.inside(repo.appendingPathComponent("a/b"), repo))
        #expect(!LaneIntegrator.inside(dir.appendingPathComponent("b.txt"), repo))
    }

    @Test func discardKeepsTheOwnersGlobNamedFileLiterally() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "false")], tries: 1); defer { r.cleanup() }
        try write("mine\n", "[x].txt", in: r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { d in try "agent\n".write(to: d.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8) }))
        _ = await r.run()
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("b/x.txt") && !patch.contains("[x].txt"), "\(patch)")
        #expect((try? String(contentsOf: r.repo.appendingPathComponent("[x].txt"), encoding: .utf8)) == "mine\n")
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("x.txt").path))
        let resets = await r.host.gits.filter { $0.contains("reset") && $0.contains("[x].txt") }
        #expect(!resets.isEmpty && resets.allSatisfy { $0.first == "--literal-pathspecs" }, "\(resets)")
    }

    @Test func aGateFileWithANewlineInItsNameIsGuarded() async throws {
        let name = "new\nline.sh"
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")], tries: 1,
                                  gate: "cat '\(name)' > /dev/null"); defer { r.cleanup() }
        try await commit(name, "echo ok\n", in: r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try "echo changed\n".write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try await commit("done.txt", "ok\n", in: d)
        }))
        _ = await r.run()
        let w = try await r.get()
        #expect(w.tasks[0].state != .done)
        #expect(w.notes.contains { $0.text.contains("que o portão executa") }, "\(w.notes.map(\.text))")
    }
}
