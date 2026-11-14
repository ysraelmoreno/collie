import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

/// Git facts with fixed answers: every path and branch fine, the SHAs in `missing` absent.
private struct VerifyFacts: GitFacts {
    var missing: Set<String> = []
    func branch(_ name: String) async -> BranchState { .open }
    func commitExists(_ sha: String) async -> Bool { !missing.contains(sha) }
    func pathExists(_ rel: String) -> Bool { true }
}

private func ops(_ list: [[String: JSONValue]]) -> CuratorOutput {
    CuratorOutput(json: .object(["ops": .array(list.map { .object($0) })]), inputTokens: 1, outputTokens: 1, costUSD: 0)
}
private func retire(_ id: UUID) -> CuratorOutput { ops([["op": .string("retire"), "id": .string(id.uuidString), "reason": .string("velha")]]) }

nonisolated(unsafe) private let day: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }()

/// A promotion candidate: 8 useful uses over 4 days spanning 20 days, from 2 sessions.
private func candidate(_ e: inout LifecycleEntry) {
    let ago: [Double] = [20, 14, 7, 1]
    var uses: Set<UseKey> = []
    for i in 0..<8 { uses.insert(UseKey(day: day.string(from: Date().addingTimeInterval(-ago[i % 4] * 86_400)), session: "u\(i)")) }
    e.usefulUses = uses
}

@Suite(.serialized) struct VerifyJobTests {
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
    }
    private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
    }
    private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { return o }; return [:] }
    private func str(_ v: JSONValue?) -> String { if case .string(let x)? = v { return x }; return "" }

    /// A terminal in a fresh repo, session "s1", injected `n` project decisions (bodies `body`).
    private func setup(_ d: Daemon, _ p: Paths, n: Int = 1, body: String = "pool") async throws -> (Term, [UUID], RepoMemory) {
        let repo = try await makeRepo()
        let r = try await admin(d, p, "admin.spawn", ["name": .string("T"), "preset": .string("shell"), "cwd": .string(repo.path)])
        let id = str(obj(r)["id"])
        let t = Term(id: id, token: try await tokenOf(d, id))
        var ids: [UUID] = []
        for i in 0..<n {
            let saved = try await call(p, t, "memory.save", ["kind": .string("decision"), "subject": .string("db\(i)"), "title": .string("Use Postgres \(i)"), "body": .string(body)])
            ids.append(UUID(uuidString: str(obj(saved)["id"]))!)
        }
        await session(d, t, "s1", ids)
        return (t, ids, await d.router.memory.repo(for: repo.path))
    }
    private func session(_ d: Daemon, _ t: Term, _ s: String, _ ids: [UUID]) async {
        await d.router.memory.noteSession(t.uuid, transcript: "/x/\(s).jsonl")
        await d.router.memory.lifecycle.noteInjected(session: s, ids: ids, now: Date())
    }
    private func flag(_ p: Paths, _ t: Term, _ id: UUID, reason: String = "stale") async throws -> [String: JSONValue] {
        let r = try await call(p, t, "memory.flag", ["id": .string(id.uuidString), "wrong": .bool(true), "reason": .string(reason)])
        #expect(r.ok, "\(r)")
        return obj(r)
    }
    private func status(_ s: RepoMemory, _ id: UUID) async throws -> MemoryStatus? {
        try await s.run { $0.store.all().records.first { $0.id == id }?.status }
    }

    @Test func validVerdictClearsFlagsAndStartsCooldown() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, store) = try await setup(d, p)
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
            let lc = d.router.memory.lifecycle
            #expect(await waitFor(10) { await lc.entry(ids[0])?.recheckedAt != nil })
            let e = await lc.entry(ids[0])
            #expect(e?.flags.isEmpty == true && e?.contestedNow == false)
            #expect(try await status(store, ids[0]) == .active)
            let input = try #require(fake.inputs.first)
            #expect(input.hasPrefix("DADOS-") && input.contains("wrong: stale") && input.contains(ids[0].uuidString))
            // a new flag inside the cooldown only tags
            await session(d, t, "s2", ids)
            let again = try await flag(p, t, ids[0])
            #expect(again["contested"] == .bool(true) && again["queued"] == .bool(false), "\(again)")
        }
    }

    @Test func invalidVerdictArchivesReversibly() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, store) = try await setup(d, p)
            fake.output = retire(ids[0])
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
            #expect(await waitFor(10) { (try? await status(store, ids[0])) == .archived })
            let rows = await d.router.digest.since(.distantPast)
            let row = try #require(rows.first { (e: DigestEntry) -> Bool in e.action == "aposentado" && e.before.first?.id == ids[0] })
            _ = try await d.router.undoDigest(row.id)
            #expect(try await status(store, ids[0]) == .active)
        }
    }

    /// Validation keeps only a retire of the job's own memory.
    @Test func retireOfAnotherIdIsDropped() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, store) = try await setup(d, p, n: 2)
            fake.output = retire(ids[1])
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
            #expect(await waitFor(10) { await d.router.memory.lifecycle.entry(ids[0])?.recheckedAt != nil })   // read as valid
            let (a, b) = (try await status(store, ids[0]), try await status(store, ids[1]))
            #expect(a == .active && b == .active)
        }
    }

    @Test func promotionValidSetsLongTerm() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (_, ids, _) = try await setup(d, p)
            let lc = d.router.memory.lifecycle
            await lc.update(ids[0], now: Date()) { candidate(&$0) }
            #expect(LifecycleRules.promotionCandidate(try #require(await lc.entry(ids[0])), now: Date()))
            #expect(await d.router.memory.enqueuePromotion(ids[0]))
            #expect(await waitFor(10) { await lc.entry(ids[0])?.tier == .longTerm })
        }
    }

    @Test func promotionInvalidStaysEarned() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (_, ids, store) = try await setup(d, p)
            fake.output = retire(ids[0])
            let lc = d.router.memory.lifecycle
            await lc.update(ids[0], now: Date()) { candidate(&$0) }
            #expect(await d.router.memory.enqueuePromotion(ids[0]))
            #expect(await waitFor(10) { await lc.entry(ids[0])?.recheckedAt != nil })
            #expect(await lc.entry(ids[0])?.tier != .longTerm)
            #expect(try await status(store, ids[0]) == .active)   // a promotion's "invalid" never archives
        }
    }

    @Test func promotionRespectsTwelveCap() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (_, ids, _) = try await setup(d, p, n: 13)
            let lc = d.router.memory.lifecycle
            for id in ids.prefix(12) { await lc.update(id, now: Date()) { $0.tier = .longTerm } }
            await lc.update(ids[12], now: Date()) { candidate(&$0) }
            #expect(await d.router.memory.enqueuePromotion(ids[12]))
            #expect(await waitFor(10) { await lc.entry(ids[12])?.recheckedAt != nil })
            #expect(await lc.entry(ids[12])?.tier != .longTerm)
        }
    }

    @Test func promotionJobsCappedThreePerDay() async throws {
        let fake = FakeCurator(); fake.avail = .unavailable("sem modelo")
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (_, ids, _) = try await setup(d, p, n: 5)
            var got: [Bool] = []
            for id in ids.prefix(4) { got.append(await d.router.memory.enqueuePromotion(id)) }
            #expect(got == [true, true, true, false])
            #expect(await d.router.curator.queued(kind: .verifyPromotion).count == 3)
            // persisted: a restart doesn't reset the day's count
            let reopened = LifecycleStore(file: d.router.memory.lifecycle.file)
            #expect(await !reopened.takeGate(day: day.string(from: Date()), max: LifecycleRules.maxGatesPerDay))
            #expect(await d.router.memory.enqueuePromotion(ids[4], now: Date().addingTimeInterval(86_400)))
        }
    }

    @Test func noModelLeavesContestedTaggedNothingSilenced() async throws {
        let fake = FakeCurator(); fake.avail = .unavailable("sem modelo")
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, store) = try await setup(d, p)
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
            await session(d, t, "s2", ids)
            _ = try await flag(p, t, ids[0])   // a second session's flag silences nothing either
            #expect(try await status(store, ids[0]) == .active)
            #expect(await d.router.memory.lifecycle.entry(ids[0])?.contestedNow == true)
            #expect(await d.router.curator.queued(kind: .verifyContested).count == 1)
            #expect(fake.calls == 0)
        }
    }

    @Test func noModelWithFailedClaimCheckArchives() async throws {
        let fake = FakeCurator(); fake.avail = .unavailable("sem modelo")
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts(missing: ["deadbee1"]) } }) { d, p in
            let (t, ids, store) = try await setup(d, p, body: "corrigido no commit deadbee1")
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(false))
            #expect(try await status(store, ids[0]) == .archived)
            #expect(await d.router.curator.queued(kind: .verifyContested).isEmpty)
            let row = try #require(await d.router.digest.since(.distantPast).first { $0.action == "aposentado" })
            #expect(row.reason.contains("commitMissing deadbee1"), "\(row.reason)")
            _ = try await d.router.undoDigest(row.id)
            #expect(try await status(store, ids[0]) == .active)
        }
    }

    @Test func capReachedKeepsJobQueued() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, store) = try await setup(d, p, n: 2)
            await d.router.curator.setCap(1)
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
            #expect(await waitFor(10) { await d.router.memory.lifecycle.entry(ids[0])?.recheckedAt != nil })
            #expect(try await flag(p, t, ids[1])["queued"] == .bool(true))
            try await Task.sleep(for: .milliseconds(300))
            #expect(fake.calls == 1)
            #expect(await d.router.curator.queued(kind: .verifyContested).count == 1)
            #expect(await d.router.memory.lifecycle.entry(ids[1])?.contestedNow == true)
            #expect(try await status(store, ids[1]) == .active)
        }
    }

    @Test func priorityOrderCorrectionThenContestedThenPromotion() async throws {
        let order: [CuratorJobKind] = [.correction, .verifyContested, .verifyPromotion, .proposals, .pitfall, .conversation, .consolidate, .procedure, .docTerms]
        #expect(CuratorJobKind.allCases == order)
        #expect(CuratorJobKind(rawValue: "proposals") == .proposals && CuratorJobKind(rawValue: "docTerms") == .docTerms)
        let fake = FakeCurator(), trace = Trace()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-vj-\(UUID().uuidString.prefix(8))/curator")
        let c = Curator(dir: dir, runner: fake, clock: ManualClock())
        for k in [CuratorJobKind.proposals, .verifyPromotion, .verifyContested, .correction] {
            #expect(await c.enqueue(CuratorJob(id: UUID(), kind: k, store: "repo:/x", payload: .null, dedupe: k.rawValue, createdAt: Date(), attempts: 0)))
        }
        await c.start { j, call in
            _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}"))
            await trace.add(j.kind.rawValue)
        }
        #expect(await waitFor(10) { await trace.events.count == 4 })
        #expect(await trace.events == ["correction", "verifyContested", "verifyPromotion", "proposals"])
        await c.stop()
    }

    @Test func flagInsideCooldownQueuesNothing() async throws {
        let fake = FakeCurator(); fake.avail = .unavailable("sem modelo")
        try await withDaemon(configure: { $0.curatorRunner = fake; $0.gitFacts = { _ in VerifyFacts() } }) { d, p in
            let (t, ids, _) = try await setup(d, p)
            await d.router.memory.lifecycle.update(ids[0], now: Date()) { $0.recheckedAt = Date().addingTimeInterval(-13 * 86_400) }
            let r = try await flag(p, t, ids[0])
            #expect(r["contested"] == .bool(true) && r["queued"] == .bool(false), "\(r)")
            #expect(await d.router.memory.lifecycle.entry(ids[0])?.contestedNow == true)
            #expect(await d.router.curator.queued(kind: .verifyContested).isEmpty)
            // past 14 days it queues again
            await d.router.memory.lifecycle.update(ids[0], now: Date()) { $0.recheckedAt = Date().addingTimeInterval(-15 * 86_400) }
            await session(d, t, "s2", ids)
            #expect(try await flag(p, t, ids[0])["queued"] == .bool(true))
        }
    }
}
