import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private actor Box<T: Sendable> {
    var value: T?
    func set(_ v: T) { value = v }
}

/// A paddock's worktree (the test repo), a field cut from its HEAD, a fake host and the paddock's integrator.
private struct Rig {
    let repo: URL, host: LoopFakeHost, integrators = PaddockIntegrators(), integ: LaneIntegrator, base: String, patches: URL
    init() async throws {
        repo = try await makeRepo(); host = LoopFakeHost(dir: repo)
        integ = LaneIntegrator(host: host, dir: repo)
        base = try await git(repo, "rev-parse", "HEAD")
        patches = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-fields-\(UUID().uuidString.prefix(8))")
    }
    func field(_ name: String, _ file: String, _ text: String) async throws -> Lane {
        let f = try await LaneWorktree.createField(repoRoot: repo, base: base, name: name, owner: UUID(), host: host)
        try await commit(file, text, in: f.path)
        return f
    }
    func land(_ f: Lane, gate: String? = nil, wait: Duration = .seconds(5)) async -> FieldLand.Outcome {
        await FieldLand.land(f, dir: repo, integrators: integrators, integrator: integ, host: host, gate: gate, gateTimeout: .seconds(60),
                             patches: patches, wait: wait, poll: .milliseconds(20))
    }
    func head() async throws -> String { try await git(repo, "rev-parse", "HEAD") }
}

/// F3: a field lands through the paddock's integrator: merged when clean, undone with a patch on a conflict or a broken
/// gate, and only when the paddock is free.
@Suite(.timeLimit(.minutes(3))) struct FieldLandTests {
    @Test func landsCleanField() async throws {
        let rig = try await Rig()
        let f = try await rig.field("ok", "a.txt", "a\n")
        let out = await rig.land(f, gate: "test -f a.txt")
        let head = try await rig.head()
        #expect(out == .landed(sha: head))
        #expect(head != rig.base)
        #expect(FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent("a.txt").path))
        #expect(try await git(rig.repo, "status", "--porcelain") == "")
        #expect(await rig.host.commands == ["test -f a.txt"], "the gate ran on the merged tree")
        // the same field again: already in, still landed
        #expect(await rig.land(f) == .landed(sha: head))
    }

    @Test func conflictWritesPatch() async throws {
        let rig = try await Rig()
        let f = try await rig.field("c", "f.txt", "from the field\n")
        try await commit("f.txt", "from the paddock\n", in: rig.repo)
        let before = try await rig.head()
        let out = await rig.land(f)
        guard case .conflict(let why, let patch?) = out else { Issue.record("\(out)"); return }
        #expect(why.contains("merge conflict"), "\(why)")
        #expect(try await rig.head() == before, "undone")
        #expect(try await git(rig.repo, "status", "--porcelain", "--untracked-files=no") == "")
        #expect(patch.path == rig.patches.appendingPathComponent("c-1.patch").path)
        #expect(try String(contentsOf: patch, encoding: .utf8).contains("+from the field"))
        let mode = try FileManager.default.attributesOfItem(atPath: patch.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // a second try: the next number, the first kept
        guard case .conflict(_, let second?) = await rig.land(f) else { Issue.record("no second patch"); return }
        #expect(second.lastPathComponent == "c-2.patch")
    }

    @Test func secondLandWaits() async throws {
        let rig = try await Rig()
        let f = try await rig.field("twice", "a.txt", "a\n")
        let second = Box<FieldLand.Outcome>()
        // while the first is in its gate, the same field lands again
        await rig.host.setProbe { _ in await second.set(await rig.land(f)) }
        let first = await rig.land(f, gate: "true")
        #expect(first == .landed(sha: try await rig.head()))
        #expect(await second.value == .waiting(reason: FieldLand.alreadyLanding))
        // and once it ended, a land of it runs again
        #expect(await rig.land(f) == .landed(sha: try await rig.head()))
    }

    @Test func waitsForBusyPaddock() async throws {
        let rig = try await Rig()
        let f = try await rig.field("busy", "a.txt", "a\n")
        await rig.host.setBusy("dev")
        let out = await rig.land(f, wait: .milliseconds(150))
        #expect(out == .waiting(reason: "'dev' está num turno no cercado"))
        #expect(try await rig.head() == rig.base, "nothing merged")
        await rig.host.setBusy(nil)
        // a dirty tracked file: waits too, nothing lost
        try "the owner's\n".write(to: rig.repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(await rig.land(f, wait: .milliseconds(150)) == .waiting(reason: "árvore do cercado com mudanças não commitadas"))
        #expect(try String(contentsOf: rig.repo.appendingPathComponent("f.txt"), encoding: .utf8) == "the owner's\n")
        #expect(try await rig.head() == rig.base)
    }

    @Test func shepherdWaitingDoesNotBlock() async throws {
        // the Shepherd blocked in an ask, a wait or a `field land` only waits; one more request of its own is work
        #expect(CommandRouter.fieldShepherdOnlyWaits(open: 1, waits: 1))
        #expect(CommandRouter.fieldShepherdOnlyWaits(open: 1, waits: 2))
        #expect(!CommandRouter.fieldShepherdOnlyWaits(open: 2, waits: 1))
        #expect(!CommandRouter.fieldShepherdOnlyWaits(open: 0, waits: 0))
        #expect(!CommandRouter.fieldShepherdOnlyWaits(open: 1, waits: 0))
        // the paddock frees up while the land waits: it lands then
        let rig = try await Rig()
        let f = try await rig.field("later", "a.txt", "a\n")
        await rig.host.setBusy("Pastor")
        let host = rig.host
        Task { try? await Task.sleep(for: .milliseconds(100)); await host.setBusy(nil) }
        #expect(await rig.land(f) == .landed(sha: try await rig.head()))
    }

    @Test func gateFailureIsConflict() async throws {
        let rig = try await Rig()
        let f = try await rig.field("gate", "a.txt", "a\n")
        let out = await rig.land(f, gate: "exit 3")
        guard case .conflict(let why, let patch) = out else { Issue.record("\(out)"); return }
        #expect(why.contains("gate"), "\(why)")
        #expect(patch?.lastPathComponent == "gate-1.patch")
        #expect(try await rig.head() == rig.base, "the merge was undone")
        #expect(!FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent("a.txt").path))
        // not a field: refused, nothing ran
        let lane = Lane(repoRoot: rig.repo, path: f.path, branch: "collie/lane/x", base: "")
        guard case .conflict = await rig.land(lane) else { Issue.record("a lane landed as a field"); return }
    }
}

extension FieldLandTests {
    /// Fix 3: `tip` merges that sha, never the branch's later commits.
    @Test func landsTheGivenTipOnly() async throws {
        let rig = try await Rig()
        let f = try await rig.field("t", "a.txt", "judged\n")
        let judged = try await git(f.path, "rev-parse", "HEAD")
        try await commit("b.txt", "after the check\n", in: f.path)
        let out = await FieldLand.land(f, dir: rig.repo, integrators: rig.integrators, integrator: rig.integ, host: rig.host, gate: nil,
                                       gateTimeout: .seconds(60), patches: rig.patches, wait: .seconds(5), poll: .milliseconds(20), tip: judged)
        #expect(out == .landed(sha: try await rig.head()))
        #expect(FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent("b.txt").path), "an unjudged commit went in")
    }
}
