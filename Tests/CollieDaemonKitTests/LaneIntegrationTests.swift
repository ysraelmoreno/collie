import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private actor Log {
    var items: [String] = [], second: Task<LaneIntegrator.Result?, Never>?
    func add(_ s: String) { items.append(s) }
    func set(_ t: Task<LaneIntegrator.Result?, Never>) { second = t }
}

/// A repo (the paddock's worktree), a fake host and the integrator; `lane` cuts a lane from the repo's first commit
/// and commits one file in it.
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
    func go(_ l: Lane, _ title: String, attempt: Int = 1, tries: Int = 3, gate: String? = nil) async throws -> LaneIntegrator.Result {
        try await integ.integrate(l, title: title, attempt: attempt, tries: tries, gate: gate, gateTimeout: .seconds(60))
    }
    func head() async throws -> String { try await git(repo, "rev-parse", "HEAD") }
    func status() async throws -> String { try await git(repo, "status", "--porcelain") }
    func merges() async -> Int { await host.gits.filter { $0.first == "merge" && $0.contains("--no-ff") }.count }
}

private func isRetry(_ o: LaneIntegration.Outcome) -> Bool { if case .retryFromNewBase = o { true } else { false } }
private func isDefer(_ o: LaneIntegration.Outcome) -> Bool { if case .defer = o { true } else { false } }
private func isWait(_ o: LaneIntegration.Outcome) -> Bool { if case .wait = o { true } else { false } }

/// M3.4: the pure decision in a table, and the integrator in temporary git repositories.
@Suite(.timeLimit(.minutes(3))) struct LaneIntegrationTests {
    typealias F = LaneIntegration.Facts

    @Test func decideTable() {
        func f(_ m: LaneIntegration.Merge, _ g: LaneIntegration.Gate, clean: Bool = true, others: String? = nil, _ attempt: Int = 1, _ tries: Int = 3) -> LaneIntegration.Outcome {
            LaneIntegration.decide(F(mergeResult: m, gateAfterMerge: g, treeClean: clean, othersWorking: others, attempt: attempt, tries: tries))
        }
        #expect(f(.clean, .passed) == .integrated)
        #expect(f(.clean, .notRun) == .integrated, "no gate")
        #expect(f(.clean, .passed, 3, 3) == .integrated)
        #expect(f(.noop, .notRun) == .noop)
        #expect(isRetry(f(.conflict, .notRun, 1, 3)))
        #expect(isRetry(f(.conflict, .notRun, 2, 3)))
        #expect(isDefer(f(.conflict, .notRun, 3, 3)))
        #expect(isDefer(f(.conflict, .notRun, 1, 1)))
        #expect(isRetry(f(.clean, .failed, 1, 3)))
        #expect(isDefer(f(.clean, .failed, 3, 3)))
        // a dirty tree or another terminal working: wait, never defer, whatever else is true
        for m in [LaneIntegration.Merge.clean, .conflict, .noop] {
            for g in [LaneIntegration.Gate.passed, .failed, .notRun] {
                for (attempt, tries) in [(1, 3), (3, 3)] {
                    #expect(isWait(f(m, g, clean: false, attempt, tries)))
                    #expect(isWait(f(m, g, others: "Rex", attempt, tries)))
                    #expect(isWait(f(m, g, clean: false, others: "Rex", attempt, tries)))
                }
            }
        }
        #expect(f(.noop, .notRun, others: "Rex") == .wait("'Rex' is working in the paddock's worktree"))
        // the reason carries git's or the gate's words
        let d = LaneIntegration.decide(F(mergeResult: .clean, gateAfterMerge: .failed, treeClean: true, attempt: 1, tries: 2, detail: "gate failed (exit 1)"))
        #expect(d == .retryFromNewBase("gate broke after the merge: gate failed (exit 1)"))
    }

    @Test func twoLanesOnDifferentFilesIntegrateInOrder() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n"), b = try await rig.lane("b", "b.txt", "b\n")
        let ra = try await rig.go(a, "Tarefa A", gate: "test -f a.txt")
        #expect(ra.outcome == .integrated)
        #expect(ra.head == (try await rig.head()))
        #expect(ra.head != rig.base)
        let rb = try await rig.go(b, "Tarefa B", gate: "test -f a.txt && test -f b.txt")
        #expect(rb.outcome == .integrated)
        #expect(rb.head == (try await rig.head()))
        #expect(try await git(rig.repo, "log", "--first-parent", "--format=%s", "-2") == "merge: Tarefa B\nmerge: Tarefa A")
        #expect(try await git(rig.repo, "rev-parse", "HEAD^1") == ra.head, "the second merged onto the first's HEAD")
        #expect(try await rig.status() == "")
        #expect(try await git(rig.repo, "symbolic-ref", "--short", "HEAD") == "main")
        // the same lane again: nothing to merge
        #expect(try await rig.go(a, "Tarefa A").outcome == .noop)
        #expect(try await rig.head() == rb.head)
        #expect(!(await rig.host.gits).contains { $0.contains("push") })
    }

    @Test func conflictIsUndoneAndTheTreeIsExactlyTheHeadOfBefore() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "f.txt", "from a\n"), b = try await rig.lane("b", "f.txt", "from b\n")
        #expect(try await rig.go(a, "A").outcome == .integrated)
        try "mine\n".write(to: rig.repo.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)   // the owner's
        let head = try await rig.head(), status = try await rig.status()
        let r = try await rig.go(b, "B", attempt: 1, tries: 3)
        #expect(isRetry(r.outcome), "\(r.outcome)")
        #expect(r.head == head)
        #expect(try await rig.head() == head)
        #expect(try await rig.status() == status)
        #expect(!FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent(".git/MERGE_HEAD").path))
        #expect(try String(contentsOf: rig.repo.appendingPathComponent("f.txt"), encoding: .utf8) == "from a\n")
        // on the last try: deferred, and undone just the same
        let last = try await rig.go(b, "B", attempt: 3, tries: 3)
        #expect(isDefer(last.outcome), "\(last.outcome)")
        #expect(try await rig.head() == head)
        #expect(try await rig.status() == status)
        #expect(try await git(b.path, "log", "-1", "--format=%s") == "edit f.txt", "the lane's branch is untouched")
    }

    @Test func gateBrokenAfterTheMergeUndoesIt() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let r = try await rig.go(a, "A", gate: "echo broke; exit 7")
        #expect(r.outcome == .retryFromNewBase("gate broke after the merge: gate failed (exit 7)"))
        #expect(r.output.contains("broke"))
        #expect(r.head == rig.base)
        #expect(try await rig.head() == rig.base)
        #expect(try await rig.status() == "")
        #expect(!FileManager.default.fileExists(atPath: rig.repo.appendingPathComponent("a.txt").path))
        #expect(isDefer(try await rig.go(a, "A", attempt: 2, tries: 2, gate: "false").outcome))
        #expect(try await rig.head() == rig.base)
        // a gate that commits does not pass either
        let moved = try await rig.go(a, "A", gate: "git commit -q --allow-empty -m sneaky")
        #expect(moved.outcome == .retryFromNewBase("gate broke after the merge: gate moved HEAD"))
        #expect(try await rig.head() == rig.base)
        // M3b.2: what a gate leaves in the tree cannot be told from the owner's edits meanwhile: it stays, by name
        // (`LaneIntegratorRaceTests`)
        let ok = try await rig.go(a, "A", gate: "echo junk > junk.txt; echo more >> f.txt")
        #expect(ok.outcome == .integrated)
        #expect(ok.kept == ["f.txt", "junk.txt"])
        #expect(try await git(rig.repo, "log", "-1", "--format=%s") == "merge: A")
    }

    @Test func dirtyTreeOrAnotherTerminalWaitsAndTouchesNothing() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        try "wip\n".write(to: rig.repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let dirty = try await rig.go(a, "A", attempt: 3, tries: 3, gate: "true")
        #expect(isWait(dirty.outcome), "\(dirty.outcome)")
        #expect(try String(contentsOf: rig.repo.appendingPathComponent("f.txt"), encoding: .utf8) == "wip\n")
        _ = try await git(rig.repo, "checkout", "-q", "f.txt")
        await rig.host.setBusy("Rex")
        let busy = try await rig.go(a, "A", attempt: 3, tries: 3, gate: "true")
        #expect(busy.outcome == .wait("'Rex' is working in the paddock's worktree"))
        #expect(await rig.merges() == 0)
        #expect(await rig.host.checks == 0)
        #expect(try await rig.head() == rig.base)
        await rig.host.setBusy(nil)
        #expect(try await rig.go(a, "A", gate: "true").outcome == .integrated)
    }

    @Test func mergeMessageIsTreatedLikeANote() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        #expect(try await rig.go(a, "\u{1B}[31mTarefa\u{1B}[0m\nX").outcome == .integrated)
        #expect(try await git(rig.repo, "log", "-1", "--format=%B") == "merge: Tarefa X")
    }

    @Test func onlyALaneBranchIsMerged() async throws {
        let rig = try await Rig()
        _ = try await git(rig.repo, "branch", "feature")
        await #expect(throws: ProtocolError.self) {
            _ = try await rig.go(Lane(repoRoot: rig.repo, path: rig.repo, branch: "feature", base: rig.base), "X")
        }
        #expect((await rig.host.gits).isEmpty)
    }

    /// Two integrations asked at the same time: the second is asked while the first's gate runs, and its merge only
    /// starts after the first one returned.
    @Test func twoIntegrationsAtOnceAreSerialized() async throws {
        let rig = try await Rig(), log = Log()
        let a = try await rig.lane("a", "a.txt", "a\n"), b = try await rig.lane("b", "b.txt", "b\n")
        await rig.host.setProbe { command in
            if command.hasSuffix("# A") {
                await log.set(Task { try? await rig.go(b, "B", gate: "true # B") })
                // until the second one is in the queue (M3b.6: a continuation; without a queue the suite's time limit ends it)
                await rig.integ.untilWaiting(1)
                await log.add("waiting \(await rig.integ.waiting)")
            }
            await log.add("gate \(command.suffix(1)) merges \(await rig.merges())")
        }
        let ra = try await rig.go(a, "A", gate: "true # A")
        let rb = await log.second?.value
        #expect(ra.outcome == .integrated)
        #expect(rb?.outcome == .integrated)
        #expect(await log.items == ["waiting 1", "gate A merges 1", "gate B merges 2"])
        #expect(try await git(rig.repo, "log", "--first-parent", "--format=%s", "-2") == "merge: B\nmerge: A")
        #expect(rb?.head == (try await rig.head()))
        #expect(await rig.integ.waiting == 0)
    }
}
