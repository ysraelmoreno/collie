import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Counts calls; `gate` holds a call until opened; `avail` switches availability; an input containing `failOn` fails the
/// run the way a real claude exit does (tests never spend tokens).
final class FakeCurator: CuratorRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _avail = CuratorAvailability.available, _inputs: [String] = [], _gated = false, waiters: [CheckedContinuation<Void, Never>] = []
    var failOn: String? { get { lock.withLock { _failOn } } set { lock.withLock { _failOn = newValue } } }
    private var _failOn: String?
    var output = CuratorOutput(json: .object(["ops": .array([])]), inputTokens: 812, outputTokens: 40, costUSD: 0.0011)
    var avail: CuratorAvailability { get { lock.withLock { _avail } } set { lock.withLock { _avail = newValue } } }
    var inputs: [String] { lock.withLock { _inputs } }
    var calls: Int { inputs.count }
    var gated: Bool { get { lock.withLock { _gated } } set { lock.withLock { _gated = newValue } } }
    func open() { let w = lock.withLock { let w = waiters; waiters = []; _gated = false; return w }; w.forEach { $0.resume() } }
    func availability() async -> CuratorAvailability { avail }
    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput {
        lock.withLock { _inputs.append(c.input) }
        if gated { await withCheckedContinuation { c in lock.withLock { if _gated { waiters.append(c) } else { c.resume() } } } }
        if let f = failOn, c.input.contains(f) { throw ProtocolError(code: .unavailable, message: "claude saiu com 1") }
        return output
    }
}

/// A local date the test moves (the next calendar day).
final class Now: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Date()
    var date: Date { get { lock.withLock { d } } set { lock.withLock { d = newValue } } }
    var fn: @Sendable () -> Date { { [self] in date } }
}

/// Records the order handlers start and end in.
actor Trace {
    var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

private func job(_ kind: CuratorJobKind = .correction, dedupe: String = UUID().uuidString, at: Date = Date(),
                 prompt: String = "não, use --filter") -> CuratorJob {
    CuratorJob(id: UUID(), kind: kind, store: "repo:/x", payload: .object(["prompt": .string(prompt)]), dedupe: dedupe,
               createdAt: at, attempts: 0)
}
private func tempDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-cq-\(UUID().uuidString.prefix(8))/curator")
}
/// The handler most tests use: one call with the job's prompt.
private let oneCall: Curator.Handler = { j, call in
    _ = try await call(CuratorCall(instructions: "i", input: "\(j.payload)", schema: "{}"))
}

@Suite(.serialized) struct CuratorQueueTests {
    @Test func oneJobAtATime() async throws {
        let fake = FakeCurator(); fake.gated = true
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        let trace = Trace()
        let a = job(), b = job()
        #expect(await c.enqueue(a))
        #expect(await c.enqueue(b))
        await c.start { j, call in
            await trace.add("start \(j.id)")
            _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}"))
            await trace.add("end \(j.id)")
        }
        #expect(await waitFor(10) { fake.calls == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.calls == 1)
        fake.open()
        #expect(await waitFor(10) { await trace.events.count == 4 })
        #expect(await trace.events == ["start \(a.id)", "end \(a.id)", "start \(b.id)", "end \(b.id)"])
        await c.stop()
    }

    @Test func queueSurvivesRestart() async throws {
        let dir = tempDir(), fake = FakeCurator()
        var first: Curator? = Curator(dir: dir, runner: fake, clock: ManualClock())
        for _ in 0..<3 { #expect(await first!.enqueue(job())) }
        first = nil
        let files = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("jobs"), includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        for f in files { #expect((try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) == 0o600) }
        #expect((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("jobs").path)[.posixPermissions] as? Int) == 0o700)
        let again = Curator(dir: dir, runner: fake, clock: ManualClock())
        #expect(await again.queued(kind: .correction).count == 3)
        await again.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls == 3 })
        #expect(await waitFor(10) { await again.queued(kind: .correction).isEmpty })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("jobs").path).isEmpty)
        await again.stop()
    }

    @Test func duplicateCorrectionQueuedOnce() async throws {
        let fake = FakeCurator(), now = Now()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock(), now: now.fn)
        #expect(await c.enqueue(job(dedupe: "d")))
        #expect(await !c.enqueue(job(dedupe: "d")))   // while queued
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { let q = await c.queued(kind: .correction); return q.isEmpty && fake.calls == 1 })
        #expect(await !c.enqueue(job(dedupe: "d")))   // within 60 s after
        now.date += 61
        #expect(await c.enqueue(job(dedupe: "d")))
        await c.stop()
    }

    @Test func dailyCapStops() async throws {
        let fake = FakeCurator(), now = Now(), clock = ManualClock()
        let c = Curator(dir: tempDir(), runner: fake, clock: clock, now: now.fn)
        await c.setCap(2)
        for _ in 0..<3 { _ = await c.enqueue(job()) }
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { await c.status().reason == "limite diário atingido (2)" })
        try await Task.sleep(for: .milliseconds(100))
        let s = await c.status()
        #expect(fake.calls == 2 && s.queued == 1 && !s.available)
        now.date = Calendar.current.date(byAdding: .day, value: 1, to: now.date)!
        await clock.waitForSleepers(1)
        clock.advance(by: Curator.tick)
        #expect(await waitFor(10) { fake.calls == 3 })
        #expect(await waitFor(10) { let s = await c.status(); return s.today == 1 && s.queued == 0 })
        await c.stop()
    }

    @Test func capZeroIsOff() async throws {
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        await c.setCap(0)
        _ = await c.enqueue(job())
        await c.start(handler: oneCall)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.calls == 0)
        let s = await c.status()
        #expect(s.reason == "desligado" && !s.available && s.cap == 0 && s.queued == 1)
        await c.stop()
    }

    @Test func unavailableKeepsJobs() async throws {
        let fake = FakeCurator(), clock = ManualClock()
        fake.avail = .unavailable("claude sem login")
        let c = Curator(dir: tempDir(), runner: fake, clock: clock)
        _ = await c.enqueue(job())
        await c.start(handler: oneCall)
        try await Task.sleep(for: .milliseconds(200))
        let s = await c.status()
        #expect(fake.calls == 0 && s.reason == "claude sem login" && s.queued == 1)
        fake.avail = .available
        await clock.waitForSleepers(1)
        clock.advance(by: Curator.tick)   // the 10-minute tick
        #expect(await waitFor(10) { fake.calls == 1 })
        fake.avail = .unavailable("claude sem login")
        _ = await c.enqueue(job())
        try await Task.sleep(for: .milliseconds(200))
        fake.avail = .available
        _ = await c.enqueue(job())   // an enqueue wakes it too
        #expect(await waitFor(10) { fake.calls == 3 })
        await c.stop()
    }

    @Test func threeAttemptsThenFailed() async throws {
        let fake = FakeCurator(), clock = ManualClock(), dir = tempDir()
        let c = Curator(dir: dir, runner: fake, clock: clock)
        let tries = Trace()
        _ = await c.enqueue(job())
        await c.start { _, _ in
            await tries.add("try")
            throw ProtocolError(code: .internal, message: "boom")
        }
        for n in 1...3 {
            let ok = await waitFor(10) { await tries.events.count == n }
            let seen = await tries.events.count
            #expect(ok, "\(seen) at \(n)")
            if n < 3 {
                // the attempt is on record before the tick (a tick during the run doesn't count)
                #expect(await waitFor(10) { await c.queued(kind: .correction).first?.attempts == n })
                await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
            }
        }
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path).count == 1)
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await tries.events.count == 3)
        await c.stop()
    }

    @Test func usageCounted() async throws {
        let fake = FakeCurator(), dir = tempDir()
        let c = Curator(dir: dir, runner: fake, clock: ManualClock())
        _ = await c.enqueue(job()); _ = await c.enqueue(job())
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { await c.status().today == 2 })
        let s = await c.status()
        #expect(s.inputTokens == 1624 && s.outputTokens == 80 && abs(s.costUSD - 0.0022) < 1e-9 && s.cap == 40)
        await c.stop()
        let again = await Curator(dir: dir, runner: fake, clock: ManualClock()).status()
        #expect(again.today == 2 && again.inputTokens == 1624)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage.json").path))
    }

    @Test func queueCapped() async throws {
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        let t0 = Date()
        let oldest = job(.proposals, at: t0)
        #expect(await c.enqueue(oldest))
        for i in 1..<Curator.queueMax { #expect(await c.enqueue(job(.proposals, at: t0 + Double(i)))) }
        #expect(await !c.enqueue(job(.proposals, at: t0 + 1000)))
        #expect(await c.enqueue(job(.correction)))
        let left = await c.queued(kind: .proposals)
        #expect(left.count == Curator.queueMax - 1 && !left.contains { $0.id == oldest.id })
        #expect(await c.queued(kind: .correction).count == 1)
    }

    @Test func inputCapped() async throws {
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        _ = await c.enqueue(job())
        await c.start { _, call in _ = try await call(CuratorCall(instructions: "", input: String(repeating: "é", count: 20_000), schema: "{}")) }
        #expect(await waitFor(10) { fake.calls == 1 })
        #expect(fake.inputs.first?.count == Curator.inputMax && Curator.inputMax == 12_000)
        await c.stop()
        // combining marks: capped by unicode scalars, not characters (the input goes in argv)
        let z = FakeCurator(), c2 = Curator(dir: tempDir(), runner: z, clock: ManualClock())
        _ = await c2.enqueue(job())
        await c2.start { _, call in _ = try await call(CuratorCall(instructions: "", input: String(repeating: "e\u{301}\u{302}", count: 20_000), schema: "{}")) }
        #expect(await waitFor(10) { z.calls == 1 })
        #expect(z.inputs.first?.unicodeScalars.count == Curator.inputMax)
        await c2.stop()
    }

    /// R7: a run that fails (nonzero exit, is_error, junk) spends an attempt; the next job still runs; 3 → failed/.
    @Test func poisonJobDoesNotBlock() async throws {
        let fake = FakeCurator(), clock = ManualClock(), dir = tempDir(), t0 = Date()
        fake.failOn = "poison"
        let c = Curator(dir: dir, runner: fake, clock: clock)
        let bad = job(at: t0, prompt: "poison"), good = job(at: t0 + 1)
        _ = await c.enqueue(bad); _ = await c.enqueue(good)
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { await c.queued(kind: .correction).map(\.id) == [bad.id] })
        #expect(await c.queued(kind: .correction).first?.attempts == 1 && fake.calls == 2)
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
        #expect(await waitFor(10) { await c.queued(kind: .correction).first?.attempts == 2 })
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(fake.calls == 4)
        #expect(await c.status().failed == 1)
        await c.stop()
    }

    /// R9: the attempt is on disk before the run, so a job that crashes the daemon each time is parked after 3 starts.
    @Test func attemptSavedBeforeRun() async throws {
        let dir = tempDir(), fake = FakeCurator()
        fake.gated = true
        let c = Curator(dir: dir, runner: fake, clock: ManualClock())
        _ = await c.enqueue(job())
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls == 1 })
        let jobs = dir.appendingPathComponent("jobs")
        func onDisk() throws -> CuratorJob {
            let n = try #require(try FileManager.default.contentsOfDirectory(atPath: jobs.path).first)
            return try Curator.decoder.decode(CuratorJob.self, from: Data(contentsOf: jobs.appendingPathComponent(n)))
        }
        #expect(try onDisk().attempts == 1)   // mid-run: a crash now still counts
        await c.stop()   // the run stays blocked, like a crash mid-run
        // two more crashed starts: written with attempts 3, the next load parks it
        var j = try onDisk(); j.attempts = Curator.maxAttempts
        let n = try #require(try FileManager.default.contentsOfDirectory(atPath: jobs.path).first)
        try Curator.encoder.encode(j).write(to: jobs.appendingPathComponent(n))
        let again = Curator(dir: dir, runner: fake, clock: ManualClock())
        #expect(await again.queued(kind: .correction).isEmpty)
        #expect(await again.status().failed == 1)
        // a handler that waits (unavailable) gives the attempt back
        let w = Curator(dir: tempDir(), runner: FakeCurator(), clock: ManualClock())
        _ = await w.enqueue(job())
        await w.start { _, _ in throw ProtocolError(code: .unavailable, message: "sem tratador") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await w.queued(kind: .correction).first?.attempts == 0)
        await w.stop()
    }

    /// A reloaded job removes the file it was loaded from, whatever its name.
    @Test func jobFileStableAcrossReload() async throws {
        let dir = tempDir(), fake = FakeCurator(), j = job()
        _ = await Curator(dir: dir, runner: fake, clock: ManualClock()).enqueue(j)
        let jobs = dir.appendingPathComponent("jobs")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: jobs.path).first)
        try FileManager.default.moveItem(at: jobs.appendingPathComponent(name), to: jobs.appendingPathComponent("0-\(j.id.uuidString).json"))
        let c = Curator(dir: dir, runner: fake, clock: ManualClock())
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs.path).isEmpty)
        await c.stop()
    }

    /// A tick during a run doesn't count for the job that fails in it: the retry waits for the next tick.
    @Test func tickMidRunKeepsBackoff() async throws {
        let fake = FakeCurator(), clock = ManualClock()
        fake.gated = true
        let c = Curator(dir: tempDir(), runner: fake, clock: clock)
        _ = await c.enqueue(job())
        await c.start { j, call in
            _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}"))
            throw ProtocolError(code: .internal, message: "boom")
        }
        #expect(await waitFor(10) { fake.calls == 1 })
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)   // mid-run
        fake.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.calls == 1)
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
        #expect(await waitFor(10) { fake.calls == 2 })
        await c.stop()
    }

    @Test func curatorCommandStatus() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        var cfg = testConfig(paths)
        cfg.curatorRunner = FakeCurator()
        let d = try Daemon(config: cfg)
        try await d.start()
        let r = try await send(paths, Request(id: "a", token: d.adminToken, command: "memory.curator", args: ["cap": .number(5)]), timeoutSeconds: 30)
        guard case .object(let o)? = r.result else { Issue.record("\(r)"); await d.stop(); return }
        #expect(o["cap"] == .number(5) && o["available"] == .bool(true) && o["today"] == .number(0))
        await d.stop()
    }
}
