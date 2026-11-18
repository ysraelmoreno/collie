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
            #expect(e0?.mapAnchor(for: LifecycleRules.textHash(r))?.commit == h0)
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
            #expect(e?.mapAnchor(for: LifecycleRules.textHash(r))?.commit == (try await head(repo)))
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
            #expect(e?.mapAnchors?.count == 2 && e?.mapAnchor(for: old) != nil && e?.mapAnchor(for: LifecycleRules.textHash(r)) != nil)
            let now = LifecycleRules.textHash(r), lost = String(repeating: "ab", count: 20)
            await lc.update(r.id, now: t0) { $0.setMapAnchor(MapAnchor(textHash: now, commit: lost, at: t0)) }
            try await commit("f.txt", lines(90, "w"), in: repo)
            await d.router.lifecyclePass(store, now: t0.addingTimeInterval(2 * 86_400))
            let e2 = await lc.entry(r.id)
            #expect(e2?.mapAnchor(for: now)?.commit == (try await head(repo)))   // gone anchor: HEAD, nothing judged
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
            #expect(e?.contestedNow == false && e?.mapAnchor(for: LifecycleRules.textHash(r))?.commit == h)
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
}
