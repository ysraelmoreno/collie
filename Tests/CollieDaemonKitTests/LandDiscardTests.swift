import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// C5c: an `--auto-land` loop that stops on a land that did not integrate puts the paddock back on the commit the work
/// began on (real git): the commits go to a patch in the daemon's folder of the work, the next land does not carry
/// them, the base is never touched; a dirty tree is left alone; `landed` discards nothing; after a land, the next
/// work's start is the HEAD after that land.
@Suite(.serialized) struct LandDiscardTests {
    private static func git(_ dir: URL, _ args: String...) async throws -> String {
        try await GitRunner.run(args, in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func patches(_ host: LoopFakeHost, _ work: UUID) -> [URL] {
        let d = host.patchDir(work).appendingPathComponent(WorkLoop.discardedFolder)
        return (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
    }

    /// A paddock of `repo` (a worktree off `main`) marked a factory's, with a persona and a spec committed in it.
    private static func realPaddock(_ d: Daemon, _ repo: URL, _ name: String) async throws -> Paddock {
        var k = try await PaddockManager.create(name: name, repoRoot: repo, createdBy: nil)
        k.factory = true
        await d.router.c5cAddPaddock(k)
        let dir = URL(fileURLWithPath: k.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
        try await commit(CommandRouter.personasDir + "correcao.md", "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n", in: dir)
        try await commit("spec.md", "SPEC\n", in: dir)
        return k
    }
    /// An engine whose land, land record and base are the router's for `k`.
    private static func engine(_ d: Daemon, _ k: Paddock) async throws -> (WorkStore, LoopFakeHost, WorkLoop, () -> Void) {
        let storeDir = URL(fileURLWithPath: "/tmp/collie-c5c-\(UUID().uuidString.prefix(8))")
        let store = WorkStore(dir: storeDir), host = LoopFakeHost(dir: URL(fileURLWithPath: k.path))
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        await host.setFactory(true)
        await host.setLandRouter(d.router, k.id)
        let loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50), promptRetryWait: .zero)
        return (store, host, loop, { for u in [storeDir, host.patches, host.root] { try? FileManager.default.removeItem(at: u) } })
    }
    /// A work of the paddock with one task `t<i>`, reviewed, with the auto-land on; `previous`: its loop before (a new
    /// `work run` of the same work, the start carried as the router carries it).
    private static func work(_ store: WorkStore, _ k: Paddock, _ i: Int, same: UUID? = nil) async throws -> UUID {
        let dir = URL(fileURLWithPath: k.path)
        var id = same ?? UUID()
        if same == nil { id = try await store.start(title: "W\(i)", terminal: UUID(), paddockId: k.id, branch: k.branch).id }
        try await store.update(id) { x in
            let previous = x.loop
            x.tasks.append(WorkTask(id: "t\(i)", title: "Task t\(i)", spec: dir.appendingPathComponent("spec.md").path, check: "true"))
            var l = WorkLoopState(tries: 1, timeout: 60, tasks: ["t\(i)"]); l.review = true
            l.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60, perDay: 5)
            l.autoLand?.startHead = CommandRouter.loopStartHead(after: previous)
            x.loop = l
        }
        return id
    }

    @Test func aBaseMovedDiscardsTheCommitAndTheNextLandDoesNotCarryIt() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let k = try await Self.realPaddock(d, repo, "disc")
            let dir = URL(fileURLWithPath: k.path)
            let (store, host, loop, cleanup) = try await Self.engine(d, k)
            defer { cleanup() }
            let start = try await Self.git(dir, "rev-parse", "HEAD")
            let w1 = try await Self.work(store, k, 1)
            await host.set("w1-task-t1-t1", LoopScript(act: {
                try await commit("neg.swift", "let neg = 1\n", in: $0)
                try await commit("outro.txt", "x\n", in: repo)   // the base moves after the attempt began
            }))
            _ = await loop.run(work: w1, dir: dir)
            let x = try #require(try await store.get(w1))
            #expect(x.loop?.stopReason?.code == .landBaseMoved, "\(String(describing: x.loop?.stopReason))")
            #expect(try await Self.git(dir, "rev-parse", "HEAD") == start)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("neg.swift").path))
            let patch = try #require(Self.patches(host, w1).first)
            let text = try String(contentsOf: patch, encoding: .utf8)
            #expect(text.contains("neg.swift") && text.contains("+let neg = 1"))
            let note = try #require(x.notes.first { $0.text.contains("descartei do cercado") })
            #expect(note.text.contains("git am ") && note.text.contains(patch.lastPathComponent) && note.text.contains("neg.swift")
                    && note.text.contains(String(start.prefix(12))), "\(note.text)")
            let notices = await host.ownerNotices
            #expect(notices.last?.contains(patch.lastPathComponent) == true && notices.last?.contains("git am") == true, "\(notices)")
            // the base is the commit made on it, nothing else
            #expect(try await Self.git(repo, "log", "--format=%s", "-1", "main") == "edit outro.txt")
            try await store.update(w1) { $0.closedAt = Date() }

            let w2 = try await Self.work(store, k, 2)
            await host.set("w2-task-t2-t1", LoopScript(act: { try await commit("t2.swift", "let t = 2\n", in: $0) }))
            _ = await loop.run(work: w2, dir: dir)
            #expect(try await store.get(w2)?.loop?.stopReason?.code == .landed)
            let files = try await Self.git(repo, "log", "--name-only", "--format=", "main")
            #expect(files.contains("t2.swift") && !files.contains("neg.swift"), "\(files)")
            #expect(Self.patches(host, w2).isEmpty)
        }
    }

    /// Veto of attempt 2: after a land that integrated, the work's next run begins at the HEAD after the land; a stop
    /// that does not integrate goes back there, never to a commit from before the land (which would undo it).
    @Test func afterALandTheNextDiscardGoesBackToThePostLandHead() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let k = try await Self.realPaddock(d, repo, "post")
            let dir = URL(fileURLWithPath: k.path)
            let (store, host, loop, cleanup) = try await Self.engine(d, k)
            defer { cleanup() }
            let before = try await Self.git(dir, "rev-parse", "HEAD")
            let w = try await Self.work(store, k, 1)
            await host.set("w1-task-t1-t1", LoopScript(act: { try await commit("t1.swift", "let t = 1\n", in: $0) }))
            _ = await loop.run(work: w, dir: dir)
            let landed = try #require(try await store.get(w)?.loop)
            #expect(landed.stopReason?.code == .landed && landed.autoLand?.startHead == nil, "\(String(describing: landed.autoLand))")
            let postLand = try await Self.git(dir, "rev-parse", "HEAD")
            #expect(postLand != before)

            _ = try await Self.work(store, k, 2, same: w)
            await host.set("w1-task-t2-t1", LoopScript(act: {
                try await commit("t2.swift", "let t = 2\n", in: $0)
                try await commit("outro.txt", "x\n", in: repo)
            }))
            _ = await loop.run(work: w, dir: dir)
            let x = try #require(try await store.get(w))
            #expect(x.loop?.stopReason?.code == .landBaseMoved, "\(String(describing: x.loop?.stopReason))")
            #expect(try await Self.git(dir, "rev-parse", "HEAD") == postLand)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("t1.swift").path))
            #expect(x.loop?.autoLand?.startHead == nil, "a discard that went back leaves nothing to carry")
            // C5d: t2's commit went with the discard, so t2 is open again; t1, landed, stays done
            #expect(x.tasks.first { $0.id == "t2" }?.state == .open && x.tasks.first { $0.id == "t1" }?.state == .done)

            // a start from before the land (stale, carried by a bug): the discard keeps the commits, never undoes the land
            // (C5d: t2 reopened is not done, so the land stops on that before the base)
            _ = try await Self.work(store, k, 3, same: w)
            try await store.update(w) { $0.loop?.autoLand?.startHead = before }
            await host.set("w1-task-t3-t1", LoopScript(act: {
                try await commit("t3.swift", "let t = 3\n", in: $0)
                try await commit("outro2.txt", "y\n", in: repo)
            }))
            _ = await loop.run(work: w, dir: dir)
            let y = try #require(try await store.get(w))
            #expect(y.loop?.stopReason?.code == .landTasksNotDone, "\(String(describing: y.loop?.stopReason))")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("t1.swift").path)
                    && FileManager.default.fileExists(atPath: dir.appendingPathComponent("t3.swift").path))
            #expect(y.notes.contains { $0.text.contains("NÃO descartados") && $0.text.contains("já estão na base") }, "\(y.notes.map(\.text))")
        }
    }

    @Test func aDirtyTreeIsNotTouched() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1)
        defer { r.cleanup() }
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec; $0.loop?.review = true
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "echo x > sobra.txt", timeout: 60)
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        await r.host.setFactory(true)
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landDirty)
        #expect(try await Self.git(r.repo, "log", "--format=%s", "-1") == "edit a.swift")
        #expect(FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("sobra.txt").path))
        #expect(Self.patches(r.host, r.work).isEmpty)
        #expect(w.notes.contains { $0.text.contains("NÃO descartados") && $0.text.contains("árvore do cercado suja") })
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("NÃO descartados"), "\(notices)")
    }

    @Test func landedDiscardsNothing() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1)
        defer { r.cleanup() }
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec; $0.loop?.review = true
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60)
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        await r.host.setFactory(true)
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landed)
        #expect(FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("a.swift").path))
        #expect(Self.patches(r.host, r.work).isEmpty && !w.notes.contains { $0.text.contains("descart") })
    }

    /// C5d: a rig of two tasks with the auto-land on: `a` done with a commit, `b` deferred (its check fails), so the land
    /// stops with `landTasksNotDone`.
    private static func twoTasks() async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true"), WorkTask(id: "b", title: "Task b", check: "false")], tries: 1)
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec; $0.tasks[1].spec = spec; $0.loop?.review = true
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60)
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        await r.host.setFactory(true)
        return r
    }

    /// C5d: the discard drops the commits of a task already `done`: it goes back to `open`, the note names it and quotes
    /// the patch's path for `git am`, and the next `work run` takes it.
    @Test func aDiscardReopensTheDoneTaskWhoseCommitsWent() async throws {
        let r = try await Self.twoTasks(); defer { r.cleanup() }
        let start = try await Self.git(r.repo, "rev-parse", "HEAD")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landTasksNotDone, "\(String(describing: w.loop?.stopReason))")
        #expect(try await Self.git(r.repo, "rev-parse", "HEAD") == start)
        #expect(w.tasks[0].state == .open && w.tasks[0].evidence == nil && w.tasks[0].reviewClean == nil, "\(w.tasks[0])")
        #expect(w.tasks[1].state == .deferred)
        let patch = try #require(Self.patches(r.host, r.work).first)
        let note = try #require(w.notes.first { $0.text.contains("descartei do cercado") })
        #expect(note.text.contains("git am '") && note.text.contains(patch.lastPathComponent + "'"), "\(note.text)")
        #expect(note.text.contains("Reabertas") && note.text.contains("\"Task a\" [a]") && !note.text.contains("\"Task b\""), "\(note.text)")
        #expect(await r.host.ownerNotices.last?.contains("reabertas: \"Task a\"") == true)

        // the next run (task a only, no land) takes it again
        try await r.store.update(r.work) { $0.loop = WorkLoopState(tries: 1, timeout: 60, tasks: ["a"]) }
        #expect(await r.run() == .finished)
        let y = try await r.get()
        #expect(y.tasks[0].state == .done && FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("a.swift").path), "\(y.tasks[0])")
    }

    /// C5d: no discard (a commit of the attempt is in the base already): nothing reopened.
    @Test func noDiscardReopensNothing() async throws {
        let r = try await Self.twoTasks(); defer { r.cleanup() }
        let host = r.host
        await host.set("w-task-a-t1", LoopScript(act: {
            try await commit("a.swift", "let a = 1\n", in: $0)
            await host.setBase(try await Self.git($0, "rev-parse", "HEAD"))
        }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landTasksNotDone)
        #expect(w.tasks[0].state == .done && Self.patches(r.host, r.work).isEmpty)
        #expect(w.notes.contains { $0.text.contains("NÃO descartados") } && !w.notes.contains { $0.text.contains("[reopen]") }, "\(w.notes.map(\.text))")
    }

    @Test func theStartCarriesOverOnlyFromALoopThatDidNotLand() {
        var l = WorkLoopState(); l.autoLand = .init(gate: "true"); l.autoLand?.startHead = "abc"
        l.stopReason = .init(.landBaseMoved)
        #expect(CommandRouter.loopStartHead(after: l) == "abc")
        l.stopReason = .init(.landed)
        #expect(CommandRouter.loopStartHead(after: l) == nil)
        #expect(CommandRouter.loopStartHead(after: nil) == nil)
    }
}

private extension CommandRouter {
    func c5cAddPaddock(_ p: Paddock) { ws.paddocks.append(p) }
}
