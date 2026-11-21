import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// Counts arrivals; `wait(for:)` returns once `n` came, or when its task is cancelled (M3c.1: a lane that never comes
/// turns the suite's `.timeLimit` into a failure, not a hang). No clock. Shared by the loop's parallel suites.
actor Arrivals {
    private var count = 0, waiters: [UUID: (n: Int, c: CheckedContinuation<Void, Never>)] = [:]
    func hit() {
        count += 1
        for (id, w) in waiters where w.n <= count { waiters[id] = nil; w.c.resume() }
    }
    func wait(for n: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if count >= n || Task.isCancelled { c.resume() } else { waiters[id] = (n, c) }
            }
        } onCancel: { Task { await self.drop(id) } }
    }
    private func drop(_ id: UUID) { waiters.removeValue(forKey: id)?.c.resume() }
}

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// M3c.1: a repository's lanes are made and removed one at a time; an `add` that met a half-made worktree is tried once more.
@Suite(.timeLimit(.minutes(3))) struct LaneCreateSerialTests {
    @Test func fourCreatesAtOnceAreAllBornTwentyTimesOver() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        defer { try? FileManager.default.removeItem(at: repo) }
        let sha = try await git(repo, "rev-parse", "HEAD")
        for round in 0..<20 {
            let work = UUID()
            let lanes = try await withThrowingTaskGroup(of: Lane.self) { g in
                for t in ["a", "b", "c", "d"] {
                    g.addTask { try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: t, host: host) }
                }
                return try await g.reduce(into: [Lane]()) { $0.append($1) }
            }
            #expect(lanes.count == 4, "round \(round)")
            for l in lanes { #expect(try await git(l.path, "rev-parse", "HEAD") == sha, "round \(round) \(l.branch)") }
            try await withThrowingTaskGroup(of: Void.self) { g in
                for l in lanes { g.addTask { try await LaneWorktree.remove(l, host: host) } }
                try await g.waitForAll()
            }
        }
        #expect(await host.maxInFlight == 1, "the lanes' git never ran two at once")
        #expect(try await git(repo, "for-each-ref", "refs/heads/collie/lane/").isEmpty)
    }

    @Test func createAndRemoveAtOnceDoNotTrip() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        defer { try? FileManager.default.removeItem(at: repo) }
        let sha = try await git(repo, "rev-parse", "HEAD"), work = UUID()
        let old = try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: "old", host: host)
        let made = try await withThrowingTaskGroup(of: Lane?.self) { g in
            g.addTask { try await LaneWorktree.remove(old, host: host); return nil }
            for t in ["x", "y"] { g.addTask { try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: t, host: host) } }
            return try await g.reduce(into: [Lane]()) { if let l = $1 { $0.append(l) } }
        }
        #expect(await host.maxInFlight == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path.path))
        let refs = try await git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/collie/lane/")
        #expect(Set(refs.split(separator: "\n").map(String.init)) == Set(made.map(\.branch)) && made.count == 2)
        for l in made { #expect(try await git(l.path, "rev-parse", "HEAD") == sha) }
    }

    @Test func theCommondirRaceIsTriedOnceMore() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        defer { try? FileManager.default.removeItem(at: repo) }
        let sha = try await git(repo, "rev-parse", "HEAD")
        // the failed `add` leaves its branch and folder behind, as git does when it dies after making them
        await host.setFault(["worktree", "add"], "fatal: failed to read .git/worktrees/lane-x/commondir: Undefined error: 0")
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: host)
        #expect(await host.gits.filter { $0.starts(with: ["worktree", "add"]) }.count == 2)
        #expect(try await git(lane.path, "rev-parse", "HEAD") == sha)
        #expect(try await git(lane.path, "symbolic-ref", "--short", "HEAD") == lane.branch)
    }

    @Test func anotherAddErrorIsNotTriedAgain() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        defer { try? FileManager.default.removeItem(at: repo) }
        let sha = try await git(repo, "rev-parse", "HEAD")
        await host.setFault(["worktree", "add"], "fatal: something else")
        await #expect(throws: ProtocolError.self) {
            _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: host)
        }
        #expect(await host.gits.filter { $0.starts(with: ["worktree", "add"]) }.count == 1)
    }

    @Test func aCancellableWaitReturnsOnCancel() async {
        let never = Arrivals(), inside = Arrivals()
        let t = Task { await inside.hit(); await never.wait(for: 1) }
        await inside.wait(for: 1)
        t.cancel()
        await t.value   // before M3c.1 this never returned
        // already cancelled before it waits: returns at once
        let pre = Task { withUnsafeCurrentTask { $0?.cancel() }; await never.wait(for: 5) }
        await pre.value
    }
}
