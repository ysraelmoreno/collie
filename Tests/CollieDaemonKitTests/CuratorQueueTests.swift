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
    var failMessage: String { get { lock.withLock { _failMessage } } set { lock.withLock { _failMessage = newValue } } }
    private var _failMessage = "claude saiu com 1"
    /// A run whose input contains `.0` turns the runner `.exhausted` until `.1`, then fails (the real runner's way).
    var exhaustOn: (String, Date)? { get { lock.withLock { _exhaustOn } } set { lock.withLock { _exhaustOn = newValue } } }
    private var _exhaustOn: (String, Date)?
    var output = CuratorOutput(json: .object(["ops": .array([])]), inputTokens: 812, outputTokens: 40, costUSD: 0.0011)
    var avail: CuratorAvailability { get { lock.withLock { _avail } } set { lock.withLock { _avail = newValue } } }
    var inputs: [String] { lock.withLock { _inputs } }
    var calls: Int { inputs.count }
    var gated: Bool { get { lock.withLock { _gated } } set { lock.withLock { _gated = newValue } } }
    func open() { let w = lock.withLock { let w = waiters; waiters = []; _gated = false; return w }; w.forEach { $0.resume() } }
    /// What it says it is (default: Claude, full trust); `models`, `timeouts`: what each run got.
    var info: CuratorProviderInfo { get { lock.withLock { _info } } set { lock.withLock { _info = newValue } } }
    private var _info = ClaudeCuratorRunner.claudeInfo, _models: [String] = [], _timeouts: [Duration] = []
    var models: [String] { lock.withLock { _models } }
    var timeouts: [Duration] { lock.withLock { _timeouts } }
    func models() async -> [String] { [] }
    func availability() async -> CuratorAvailability { avail }
    /// How its login bills (default: in a plan, like the Claude subscription).
    var bills: CuratorBilling { get { lock.withLock { _bills } } set { lock.withLock { _bills = newValue } } }
    private var _bills = CuratorBilling.included("teste")
    func billing() async -> CuratorBilling { bills }
    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput {
        lock.withLock { _inputs.append(c.input); _models.append(model); _timeouts.append(timeout) }
        if gated { await withCheckedContinuation { c in lock.withLock { if _gated { waiters.append(c) } else { c.resume() } } } }
        if let f = failOn, c.input.contains(f) { throw ProtocolError(code: .unavailable, message: failMessage) }
        if let (f, until) = exhaustOn, c.input.contains(f) {
            avail = .exhausted("Credit balance is too low", until: until)
            throw ProtocolError(code: .unavailable, message: "Credit balance is too low")
        }
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
    // E7: config.json read field by field, both ways (an older daemon rewrites it with only cap and model)
    private func config(_ json: String) throws -> Curator.Config { try Curator.decoder.decode(Curator.Config.self, from: Data(json.utf8)) }

    @Test func newReadsOld() async throws {
        let c = try config(#"{"cap":7,"model":"sonnet"}"#)
        #expect(c.cap == 7 && c.model == "sonnet" && c.provider == "claude" && c.models.isEmpty && c.consented.isEmpty)
        // through the curator: an old file keeps its cap (a strict decode used to reset everything to 40)
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"cap":7,"model":"sonnet"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(await Curator(dir: dir, runner: FakeCurator(), clock: ManualClock()).status().cap == 7)
    }

    @Test func oldRewriteFallsBackToClaude() throws {
        var c = try config(#"{"cap":9,"model":"haiku","provider":"cursor","models":{"cursor":"x"},"consented":["cursor"]}"#)
        #expect(c.provider == "cursor" && c.consented == ["cursor"] && c.models == ["cursor": "x"])
        // what an older daemon's `setCap` writes back: only the keys it knows
        struct Old: Codable { var cap: Int; var model: String }
        let old = try Curator.encoder.encode(Old(cap: 9, model: "haiku"))
        c = try Curator.decoder.decode(Curator.Config.self, from: old)
        #expect(c.cap == 9 && c.provider == "claude" && c.consented.isEmpty)
    }

    @Test func unknownProviderIsClaude() throws {
        #expect(try config(#"{"provider":"gpt-9"}"#).provider == "claude")
    }

    @Test func wrongTypeKeepsOthers() throws {
        let c = try config(#"{"cap":"x","model":"sonnet","consented":"cursor"}"#)
        #expect(c.cap == nil && c.model == "sonnet" && c.consented.isEmpty)
    }

    @Test func configRoundTrip() throws {
        var c = Curator.Config(); c.cap = 12; c.provider = "cursor"; c.models = ["claude": "haiku"]; c.consented = ["cursor"]
        let back = try Curator.decoder.decode(Curator.Config.self, from: Curator.encoder.encode(c))
        #expect(back.cap == 12 && back.model == "haiku" && back.provider == "cursor" && back.models == ["claude": "haiku"] && back.consented == ["cursor"])
    }

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

    /// No cap is the default: nothing stops the queue, no quarter is held back; a cap set and cleared goes back to that.
    @Test func noCapByDefault() async throws {
        let fake = FakeCurator(), dir = tempDir()
        let c = Curator(dir: dir, runner: fake, clock: ManualClock())
        #expect(Curator.Config().cap == nil)
        for _ in 0..<45 { _ = await c.enqueue(job()) }   // past the old default of 40
        await c.start(handler: oneCall)
        #expect(await waitFor(20) { fake.calls == 45 })
        var s = await c.status()
        #expect(s.cap == nil && s.available && s.reason == nil && s.queued == 0)
        await c.setCap(1)
        s = await c.status()
        #expect(s.cap == 1 && s.reason == "limite diário atingido (1)")
        await c.setCap(nil)
        s = await c.status()
        #expect(s.cap == nil && s.available)
        // cleared on disk too: the file has no cap, so a restart (or an older daemon) reads its own default
        let file = try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(!file.contains("\"cap\""))
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

    /// An environment failure (here the real DNS error of the sandboxed Cursor call) spends no attempt: the job waits, never
    /// reaches failed/; a plain failure of the run still spends one.
    @Test func environmentFailureSpendsNoAttempt() async throws {
        let fake = FakeCurator(), clock = ManualClock(), dir = tempDir()
        fake.failOn = "dns"
        fake.failMessage = "cursor saiu com 1: Error: [unavailable] getaddrinfo ENOTFOUND api2.cursor.sh"
        let c = Curator(dir: dir, runner: fake, clock: clock)
        _ = await c.enqueue(job(prompt: "dns"))
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls >= 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await c.queued(kind: .correction).first?.attempts == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path).isEmpty)
        await c.stop()

        let plain = FakeCurator()
        plain.failOn = "x"
        plain.failMessage = "claude saiu com 1"
        let c2 = Curator(dir: tempDir(), runner: plain, clock: ManualClock())
        _ = await c2.enqueue(job(prompt: "x"))
        await c2.start(handler: oneCall)
        #expect(await waitFor(10) { await c2.queued(kind: .correction).first?.attempts == 1 })
        await c2.stop()
    }

    @Test func environmentFailureMessages() {
        for m in ["cursor saiu com 1: Error: Workspace directory does not exist: /var/folders/x", "curador bloqueado pelo sandbox: /private/var/x",
                  "Error: [unavailable] getaddrinfo ENOTFOUND api2.cursor.sh", "connect ECONNREFUSED 127.0.0.1:443"] {
            #expect(Curator.isEnvironmentFailure(m), "\(m)")
        }
        for m in ["claude saiu com 1", "curator: junk answer (items)", "resposta ilegível do claude", "claude não respondeu"] {
            #expect(!Curator.isEnvironmentFailure(m), "\(m)")
        }
    }

    /// `failed/` keeps a parked job `failedKeep`, then it is deleted: the app's "curador falhando" alert goes away once the
    /// curator works again (63 environment failures in one day had left it on for good).
    @Test func failedJobsExpire() async throws {
        let dir = tempDir(), failed = dir.appendingPathComponent("failed")
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        let old = failed.appendingPathComponent("1-old.json"), recent = failed.appendingPathComponent("2-recent.json")
        for u in [old, recent] { try Data("{}".utf8).write(to: u) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Curator.failedKeep - 60)], ofItemAtPath: old.path)
        let c = Curator(dir: dir, runner: FakeCurator(), clock: ManualClock())
        #expect(await c.status().failed == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: recent.path))
    }

    /// The prune also runs when a job is parked: an old file goes, the new one (just written) stays.
    @Test func parkingAJobPrunesOldOnes() async throws {
        let fake = FakeCurator(), clock = ManualClock(), dir = tempDir(), failed = dir.appendingPathComponent("failed")
        let c = Curator(dir: dir, runner: fake, clock: clock)
        let old = failed.appendingPathComponent("1-old.json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Curator.failedKeep - 60)], ofItemAtPath: old.path)
        let tries = Trace()
        _ = await c.enqueue(job())
        await c.start { _, _ in await tries.add("try"); throw ProtocolError(code: .internal, message: "boom") }
        for n in 1...3 {
            #expect(await waitFor(10) { await tries.events.count == n })
            if n < 3 {
                #expect(await waitFor(10) { await c.queued(kind: .correction).first?.attempts == n })
                await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
            }
        }
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: failed.path).count == 1)   // the parked job
        await c.stop()
    }

    /// E6: a run that leaves the runner `.exhausted` (credit, quota) spends no attempt: the job waits, never reaches failed/.
    @Test func exhaustedSpendsNoAttempt() async throws {
        let fake = FakeCurator(), clock = ManualClock(), dir = tempDir()
        let until = Date().addingTimeInterval(3600)
        fake.exhaustOn = ("cota", until)
        let c = Curator(dir: dir, runner: fake, clock: clock)
        _ = await c.enqueue(job(prompt: "cota"))
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await c.queued(kind: .correction).first?.attempts == 0)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        #expect(await c.status().reason == "cota do claude esgotada até \(f.string(from: until))")
        for _ in 0..<3 { await clock.waitForSleepers(1); clock.advance(by: Curator.tick) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.calls == 1)   // still exhausted: nothing runs, nothing is spent
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path).isEmpty)
        await c.stop()
    }

    /// Once the quota is back, the waiting job runs on the next tick.
    @Test func exhaustedWaitsUntil() async throws {
        let fake = FakeCurator(), clock = ManualClock()
        fake.exhaustOn = ("cota", Date().addingTimeInterval(3600))
        let c = Curator(dir: tempDir(), runner: fake, clock: clock)
        _ = await c.enqueue(job(prompt: "cota"))
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls == 1 })
        fake.exhaustOn = nil; fake.avail = .available
        await clock.waitForSleepers(1); clock.advance(by: Curator.tick)
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(fake.calls == 2)
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
        #expect(s.inputTokens == 1624 && s.outputTokens == 80 && abs(s.costUSD - 0.0022) < 1e-9 && s.cap == nil)
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

    /// Over the cap, the data is cut inside the fence: both marks stay (the closing one last).
    @Test func inputCapped() async throws {
        let mark = "DADOS-" + String(repeating: "a", count: 32)
        func fenced(_ s: String) -> String { "Escopos: project\n\(mark)\n\(s)\n\(mark)" }
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        _ = await c.enqueue(job())
        let e1 = fenced(String(repeating: "é", count: 20_000)), e2 = fenced(String(repeating: "e\u{301}\u{302}", count: 20_000))
        await c.start { _, call in _ = try await call(CuratorCall(instructions: "", input: e1, schema: "{}")) }
        #expect(await waitFor(10) { fake.calls == 1 })
        let got = try #require(fake.inputs.first)
        #expect(got.unicodeScalars.count == Curator.inputMax && Curator.inputMax == 12_000)
        #expect(got.hasPrefix("Escopos: project\n\(mark)\n") && got.hasSuffix("\n\(mark)"))
        await c.stop()
        // combining marks: capped by unicode scalars, not characters
        let z = FakeCurator(), c2 = Curator(dir: tempDir(), runner: z, clock: ManualClock())
        _ = await c2.enqueue(job())
        await c2.start { _, call in _ = try await call(CuratorCall(instructions: "", input: e2, schema: "{}")) }
        #expect(await waitFor(10) { z.calls == 1 })
        #expect(z.inputs.first?.unicodeScalars.count == Curator.inputMax && z.inputs.first?.hasSuffix(mark) == true)
        await c2.stop()
    }

    /// An input over the cap with no fence to cut inside fails the job (an attempt spent), never runs cut.
    @Test func overLimitWithoutFenceFails() async throws {
        let fake = FakeCurator(), c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        _ = await c.enqueue(job())
        await c.start { _, call in _ = try await call(CuratorCall(instructions: "", input: String(repeating: "x", count: 20_000), schema: "{}")) }
        #expect(await waitFor(10) { await c.queued(kind: .correction).first?.attempts == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.calls == 0)
        await c.stop()
    }

    @Test func fitKeepsBothMarks() {
        let m = "DADOS-" + String(repeating: "b", count: 32)
        #expect(Curator.fit("curto", max: 100) == "curto")
        #expect(Curator.fit(String(repeating: "x", count: 200), max: 100) == nil)   // no fence
        let s = "\(m)\n" + String(repeating: "y", count: 500) + "\n\(m)"
        let f = try! #require(Curator.fit(s, max: 120))
        #expect(f.unicodeScalars.count == 120 && f.hasPrefix(m + "\n") && f.hasSuffix("\n" + m))
        #expect(Curator.fit(s, max: 60) == nil)   // the opening mark itself wouldn't fit
    }

    // the bad-output pause: the last 20 calls of the chosen provider, ≥ 10 junk or all-dropped
    private func results(_ c: Curator, _ rs: [CuratorJobResult], fake: FakeCurator) async {
        let box = Trace()
        for _ in rs { _ = await c.enqueue(job()) }
        await c.start(job: { j, call, _ in
            _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}"))
            let n = await box.events.count; await box.add("r")
            return rs[n]
        })
        _ = await waitFor(10) {
            if fake.calls == rs.count { return true }
            let why = await c.status().reason ?? ""
            return why.hasPrefix("saída inválida")
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func tenOfTwentyPauses() async throws {
        let fake = FakeCurator(), c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        let rs: [CuratorJobResult] = Array(repeating: .ok, count: 5) + Array(repeating: .junk, count: 5) + Array(repeating: .allDropped, count: 5) + [.ok]
        await results(c, rs, fake: fake)
        let s = await c.status()
        #expect(s.available == false && s.reason == "saída inválida em 10 de 15 (troque de modelo)" && fake.calls == 15 && s.queued == 1)
        await c.stop()
    }

    @Test func switchClearsPause() async throws {
        let fake = FakeCurator(), c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        let rs: [CuratorJobResult] = Array(repeating: .junk, count: 10) + [.ok]
        await results(c, rs, fake: fake)
        #expect(await c.status().available == false)
        try await c.setProvider(.claude, model: "sonnet")   // another model: a fresh start
        #expect(await waitFor(10) { fake.calls == 11 })
        #expect(await c.status().available == true)
        await c.stop()
    }

    /// A runner answer it can't read counts against the provider like a junk answer.
    @Test func runnerUnreadableCountsAsJunk() async throws {
        let fake = FakeCurator(); fake.failOn = "x"; fake.failMessage = "resposta ilegível do claude"
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        for _ in 0..<10 { _ = await c.enqueue(job(prompt: "x")) }
        await c.start { _, call in _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}")) }
        #expect(await waitFor(10) { (await c.status().reason ?? "").hasPrefix("saída inválida em 10") })
        await c.stop()
    }

    @Test func junkCountsAsBad() {
        #expect(CuratorOps.result(.object(["ops": .array([])]), ([], 0)) == .ok)
        #expect(CuratorOps.result(.object([:]), ([], 1)) == .junk)
        #expect(CuratorOps.result(.string("x"), ([], 1)) == .junk)
        #expect(CuratorOps.result(.object(["ops": .array([.object(["op": .string("nada")])])]), ([], 1)) == .allDropped)
        #expect(DocTerms.result(.object(["chunks": .array([])])) == .ok && DocTerms.result(.object([:])) == .junk)
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
        let n = try await send(paths, Request(id: "b", token: d.adminToken, command: "memory.curator", args: ["noCap": .bool(true)]), timeoutSeconds: 30)
        guard case .object(let u)? = n.result else { Issue.record("\(n)"); await d.stop(); return }
        #expect(u["cap"] == nil && u["available"] == .bool(true))
        await d.stop()
    }

    // Task 12: choose, consent and test the provider (admin-only, through `memory.curator`)
    private func cursorRunner() -> FakeCurator {
        let f = FakeCurator()
        f.info = CuratorProviderInfo(provider: .cursor, trust: .limited, destination: "Cursor", structuredOutput: false,
                                     reportsUsage: false, timeout: .seconds(120), inputMax: 12_000)
        return f
    }
    private func curatorCmd(_ d: Daemon, _ p: Paths, _ args: [String: JSONValue]) async throws -> Response {
        try await send(p, Request(id: "c", token: d.adminToken, command: "memory.curator", args: args), timeoutSeconds: 30)
    }

    @Test func curatorCommandSetsProvider() async throws {
        let cursor = cursorRunner()
        try await withDaemon(configure: { $0.curatorRunners = [.claude: FakeCurator(), .cursor: cursor] }) { d, p in
            let refused = try await curatorCmd(d, p, ["provider": .string("cursor")])
            #expect(refused.error == ProtocolError(code: .unavailable, message: "falta confirmar nas Preferências"), "\(refused)")
            let ok = try await curatorCmd(d, p, ["consent": .string("cursor"), "provider": .string("cursor"), "model": .string("auto")])
            guard case .object(let o)? = ok.result else { Issue.record("\(ok)"); return }
            #expect(o["provider"] == .string("cursor") && o["model"] == .string("auto") && o["destination"] == .string("Cursor"))
            let bad = try await curatorCmd(d, p, ["provider": .string("ollama")])
            #expect(bad.error?.code == .invalidArgs, "\(bad)")
        }
    }

    @Test func nonAdminRefused() async throws {
        try await withDaemon(configure: { $0.curatorRunner = FakeCurator() }) { d, p in
            let t = try await spawn(d, p, "W")
            let tok = try await tokenOf(d, t.id)
            for args: [String: JSONValue] in [[:], ["consent": .string("cursor")], ["test": .bool(true)]] {
                let r = try await send(p, Request(id: "t", terminalId: t.id, token: tok, command: "memory.curator", args: args))
                #expect(r.error?.code == .unauthorized, "\(r)")
            }
        }
    }

    @Test func testSpendsNothing() async throws {
        let fake = FakeCurator()
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let r = try await curatorCmd(d, p, ["test": .bool(true)])
            guard case .object(let o)? = r.result, case .object(let t)? = o["test"] else { Issue.record("\(r)"); return }
            #expect(t["availability"] == .string("disponível") && t["models"] == .array([]))
            #expect(fake.calls == 0 && o["today"] == .number(0))
        }
    }

    @Test func testCallSpendsThree() async throws {
        let fake = FakeCurator()   // answers {"ops":[]}: right for the ops format only
        try await withDaemon(configure: { $0.curatorRunner = fake }) { d, p in
            let r = try await curatorCmd(d, p, ["testCall": .bool(true)])
            guard case .object(let o)? = r.result, case .array(let calls)? = o["testCall"] else { Issue.record("\(r)"); return }
            #expect(calls == [.object(["format": .string("ops"), "result": .string("ok")]),
                              .object(["format": .string("items"), "result": .string("junk")]),
                              .object(["format": .string("chunks"), "result": .string("junk")])])
            #expect(fake.calls == 3 && o["today"] == .number(3))
        }
    }

    /// Every provider of this build, registered or not, with installed (no token spent), availability and its reason.
    @Test func providersListed() async throws {
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runners: [.claude: fake], clock: ManualClock(), installed: { $0 == .claude })
        var s = await c.status()
        #expect(s.providers.map(\.provider) == CuratorProvider.allCases.map(\.rawValue))
        #expect(s.providers[0] == CuratorProviderStatus(provider: "claude", installed: true, available: true, availability: "disponível",
                                                       consentNeeded: false, destination: "Anthropic"))
        #expect(s.providers[1] == CuratorProviderStatus(provider: "cursor", installed: false, available: false,
                                                       availability: "provedor ainda não habilitado nesta versão",
                                                       consentNeeded: false, destination: "Cursor"))
        await #expect(throws: ProtocolError(code: .unavailable, message: "provedor ainda não habilitado nesta versão")) {
            await c.consent(.cursor); try await c.setProvider(.cursor, model: nil)
        }
        fake.avail = .unavailable("claude não encontrado")
        s = await c.status()
        #expect(s.providers[0].availability == "claude não encontrado" && !s.providers[0].available && fake.calls == 0)
    }

    /// A login billed per use (or not recognized) curates only once its consent is on file, Claude's too.
    @Test func meteredNeedsConsent() async throws {
        let fake = FakeCurator()
        fake.bills = .metered("conta de API (cobrança por token)")
        let c = Curator(dir: tempDir(), runners: [.claude: fake], clock: ManualClock(), installed: { _ in true })
        var s = await c.status()
        let why = "Claude: login com cobrança por uso ou não reconhecido; consentimento necessário"
        #expect(!s.available && s.reason == why && s.providers[0].consentNeeded && s.providers[0].availability == why)
        await c.consent(.claude)
        s = await c.status()
        #expect(s.available && !s.providers[0].consentNeeded)
    }

    /// R8: a flood of other jobs stops at cap − cap/4; the reserved rest is the corrections'.
    @Test func reviewFloodCantBlockCorrection() async throws {
        let fake = FakeCurator()
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        await c.setCap(40)
        for _ in 0..<35 { _ = await c.enqueue(job(.pitfall)) }
        await c.start(handler: oneCall)
        #expect(await waitFor(10) { fake.calls == 30 })
        try await Task.sleep(for: .milliseconds(200))
        let left = await c.queued(kind: .pitfall)
        #expect(fake.calls == 30 && left.count == 5)
        #expect(await c.enqueue(job(.correction)))
        #expect(await waitFor(10) { await c.queued(kind: .correction).isEmpty })
        #expect(fake.calls == 31)
        await c.stop()
    }
}
