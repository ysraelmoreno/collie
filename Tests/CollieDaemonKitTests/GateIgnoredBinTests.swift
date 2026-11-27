import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// R1: a runner in a folder git ignores (`node_modules/.bin`, `.venv/bin`) that the agent rewrites is seen by no diff;
/// the loop compares those folders with what they held before the work's first attempt. Real git, the loop's fake host.
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

private let runner = "node_modules/.bin/x"
private let refused = "a tentativa alterou «\(runner)», que o portão executa"

/// An ignored `node_modules/.bin/x` that exits with `code`, written over whatever was there.
private func writeRunner(_ body: String, in d: URL) throws {
    let bin = d.appendingPathComponent("node_modules/.bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let f = bin.appendingPathComponent("x")
    try? FileManager.default.removeItem(at: f)
    try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
}

/// The repo ignores `node_modules/` and holds `runner` exiting `code` before the loop.
private func rig(_ tasks: [WorkTask], tries: Int, code: Int) async throws -> LoopRig {
    let r = try await LoopRig(tasks, tries: tries, gate: runner)
    try await commit(".gitignore", "node_modules/\n", in: r.repo)
    try writeRunner("exit \(code)", in: r.repo)
    return r
}

@Suite(.timeLimit(.minutes(3))) struct GateIgnoredBinTests {
    @Test func anAgentThatRewritesTheGatesRunnerIsRefused() async throws {
        let r = try await rig([task("a", "test -f done.txt")], tries: 1, code: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try await commit("done.txt", "ok\n", in: d)
            try writeRunner("exit 0 # passes now", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred, "\(w.tasks)")
        #expect(w.tasks[0].lastFailure == refused)
        #expect(await r.host.commands == ["test -f done.txt"], "the gate did not run the rewritten runner")
    }

    @Test func anUnchangedRunnerPasses() async throws {
        let r = try await rig([task("a", "test -f done.txt")], tries: 1, code: 0); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
        #expect(await r.host.commands == ["test -f done.txt", runner])
    }

    @Test func aSpecThatCitesNpmInstallPasses() async throws {
        var t = task("a", "test -f done.txt"); t.spec = "spec.md"
        let r = try await rig([t], tries: 1, code: 1); defer { r.cleanup() }
        try await commit("spec.md", "Run npm install, then add done.txt.\n", in: r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try await commit("done.txt", "ok\n", in: d)
            try writeRunner("exit 0 # installed", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
    }

    /// The reviewer's case: the rewrite refused on attempt 1 stays (ignored, the reset keeps it); attempt 2 compares
    /// with the work's base, not with what attempt 1 left, and is refused too.
    @Test func aRefusedRewriteIsStillSeenOnTheNextAttempt() async throws {
        let r = try await rig([task("a", "test -f done.txt")], tries: 2, code: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            try await commit("done.txt", "ok\n", in: d)
            try writeRunner("exit 0 # passes now", in: d)
        }))
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].tries == 2, "\(w.tasks)")
        #expect(w.tasks[0].lastFailure == refused)
        #expect(await r.host.commands == ["test -f done.txt", "test -f done.txt"], "the gate never ran the rewritten runner")
    }

    @Test func whatACommandRuns() {
        #expect(WorkLoop.runs("npx jest --ci", "node_modules/.bin/jest"))
        #expect(WorkLoop.runs("npm test", "node_modules/.bin/jest"))
        #expect(WorkLoop.runs(".venv/bin/python -m pytest", ".venv/bin/python"))
        #expect(!WorkLoop.runs("swift test", "node_modules/.bin/jest"))
        #expect(!WorkLoop.runs("make check", ".venv/bin/pytest"))
    }
}
