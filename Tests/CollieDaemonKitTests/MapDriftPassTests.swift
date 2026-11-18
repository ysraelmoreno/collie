import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Item 7 in the lifecycle pass: anchor, measure, contest (never archive on its own), re-anchor.
@Suite(.serialized) struct MapDriftPassTests {
    private func run(available: Bool = true, _ body: (Daemon, RepoMemory, URL) async throws -> Void) async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        defer { try? FileManager.default.removeItem(at: repo) }
        fake.gated = true
        if !available { fake.avail = .unavailable("sem claude") }
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, _ in   // live git facts
            try await body(d, await d.router.memory.repo(for: repo.path), repo)
            fake.open()
        }
    }
    private func map(_ path: String = "f.txt", body: String = "f.txt guarda a lista de coisas") -> MemoryRecord {
        MemoryRecord(kind: .map, subject: "mapa \(path)", title: "Mapa de \(path)", body: body, path: path, createdAt: Date())
    }
    private func put(_ s: RepoMemory, _ r: MemoryRecord) async throws { try await s.run { try $0.store.write(r) } }
    private func head(_ repo: URL) async throws -> String {
        try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func lines(_ n: Int, _ tag: String) -> String { (0..<n).map { "\(tag)\($0)\n" }.joined() }
    private func drift(_ e: LifecycleEntry?) -> LifecycleFlag? { e?.flags.first { $0.session == "claim-check" && $0.reason.hasPrefix("mapDrift") } }

    @Test func anchorsAtHeadThenContestsPastThreshold() async throws {
        try await run { d, store, repo in
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            let h0 = try await head(repo)
            let e0 = await lc.entry(r.id)
            #expect(e0?.mapAnchor(for: LifecycleRules.textHash(r), store: store.key)?.commit == h0)
            #expect(e0?.contestedNow == false)
            try await commit("f.txt", lines(60, "novo"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            let e1 = await lc.entry(r.id)
            #expect(e1?.contestedNow == true)
            let f = try #require(drift(e1))
            #expect(f.verdict == .outdated && f.reason.contains("f.txt +60 −1 linhas desde \(h0.prefix(8))"))
            #expect(f.reason.contains("commits: "))
        }
    }

    @Test func belowThresholdOnlyMarksChecked() async throws {
        try await run { d, store, repo in
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            try await commit("f.txt", "one\n" + lines(10, "x"), in: repo)
            let t1 = t0.addingTimeInterval(86_400)
            await d.router.lifecyclePass(store, now: t1)
            let e = await lc.entry(r.id)
            #expect(e?.contestedNow == false && drift(e) == nil)
            #expect(e?.mapCheckedAt == t1)
        }
    }

    /// No curator: contested, still active, and after 14 days it asks the user. Never archived by the drift alone.
    @Test func noCuratorNeverArchivesAsksAfterFourteenDays() async throws {
        try await run(available: false) { d, store, repo in
            let r = map(), t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            try await commit("f.txt", lines(80, "z"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            #expect(await d.router.memory.lifecycle.entry(r.id)?.contestedNow == true)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(16 * 86_400))
            let st = try await store.run { $0.store.all().records.first { $0.id == r.id }?.status }
            #expect(st == .active)
            #expect(await d.router.digest.since(.distantPast).contains { $0.action == "ask" && $0.before.contains { $0.id == r.id } })
            #expect(!(await d.router.digest.since(.distantPast).contains { $0.action == "aposentado" }))
        }
    }

    /// A valid re-check (or the user keeping it) after the anchor: re-anchored at HEAD, the old drift no longer counts.
    @Test func keptAfterAnchorReanchors() async throws {
        try await run { d, store, repo in
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            try await commit("f.txt", lines(60, "novo"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            await lc.update(r.id, now: t0) { $0.flags = []; $0.contestedNow = false; $0.recheckedAt = t0.addingTimeInterval(2 * 86_400) }
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(3 * 86_400))
            let e = await lc.entry(r.id)
            #expect(e?.mapAnchor(for: LifecycleRules.textHash(r), store: store.key)?.commit == (try await head(repo)))
            #expect(e?.contestedNow == false)
        }
    }

    @Test func editedTextGetsItsOwnAnchorAndGoneAnchorIsReplaced() async throws {
        try await run { d, store, repo in
            var r = map(), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            let old = LifecycleRules.textHash(r)
            r.body = "f.txt agora guarda outra coisa"; r.updatedAt = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            let e = await lc.entry(r.id)
            #expect(e?.mapAnchors?.count == 2 && e?.mapAnchor(for: old, store: store.key) != nil && e?.mapAnchor(for: LifecycleRules.textHash(r), store: store.key) != nil)
            let now = LifecycleRules.textHash(r), lost = String(repeating: "ab", count: 20)
            await lc.update(r.id, now: t0) { $0.setMapAnchor(MapAnchor(textHash: now, commit: lost, at: t0, store: store.key)) }
            try await commit("f.txt", lines(90, "w"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(2 * 86_400))
            let e2 = await lc.entry(r.id)
            #expect(e2?.mapAnchor(for: now, store: store.key)?.commit == (try await head(repo)))   // gone anchor: HEAD, nothing judged
            #expect(e2?.contestedNow == false)
        }
    }

    /// Nothing written to the user's repo: the pass reads git only (the memory files are the test's own writes).
    @Test func passLeavesTheRepoAsItWas() async throws {
        try await run { d, store, repo in
            try await put(store, map())
            let before = try await GitRunner.run(["status", "--porcelain", "--ignored"], in: repo).stdout
            await d.router.lifecyclePass(store, now: Date())
            await d.router.lifecyclePass(store, now: Date().addingTimeInterval(86_400))
            #expect(try await GitRunner.run(["status", "--porcelain", "--ignored"], in: repo).stdout == before)
        }
    }

    // MARK: the curator's side (the real verify job, run by hand; MemoryVerify untouched)

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var _input = ""
        var input: String { get { lock.withLock { _input } } set { lock.withLock { _input = newValue } } }
    }
    /// A drift-contested map and the verify job `enqueueVerify` would queue for it (claim checks pass: no facts).
    private func driftJob(_ d: Daemon, _ store: RepoMemory, _ repo: URL, _ r: MemoryRecord, t0: Date) async throws -> CuratorJob {
        await d.router.lifecyclePass(store, now: t0)
        try await commit("f.txt", lines(60, "novo"), in: repo)
        await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
        let e = try #require(await d.router.memory.lifecycle.entry(r.id))
        #expect(e.contestedNow)
        #expect(await ClaimChecks.check(r, facts: GitFactsLive(root: repo)).isEmpty)   // so no-model never archives it
        return CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: MemoryVerify.payload(memory: r, flags: e.flags, facts: []),
                          dedupe: "", createdAt: Date(), attempts: 0)
    }

    /// The curator reads the drift (numbers and commit subjects, inside the data marks); "valid" clears the contest and
    /// the next pass re-anchors at HEAD, so the same drift never contests it again.
    @Test func curatorSeesDriftValidClearsAndReanchors() async throws {
        try await run(available: false) { d, store, repo in
            let r = map(), t0 = Date().addingTimeInterval(-60), seen = Seen()
            try await put(store, r)
            let job = try await driftJob(d, store, repo, r, t0: t0)
            try await d.router.runVerifyJob(job) { c in
                seen.input = c.input
                return CuratorOutput(json: .object(["ops": .array([])]), inputTokens: 1, outputTokens: 1, costUSD: 0)
            }
            #expect(seen.input.contains("mapDrift f.txt +60 −1 linhas"))
            #expect(seen.input.contains("commits: "))
            let lc = d.router.memory.lifecycle
            #expect(await lc.entry(r.id)?.contestedNow == false)
            await d.router.lifecyclePass(store, now: Date().addingTimeInterval(2 * 86_400))
            let e = await lc.entry(r.id), h = try await head(repo)
            #expect(e?.contestedNow == false && e?.mapAnchor(for: LifecycleRules.textHash(r), store: store.key)?.commit == h)
        }
    }

    /// "invalid" is the curator's call: archived through the digest, reversibly.
    @Test func curatorInvalidArchivesReversibly() async throws {
        try await run(available: false) { d, store, repo in
            let r = map(), t0 = Date().addingTimeInterval(-60)
            try await put(store, r)
            let job = try await driftJob(d, store, repo, r, t0: t0)
            try await d.router.runVerifyJob(job) { _ in
                CuratorOutput(json: .object(["ops": .array([.object(["op": .string("retire"), "id": .string(r.id.uuidString), "reason": .string("arquivo reescrito")])])]),
                              inputTokens: 1, outputTokens: 1, costUSD: 0)
            }
            let gone = try await store.run { $0.store.all().records.first { $0.id == r.id }?.status }
            #expect(gone == .archived)
            let row = try #require(await d.router.digest.since(.distantPast).first { $0.action == "aposentado" && $0.before.contains { $0.id == r.id } })
            _ = try await d.router.undoDigest(row.id)
            let back = try await store.run { $0.store.all().records.first { $0.id == r.id }?.status }
            #expect(back == .active)
        }
    }

    /// The re-check the queue runs carries the drift as a verified fact (not only as the claim-check flag's reason).
    @Test func queuedRecheckCarriesDriftAsFact() async throws {
        let repo = try await makeRepo(), fake = FakeCurator()
        defer { try? FileManager.default.removeItem(at: repo) }
        fake.gated = true   // the run records its input, then waits
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, paths in
            defer { fake.open() }   // a failed expectation must not leave the job waiting (the daemon's stop would hang)
            // a terminal in the repo makes its store a known one (`enqueueVerify` looks there)
            let spawned = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                                                                  args: ["name": .string("T"), "preset": .string("shell"), "cwd": .string(repo.path)]),
                                                          to: paths.socket, timeoutSeconds: 60)
            #expect(spawned.ok)
            let store = await d.router.memory.repo(for: repo.path)
            let r = map(), t0 = Date().addingTimeInterval(-60)
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            try await commit("f.txt", lines(60, "novo"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            var input: String?
            for _ in 0..<100 where input == nil {
                input = fake.inputs.first { $0.contains(r.id.uuidString) || $0.contains(r.id.uuidString.lowercased()) }
                if input == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            let facts = try #require(input?.components(separatedBy: "Fatos verificados:").last)
            #expect(facts.contains("- mapDrift: f.txt +60 −1 linhas"))
            #expect(facts.contains("commits: "))
        }
    }

    // MARK: two stores of one repo (review finding 2): the pasture and a paddock worktree on its own branch

    /// A shell terminal in each dir makes its store a known one (as the pasture and a paddock are in the app).
    private func know(_ d: Daemon, _ dirs: URL...) async throws {
        for (i, u) in dirs.enumerated() {
            let r = try await UnixSocketClient.send(Request(id: "k\(i)", token: d.adminToken, command: "admin.spawn",
                                                            args: ["name": .string("K\(i)"), "preset": .string("shell"), "cwd": .string(u.path)]),
                                                    to: d.router.config.paths.socket, timeoutSeconds: 60)
            #expect(r.ok, "\(r)")
        }
    }

    private func worktree(_ repo: URL) async throws -> URL {
        let wt = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-wt")
        _ = try await GitRunner.run(["worktree", "add", "-q", "-b", "side", wt.path], in: repo)
        return wt.resolvingSymlinksInPath()
    }

    /// Each store measures against its own anchor: the worktree's branch (already different from main when the map was
    /// written) never contests it, day after day, and the pasture never re-anchors the worktree's.
    @Test func pastureAndWorktreeNeverPingPong() async throws {
        try await run { d, pasture, repo in
            let wt = try await worktree(repo)
            defer { try? FileManager.default.removeItem(at: wt) }
            try await commit("f.txt", lines(60, "lado"), in: wt)
            try await know(d, repo, wt)
            let paddock = await d.router.memory.repo(for: wt.path)
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(pasture, r); try await put(paddock, r)
            for day in 0..<4 {
                let t = t0.addingTimeInterval(Double(day) * 86_400)
                await d.router.lifecyclePass(pasture, now: t)
                await d.router.lifecyclePass(paddock, now: t)
                #expect(await lc.entry(r.id)?.contestedNow == false, "day \(day)")
            }
            let e = await lc.entry(r.id), h = LifecycleRules.textHash(r)
            #expect(e?.mapAnchor(for: h, store: pasture.key)?.commit == (try await head(repo)))
            #expect(e?.mapAnchor(for: h, store: paddock.key)?.commit == (try await head(wt)))
        }
    }

    /// The pasture's file drifts and a valid re-check clears it: only the pasture re-anchors; the worktree, whose branch
    /// never had that change, is not contested by it.
    @Test func validVerdictInOneStoreDoesNotReopenTheOther() async throws {
        try await run { d, pasture, repo in
            let wt = try await worktree(repo)
            defer { try? FileManager.default.removeItem(at: wt) }
            try await know(d, repo, wt)
            let paddock = await d.router.memory.repo(for: wt.path)
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date(), h = LifecycleRules.textHash(r)
            try await put(pasture, r); try await put(paddock, r)
            await d.router.lifecyclePass(pasture, now: t0)
            await d.router.lifecyclePass(paddock, now: t0)
            let side0 = try await head(wt)
            try await commit("f.txt", lines(60, "novo"), in: repo)
            await d.router.lifecyclePass(pasture, now: t0.addingTimeInterval(86_400))
            #expect(await lc.entry(r.id)?.contestedNow == true)
            await lc.update(r.id, now: t0) { $0.flags = []; $0.contestedNow = false; $0.recheckedAt = t0.addingTimeInterval(1.5 * 86_400) }
            for day in 2..<4 {
                let t = t0.addingTimeInterval(Double(day) * 86_400)
                await d.router.lifecyclePass(pasture, now: t)
                await d.router.lifecyclePass(paddock, now: t)
                #expect(await lc.entry(r.id)?.contestedNow == false, "day \(day)")
            }
            let e = await lc.entry(r.id)
            #expect(e?.mapAnchor(for: h, store: pasture.key)?.commit == (try await head(repo)))
            #expect(e?.mapAnchor(for: h, store: paddock.key)?.commit == side0)
        }
    }

    /// An anchor written before anchors had a store (no `store`): never measured, replaced by this store's HEAD, no contest.
    @Test func storelessAnchorMigratesWithoutContest() async throws {
        try await run { d, store, repo in
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date(), h = LifecycleRules.textHash(r)
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            let old = try await head(repo)
            try await commit("f.txt", lines(80, "z"), in: repo)
            await lc.update(r.id, now: t0) { $0.mapAnchors = [MapAnchor(textHash: h, commit: old, at: t0)] }   // the old shape
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            let e = await lc.entry(r.id)
            #expect(e?.contestedNow == false)
            #expect(e?.mapAnchor(for: h, store: store.key)?.commit == (try await head(repo)))
            #expect(e?.mapAnchors?.contains { $0.store == nil } == false)
        }
    }

    /// Review finding 3: a file first committed after the anchor shows as "+N −0" (every line new) and would always
    /// contest; it wasn't there to drift from, so the map is re-anchored instead.
    @Test func fileCommittedAfterTheAnchorReanchors() async throws {
        try await run { d, store, repo in
            try lines(50, "n").write(to: repo.appendingPathComponent("novo.txt"), atomically: true, encoding: .utf8)   // on disk, not committed
            let r = map("novo.txt", body: "novo.txt guarda as novidades"), lc = d.router.memory.lifecycle, t0 = Date()
            try await put(store, r)
            await d.router.lifecyclePass(store, now: t0)
            try await commit("novo.txt", lines(50, "n"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(86_400))
            let e = await lc.entry(r.id)
            #expect(e?.contestedNow == false)
            #expect(e?.mapAnchor(for: LifecycleRules.textHash(r), store: store.key)?.commit == (try await head(repo)))
        }
    }

    // MARK: bookkeeping (review findings 6 and 7), with git facts that count their calls

    private final class CountingFacts: GitFacts, @unchecked Sendable {
        private let lock = NSLock(); private var _diffs = 0
        var diffs: Int { lock.withLock { _diffs } }
        let result: MapDriftFacts
        static let head = String(repeating: "a", count: 40), anchor = String(repeating: "b", count: 40)
        init(_ result: MapDriftFacts) { self.result = result }
        func branch(_ name: String) async -> BranchState { .open }
        func commitExists(_ sha: String) async -> Bool { true }
        func pathExists(_ rel: String) -> Bool { true }
        func head() async -> String? { Self.head }
        func changes(from anchor: String, to head: String, paths: [String]) async -> MapDriftFacts { lock.withLock { _diffs += 1 }; return result }
        func extent(_ rel: String) async -> PathExtent? { PathExtent(isDir: false, lines: 100, files: nil) }
        func subjects(from anchor: String, to head: String, path: String) async -> [String] { [] }
        func existed(at commit: String, _ path: String) async -> Bool? { true }
    }
    /// `n` maps, each anchored in `store` at `CountingFacts.anchor` (not HEAD: all due).
    private func anchored(_ d: Daemon, _ store: RepoMemory, _ n: Int, t0: Date) async -> [MemoryRecord] {
        let recs = (0..<n).map { map("p\($0).txt") }
        await d.router.memory.lifecycle.update(recs.map(\.id), now: t0) { id, e in
            let r = recs.first { $0.id == id }!
            e.setMapAnchor(MapAnchor(textHash: LifecycleRules.textHash(r), commit: CountingFacts.anchor, at: t0, store: store.key))
        }
        return recs
    }
    private func drift(_ recs: [MemoryRecord], big: Bool = true) -> MapDriftFacts {
        .changes(Dictionary(uniqueKeysWithValues: recs.map { ($0.path!, PathChange(added: big ? 90 : 1, deleted: 0, files: 1)) }))
    }

    /// No contest left this pass: git isn't even run, and nothing is marked checked.
    @Test func noRoomRunsNoGitAndMarksNothing() async throws {
        try await run { d, store, _ in
            let t0 = Date(), recs = await anchored(d, store, 3, t0: t0), facts = CountingFacts(drift(recs))
            await d.router.mapDriftPass(store, eligible: recs, fresh: [], facts: facts, room: 0, now: t0, day: "2026-11-17")
            #expect(facts.diffs == 0)
            let all = await d.router.memory.lifecycle.all()
            #expect(recs.allSatisfy { all[$0.id]?.mapCheckedAt == nil && all[$0.id]?.contestedNow == false })
        }
    }

    /// Room for one contest, two drifted maps: the one not contested isn't marked checked (it goes first next pass).
    @Test func driftedButNotContestedStaysUnchecked() async throws {
        try await run { d, store, _ in
            let t0 = Date(), recs = await anchored(d, store, 2, t0: t0), facts = CountingFacts(drift(recs))
            await d.router.mapDriftPass(store, eligible: recs, fresh: [], facts: facts, room: 1, now: t0, day: "2026-11-17")
            let all = await d.router.memory.lifecycle.all()
            #expect(recs.filter { all[$0.id]?.contestedNow == true }.count == 1)
            for r in recs { #expect((all[r.id]?.mapCheckedAt != nil) == (all[r.id]?.contestedNow == true)) }
        }
    }

    /// git can't tell (`unknown`): those maps are marked checked too, so the 51st onwards get their turn (round robin).
    @Test func unknownRotatesPastTheFiftyCap() async throws {
        try await run { d, store, _ in
            let t0 = Date(), recs = await anchored(d, store, 60, t0: t0), facts = CountingFacts(.unknown)
            await d.router.mapDriftPass(store, eligible: recs, fresh: [], facts: facts, room: 10, now: t0, day: "2026-11-17")
            let t1 = t0.addingTimeInterval(86_400)
            await d.router.mapDriftPass(store, eligible: recs, fresh: [], facts: facts, room: 10, now: t1, day: "2026-11-18")
            let all = await d.router.memory.lifecycle.all()
            #expect(recs.allSatisfy { all[$0.id]?.mapCheckedAt != nil })
            #expect(recs.filter { all[$0.id]?.mapCheckedAt == t1 }.count == MapDrift.maxPerPass)
        }
    }

    /// Review finding 8: the user keeps the memory while the pass waits on git; the drift measured before that is not
    /// written over the user's keep (the entry is re-read when written).
    @Test func userKeepDuringThePassWins() async throws {
        final class KeepMidway: GitFacts, @unchecked Sendable {
            let lc: LifecycleStore, id: UUID, result: MapDriftFacts
            init(_ lc: LifecycleStore, _ id: UUID, _ result: MapDriftFacts) { self.lc = lc; self.id = id; self.result = result }
            func branch(_ name: String) async -> BranchState { .open }
            func commitExists(_ sha: String) async -> Bool { true }
            func pathExists(_ rel: String) -> Bool { true }
            func head() async -> String? { CountingFacts.head }
            func changes(from anchor: String, to head: String, paths: [String]) async -> MapDriftFacts {
                await lc.update(id, now: Date()) { $0.flags = [LifecycleFlag(verdict: .wrong, session: "s", day: "2026-11-17", reason: "")]; $0.contestedNow = true }
                await lc.userKept(id, now: Date())   // the user resolves it in the app meanwhile
                return result
            }
            func extent(_ rel: String) async -> PathExtent? { PathExtent(isDir: false, lines: 100, files: nil) }
            func subjects(from anchor: String, to head: String, path: String) async -> [String] { [] }
            func existed(at commit: String, _ path: String) async -> Bool? { true }
        }
        try await run { d, store, _ in
            let t0 = Date(), lc = d.router.memory.lifecycle, recs = await anchored(d, store, 1, t0: t0)
            let before = await lc.entry(recs[0].id)?.mapAnchors
            await d.router.mapDriftPass(store, eligible: recs, fresh: [], facts: KeepMidway(lc, recs[0].id, drift(recs)), room: 10,
                                        now: t0, day: "2026-11-17")
            let e = await lc.entry(recs[0].id)
            #expect(e?.contestedNow == false && e?.flags.isEmpty == true)
            #expect(e?.mapAnchors == before)   // not re-anchored over it either
        }
    }

    // MARK: many stores (before-release point A): no store evicts another's anchor; dead stores' anchors are pruned

    /// The pasture and 8 paddocks, each passing daily: anchored once, then never re-anchored (each one is measured).
    @Test func nineLiveStoresKeepTheirAnchors() async throws {
        try await run { d, _, _ in
            var stores: [RepoMemory] = [], dirs: [URL] = []
            for _ in 0..<9 { let r = try await makeRepo(); dirs.append(r); stores.append(await d.router.memory.repo(for: r.path)) }
            defer { for u in dirs { try? FileManager.default.removeItem(at: u) } }
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date(), live = Set(stores.map(\.key)), h = LifecycleRules.textHash(r)
            await lc.update(r.id, now: t0) { _ in }
            for day in 0..<3 {
                for s in stores {
                    await d.router.mapDriftPass(s, eligible: [r], fresh: [], facts: CountingFacts(.changes([:])), room: 10,
                                                now: t0.addingTimeInterval(Double(day) * 86_400), day: "d\(day)", live: live)
                }
            }
            let e = await lc.entry(r.id)
            for s in stores { #expect(e?.mapAnchor(for: h, store: s.key)?.at == t0, "\(s.key)") }   // anchored on day 0 only
        }
    }

    /// Anchors of stores no longer known (deleted paddocks) go when the entry is next written; live ones stay.
    @Test func deadStoresAnchorsArePruned() async throws {
        try await run { d, store, _ in
            let r = map(), lc = d.router.memory.lifecycle, t0 = Date(), h = LifecycleRules.textHash(r)
            await lc.update(r.id, now: t0) { e in
                for i in 0..<20 { e.setMapAnchor(MapAnchor(textHash: h, commit: CountingFacts.anchor, at: t0, store: "/dead/\(i)")) }
                e.setMapAnchor(MapAnchor(textHash: h, commit: CountingFacts.anchor, at: t0, store: "/alive"))
                e.setMapAnchor(MapAnchor(textHash: "older", commit: CountingFacts.anchor, at: t0))   // storeless: never matched
            }
            await d.router.mapDriftPass(store, eligible: [r], fresh: [], facts: CountingFacts(.changes([:])), room: 10,
                                        now: t0, day: "d", live: [store.key, "/alive"])
            let keys = Set(await lc.entry(r.id)?.mapAnchors?.compactMap(\.store) ?? [])
            #expect(keys == [store.key, "/alive"])
            #expect(await lc.entry(r.id)?.mapAnchors?.contains { $0.store == nil } == false)
        }
    }
}
