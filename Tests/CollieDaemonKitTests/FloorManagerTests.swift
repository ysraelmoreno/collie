import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func sh(_ args: [String], _ dir: URL) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args) failed: \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

func makeRepo() async throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-floor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let real = URL(fileURLWithPath: d.path).resolvingSymlinksInPath()
    _ = try await sh(["init", "-b", "main"], real)
    _ = try await sh(["config", "user.name", "T"], real)
    _ = try await sh(["config", "user.email", "t@t"], real)
    try "one\n".write(to: real.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    _ = try await sh(["add", "."], real)
    _ = try await sh(["commit", "-m", "init"], real)
    return real
}

func commit(_ file: String, _ text: String, in dir: URL) async throws {
    try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    _ = try await sh(["add", "."], dir)
    _ = try await sh(["commit", "-m", "edit \(file)"], dir)
}

@Suite struct FloorManagerTests {
    @Test func floorNameIsValidated() async throws {
        let repo = try await makeRepo()
        for bad in ["../x", "a/b", "A", "a b", String(repeating: "a", count: 41), ""] {
            await #expect(throws: ProtocolError.self) { try await FloorManager.create(name: bad, repoRoot: repo, createdBy: nil) }
        }
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".collie").path))
    }

    @Test func createMakesWorktreeAndExclude() async throws {
        let repo = try await makeRepo()
        var f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        _ = try await FloorManager.create(name: "other", repoRoot: repo, createdBy: nil)
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(f.branch == "collie/feat" && f.baseBranch == "main")
        _ = try await sh(["rev-parse", "--verify", "collie/feat"], repo)
        let ex = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(ex.components(separatedBy: ".collie/floors/").count - 1 == 1)
        let st = try await sh(["status", "--porcelain"], repo)
        #expect(st.isEmpty)
        await #expect(throws: ProtocolError.self) { try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil) }
        let rr = try await FloorManager.repoRoot(of: URL(fileURLWithPath: f.path))
        #expect(rr.resolvingSymlinksInPath().path == repo.path)
    }

    @Test(arguments: [LandMode.merge, .squash, .rebase])
    func landMergeSquashRebase(mode: LandMode) async throws {
        let repo = try await makeRepo()
        var f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        let floor = URL(fileURLWithPath: f.path)
        try await commit("a.txt", "a\n", in: floor)
        try await commit("b.txt", "b\n", in: floor)
        if mode == .rebase { try await commit("g.txt", "g\n", in: repo) }   // diverge the base
        let before = try await sh(["rev-parse", "HEAD"], repo)
        let r = try await FloorManager.land(&f, mode: mode, message: nil)
        let head = try await sh(["rev-parse", "HEAD"], repo)
        #expect(r.mode == mode && r.commit == head)
        #expect(f.status == .done && f.landedAt != nil)
        if mode == .merge { #expect(try await sh(["log", "-1", "--format=%s"], repo) == "Land floor feat") }
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path))
        let parents = try await sh(["rev-list", "--parents", "-n", "1", "HEAD"], repo).split(separator: " ").count - 1
        switch mode {
        case .merge: #expect(parents == 2)
        case .squash:
            let n = try await sh(["rev-list", "--count", "\(before)..HEAD"], repo)
            #expect(parents == 1 && n == "1")
        default:
            let m = try await sh(["rev-list", "--merges", "--count", "HEAD"], repo)
            #expect(parents == 1 && m == "0")
        }
        try await FloorManager.delete(f, force: false)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func landRefusesDirtyGround() async throws {
        let repo = try await makeRepo()
        var f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        try await commit("a.txt", "a\n", in: URL(fileURLWithPath: f.path))
        try "dirty\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let before = try await sh(["rev-parse", "main"], repo)
        await #expect(throws: ProtocolError.self) { try await FloorManager.land(&f, mode: .merge, message: nil) }
        let after = try await sh(["rev-parse", "main"], repo)
        #expect(after == before)
    }

    @Test func landRefusesDirtyFloor() async throws {
        let repo = try await makeRepo()
        var f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        try "x\n".write(to: URL(fileURLWithPath: f.path).appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        do { _ = try await FloorManager.land(&f, mode: .merge, message: nil); Issue.record("expected error") }
        catch { #expect(error.message.contains("uncommitted")) }
        await #expect(throws: ProtocolError.self) { try await FloorManager.delete(f, force: false) }
        try await FloorManager.delete(f, force: true)
    }

    @Test(arguments: [LandMode.merge, .squash, .rebase])
    func landConflictAbortsCleanly(mode: LandMode) async throws {
        let repo = try await makeRepo()
        var f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        try await commit("f.txt", "floor\n", in: URL(fileURLWithPath: f.path))
        try await commit("f.txt", "ground\n", in: repo)
        let before = try await sh(["rev-parse", "HEAD"], repo)
        do { _ = try await FloorManager.land(&f, mode: mode, message: nil); Issue.record("expected conflict") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("f.txt")) }
        #expect(f.status == .working && f.landedAt == nil)
        let s1 = try await sh(["status", "--porcelain"], repo)
        let s2 = try await sh(["status", "--porcelain"], URL(fileURLWithPath: f.path))
        let h = try await sh(["rev-parse", "HEAD"], repo)
        #expect(s1.isEmpty && s2.isEmpty && h == before)
        let gd = try await sh(["rev-parse", "--path-format=absolute", "--git-dir"], repo)
        #expect(!FileManager.default.fileExists(atPath: gd + "/MERGE_HEAD"))
    }

    @Test func gitTimeoutKills() async throws {
        let t0 = ContinuousClock.now
        do {
            _ = try await GitRunner.run(["60"], in: FileManager.default.temporaryDirectory, timeout: .seconds(1),
                                        executable: URL(fileURLWithPath: "/bin/sleep"))
            Issue.record("expected timeout")
        } catch { #expect(error.code == .timeout) }
        #expect(ContinuousClock.now - t0 < .seconds(10))   // the 1 s timeout, not the 60 s sleep
        let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); ps.arguments = ["-fx", "/bin/sleep 60"]
        ps.standardOutput = FileHandle.nullDevice
        try ps.run(); ps.waitUntilExit()
        #expect(ps.terminationStatus == 1, "sleep still running")
    }

    @Test func gitTimeoutKillsGrandchild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("collie-gc-\(UUID().uuidString)")
        let t0 = ContinuousClock.now
        do {
            _ = try await GitRunner.run(["-c", "sleep 60 & echo $! > \(pidFile.path); sleep 60"], in: FileManager.default.temporaryDirectory,
                                        timeout: .seconds(1), executable: URL(fileURLWithPath: "/bin/sh"))
            Issue.record("expected timeout")
        } catch { #expect(error.code == .timeout) }
        #expect(ContinuousClock.now - t0 < .seconds(10))   // the 1 s timeout, not the 60 s sleep
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        #expect(await waitFor(20) { kill(pid, 0) != 0 && errno == ESRCH }, "grandchild still alive")
    }

    @Test func timeoutCoversBackgroundedHolderAfterLeaderExits() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("collie-bg-\(UUID().uuidString)")
        let t0 = ContinuousClock.now
        do {
            _ = try await GitRunner.run(["-c", "sleep 600 & echo $! > \(pidFile.path)"], in: FileManager.default.temporaryDirectory,
                                        timeout: .seconds(1), executable: URL(fileURLWithPath: "/bin/sh"))
            Issue.record("expected timeout")
        } catch { #expect(error.code == .timeout) }
        #expect(ContinuousClock.now - t0 < .seconds(10))   // the 1 s timeout, not the 600 s holder
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        #expect(await waitFor(20) { kill(pid, 0) != 0 && errno == ESRCH }, "holder still alive")
    }

    @Test func deleteUnmergedFailsAtomicallyAndRetrySucceeds() async throws {
        let repo = try await makeRepo()
        let f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        try await commit("a.txt", "a\n", in: URL(fileURLWithPath: f.path))
        await #expect(throws: ProtocolError.self) { try await FloorManager.delete(f, force: false) }
        #expect(FileManager.default.fileExists(atPath: f.path))
        try FileManager.default.removeItem(atPath: f.path)   // manual removal; branch still unmerged
        try await FloorManager.delete(f, force: true)
        let b = try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/collie/feat"], in: repo)
        #expect(b.status != 0)
    }

    /// Final-review I4: a floor whose branch was deleted by hand can still be deleted.
    @Test func deleteWithBranchAlreadyGone() async throws {
        let repo = try await makeRepo()
        let f = try await FloorManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        _ = try await sh(["worktree", "remove", f.path], repo)
        _ = try await sh(["branch", "-D", f.branch], repo)
        try await FloorManager.delete(f, force: false)
    }

    /// Final-review I1: a repo-configured fsmonitor (agent-writable .git/config) is not run by the daemon's git.
    @Test func gitIgnoresRepoFsmonitor() async throws {
        let repo = try await makeRepo()
        let mark = repo.appendingPathComponent("fsmonitor-ran")
        _ = try await sh(["config", "core.fsmonitor", "touch '\(mark.path)'; false"], repo)
        _ = try await GitRunner.run(["status", "--porcelain"], in: repo)
        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }
}
