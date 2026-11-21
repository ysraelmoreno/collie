import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func write(_ text: String, _ file: String, in dir: URL) {
    do { try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) } catch { Issue.record("write \(file): \(error)") }
}
private func read(_ file: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) }

/// The paddock's worktree (a real temporary repo), a fake host and the integrator; `lane` cuts a lane from the first
/// commit and commits one file in it.
private struct Rig {
    let repo: URL, host: LoopFakeHost, integ: LaneIntegrator, base: String, work = UUID()
    init() async throws {
        repo = try await makeRepo(); host = LoopFakeHost(dir: repo)
        integ = LaneIntegrator(host: host, dir: repo)
        base = try await git(repo, "rev-parse", "HEAD")
    }
    func lane(_ task: String, _ file: String, _ text: String) async throws -> Lane {
        let l = try await LaneWorktree.create(repoRoot: repo, base: base, work: work, task: task, host: host)
        try await commit(file, text, in: l.path)
        return l
    }
    func go(_ l: Lane, attempt: Int = 1, tries: Int = 3, gate: String?) async throws -> LaneIntegrator.Result {
        try await integ.integrate(l, title: "T \(l.branch)", attempt: attempt, tries: tries, gate: gate, gateTimeout: .seconds(60))
    }
    func head() async throws -> String { try await git(repo, "rev-parse", "HEAD") }
    func status() async throws -> String { try await git(repo, "status", "--porcelain") }
    func cleans() async -> [[String]] { await host.gits.filter { $0.contains("clean") } }
    /// M6.3: a file in the quarantine of the sweep `n`.
    func quarantined(_ file: String, _ n: Int = 1) -> String? {
        read(".git/\(LaneIntegrator.quarantineDir)/\(n)/\(file)", in: repo)
    }
}

private func isLeftDirty(_ o: LaneIntegration.Outcome) -> Bool { if case .leftDirty = o { true } else { false } }

/// M3d.3: what the gate leaves untracked in the paddock's worktree is the integrator's to remove (only that, and only
/// as the gate left it) before the next merge, so a later lane that adds the same path merges.
@Suite(.timeLimit(.minutes(3))) struct GateLeftoversTests {
    @Test func theGatesReportGoesBeforeALaneThatAddsIt() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n"), b = try await rig.lane("b", "report.txt", "from b\n")
        let ra = try await rig.go(a, gate: "echo report > report.txt")
        #expect(ra.outcome == .integrated)
        #expect(ra.left == ["report.txt"] && ra.kept.isEmpty)
        #expect(read("report.txt", in: rig.repo) == "report\n", "it stays until the next merge")
        let rb = try await rig.go(b, gate: "true")
        #expect(rb.outcome == .integrated, "\(rb.outcome)")
        #expect(rb.spared.isEmpty)
        #expect(read("report.txt", in: rig.repo) == "from b\n")
        #expect(try await rig.status() == "")
        // M6.3: moved into the quarantine (was: removed by git clean), only the gate's file, by name
        #expect(await rig.cleans().isEmpty)
        #expect(rb.moved == ["report.txt"])
        #expect(rig.quarantined("report.txt") == "report\n")
        #expect(rb.quarantine?.hasSuffix("/.git/\(LaneIntegrator.quarantineDir)/1") == true, "\(rb.quarantine ?? "nil")")
    }

    @Test func theOwnersFileInTheWayIsNeverRemovedAndTheLoopStops() async throws {
        let rig = try await Rig()
        write("mine\n", "report.txt", in: rig.repo)   // the owner's, there before any gate
        let a = try await rig.lane("a", "a.txt", "a\n"), b = try await rig.lane("b", "report.txt", "from b\n")
        // a gate that leaves nothing new: the owner's file is not its own
        #expect(try await rig.go(a, gate: "true").outcome == .integrated)
        let head = try await rig.head()
        let r = try await rig.go(b, attempt: 3, tries: 3, gate: "true")
        #expect(isLeftDirty(r.outcome), "never a retry nor a defer: \(r.outcome)")
        if case .leftDirty(let why) = r.outcome { #expect(why.contains("report.txt"), "\(why)") }
        #expect(r.kept == ["report.txt"])
        #expect(r.undo == nil && r.head == head)
        #expect(try await rig.head() == head, "nothing merged")
        #expect(read("report.txt", in: rig.repo) == "mine\n")
        #expect(await rig.cleans().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test func aGateFileTheOwnerEditedIsLeftAndNoted() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n"), b = try await rig.lane("b", "b.txt", "b\n")
        let c = try await rig.lane("c", "report.txt", "from c\n")
        #expect(try await rig.go(a, gate: "echo report > report.txt").outcome == .integrated)
        write("the owner's now\n", "report.txt", in: rig.repo)
        let rb = try await rig.go(b, gate: "true")
        #expect(rb.outcome == .integrated)
        #expect(rb.spared == ["report.txt"])
        #expect(read("report.txt", in: rig.repo) == "the owner's now\n")
        #expect(await rig.cleans().isEmpty)
        #expect(WorkLoop.sparedNote(rb.spared).contains("report.txt"))
        // from then on it is the owner's: a lane that adds it stops the loop, the file untouched
        let rc = try await rig.go(c, gate: "true")
        #expect(isLeftDirty(rc.outcome), "\(rc.outcome)")
        #expect(read("report.txt", in: rig.repo) == "the owner's now\n")
    }

    @Test func aFileTheOwnerAddedToTheIndexIsNotRemoved() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        #expect(try await rig.go(a, gate: "echo report > report.txt").outcome == .integrated)
        _ = try await git(rig.repo, "add", "report.txt")
        #expect(await rig.integ.sweep() == .init())
        #expect(read("report.txt", in: rig.repo) == "report\n")
        #expect(await rig.cleans().isEmpty)
    }

    @Test func theLoopsEndSweepsWhatTheLastGateLeft() async throws {
        let rig = try await Rig()
        write("mine\n", "loose.txt", in: rig.repo)
        let a = try await rig.lane("a", "a.txt", "a\n")
        #expect(try await rig.go(a, gate: "echo report > report.txt; mkdir -p cov; echo x > cov/lcov.info").outcome == .integrated)
        let s = await rig.integ.sweep()
        #expect(s.spared.isEmpty && s.moved == ["cov/lcov.info", "report.txt"], "\(s)")
        #expect(read("report.txt", in: rig.repo) == nil)
        #expect(read("cov/lcov.info", in: rig.repo) == nil)
        // M6.3: moved into the quarantine (was: removed)
        #expect(rig.quarantined("report.txt") == "report\n" && rig.quarantined("cov/lcov.info") == "x\n")
        #expect(read("loose.txt", in: rig.repo) == "mine\n", "the owner's never")
        #expect(await rig.integ.sweep() == .init(), "once")
    }

    /// M3c.2 preserved: a formatter that really changes a tracked file is the owner's to the integrator: nothing reset.
    @Test func aGateThatReformatsATrackedFileKeepsM3c2() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let broke = try await rig.go(a, gate: "echo junk > junk.txt; printf 'ONE\\n' > f.txt; exit 7")
        #expect(broke.outcome == .leftDirty("gate broke after the merge: gate failed (exit 7)"))
        #expect(broke.kept == ["f.txt", "junk.txt"] && broke.undo == rig.base)
        #expect(read("f.txt", in: rig.repo) == "ONE\n")
        // a tree left dirty: nothing of the gate's is taken as its own (the note said "nothing removed")
        #expect(await rig.integ.sweep() == .init())
        #expect(read("junk.txt", in: rig.repo) == "junk\n")
        #expect(await rig.cleans().isEmpty)
    }
}
