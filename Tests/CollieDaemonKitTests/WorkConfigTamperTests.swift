import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M13.3: the loop reads `collie-work.json` from the base (the committed version at the loop's start), never from the
/// working tree, and an attempt that changes the file fails. Real git in a temp repo; the loop with `LoopFakeHost`.
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func work(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func write(_ dir: URL, _ body: String) throws {
    try Data(body.utf8).write(to: dir.appendingPathComponent(ProjectWorkConfig.fileName))
}
private func head(_ dir: URL) async throws -> String {
    try await GitRunner.run(["rev-parse", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
private func gateOf(_ r: Result<ProjectWorkConfig?, ProtocolError>) -> String? {
    if case .success(let c?) = r { c.gate } else { nil }
}
private let fileA = #"{ "version": 1, "gate": "echo GATE-A", "precheck": "echo PRE-A", "areas": { "x": "echo X-A" } }"#
private let fileB = #"{ "version": 1, "gate": "echo GATE-B", "precheck": "echo PRE-B", "areas": { "x": "echo X-B" } }"#
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

@Suite(.serialized) struct WorkConfigTamperTests {
    // MARK: the base, not the tree

    @Test func theBaseWinsOverADirtyTree() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await commit(ProjectWorkConfig.fileName, fileA, in: repo)
        let base = try await head(repo)
        try write(repo, fileB)   // tracked and dirty
        #expect(gateOf(await WorkConfigFile.config(base: base, dir: repo)) == "echo GATE-A")
        #expect(gateOf(WorkConfigFile.config(root: repo)) == "echo GATE-B")   // the tree's reader still sees the tree
    }

    @Test func theBaseWinsOverANewerCommit() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await commit(ProjectWorkConfig.fileName, fileA, in: repo)
        let base = try await head(repo)
        try await commit(ProjectWorkConfig.fileName, fileB, in: repo)
        #expect(gateOf(await WorkConfigFile.config(base: base, dir: repo)) == "echo GATE-A")
    }

    @Test func absentFromTheBaseIsTodaysDefaults() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, fileB)   // untracked: not in the base
        let r = await WorkConfigFile.config(base: try await head(repo), dir: repo)
        guard case .success(nil) = r else { Issue.record("\(r)"); return }
    }

    @Test func aBaseSymlinkOrHugeFileIsRefused() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent(ProjectWorkConfig.fileName).path, withDestinationPath: "f.txt")
        _ = try await GitRunner.run(["add", "-A"], in: repo); _ = try await GitRunner.run(["commit", "-qm", "link"], in: repo)
        guard case .failure = await WorkConfigFile.config(base: try await head(repo), dir: repo) else { Issue.record("symlink read"); return }
        _ = try await GitRunner.run(["rm", "-q", ProjectWorkConfig.fileName], in: repo)
        try await commit(ProjectWorkConfig.fileName, String(repeating: " ", count: ProjectWorkConfig.maxBytes + 1) + "{}", in: repo)
        guard case .failure = await WorkConfigFile.config(base: try await head(repo), dir: repo) else { Issue.record("huge read"); return }
    }

    // MARK: work run takes the base's gate

    private struct Pad { let dir: URL; let s: Term }
    private func pad(_ d: Daemon, _ p: Paths) async throws -> Pad {
        let repo = try await makeRepo()
        let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
        #expect(try await work(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
        let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
        #expect(try await work(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
        #expect(try await work(d, p, s, "work.task.add", ["title": .string("A"), "check": .string("true")]).ok)
        return Pad(dir: repo.appendingPathComponent(".collie/paddocks/feat"), s: s)
    }
    private func card(_ d: Daemon, _ p: Paths, _ x: Pad) async throws -> String {
        #expect(try await work(d, p, x.s, "work.run", ["max": .number(3)]).ok)
        var text = ""
        if await waitFor(20, { await d.router.appCards.contains { $0.app == "work-loop" } }) {
            text = await d.router.appCards.first { $0.app == "work-loop" }?.call ?? ""
        }
        #expect(try await work(d, p, x.s, "work.stop").ok)
        return text
    }

    @Test func runReadsTheCommittedFile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, fileA, in: x.dir)
            let text = try await card(d, p, x)
            #expect(text.contains("«echo GATE-A»") && text.contains("«echo PRE-A»"), "\(text)")
        }
    }

    @Test func runIgnoresAnUntrackedFile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try write(x.dir, fileB)   // in the tree, not in the base
            let text = try await card(d, p, x)
            #expect(!text.contains("GATE-B") && !text.contains("portão") && !text.contains("pré-check"), "\(text)")
        }
    }

    // MARK: an attempt that changes the file fails

    @Test func committingAChangeFailsTheAttemptAndIsDiscarded() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        try await commit(ProjectWorkConfig.fileName, fileA, in: r.repo)
        let start = try await head(r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit(ProjectWorkConfig.fileName, fileB, in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred, "\(w.tasks)")
        #expect(w.tasks[0].lastFailure == WorkLoop.configTampered, "\(w.tasks)")
        #expect(await r.host.commands.isEmpty)   // the check did not run on it
        #expect(try await head(r.repo) == start)
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("GATE-B"))
    }

    @Test func creatingTheFileFailsToo() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 2); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try await commit("done.txt", "ok\n", in: d)
            try write(d, fileB)   // left untracked
        }))
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
        let ran = await r.host.commands
        #expect(ran == ["true"], "\(ran)")   // only the second attempt's check ran
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent(ProjectWorkConfig.fileName).path))
    }

    @Test func aTaskWhoseSpecNamesTheFileMayChangeIt() async throws {
        var t = task("a", "true"); t.spec = "spec.md"
        let r = try await LoopRig([t], tries: 1); defer { r.cleanup() }
        try await commit("spec.md", "Add an area to collie-work.json.\n", in: r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit(ProjectWorkConfig.fileName, fileB, in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
    }

    @Test func theOwnersUntrackedFileIsNotTheAttempts() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        try write(r.repo, fileB)   // there before the attempt
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try "ok\n".write(to: d.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            _ = try await GitRunner.run(["add", "done.txt"], in: d); _ = try await GitRunner.run(["commit", "-qm", "done"], in: d)
        }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
    }

    // MARK: a task's built check stays

    @Test func aBuiltCheckDoesNotFollowTheFile() async throws {
        let repo = try await makeRepo()
        try write(repo, fileA)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            #expect(try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("x")]).ok)
            try write(repo, fileB)
            let t = try #require(try await d.router.work.active(terminal: a.uuid)?.tasks.first)
            #expect(t.check == "echo X-A")
        }
    }
}
