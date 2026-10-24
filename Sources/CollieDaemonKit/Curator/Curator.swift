import Foundation
import CollieCore
import CollieProtocol

enum CuratorJobKind: String, Codable, Sendable { case correction, proposals }

/// A queued curator job; `store` is the store family's key (`RepoMemory.key`).
struct CuratorJob: Codable, Sendable, Identifiable {
    var id: UUID
    var kind: CuratorJobKind
    var store: String
    var payload: JSONValue
    var dedupe: String
    var createdAt: Date
    var attempts: Int
}

/// The Memory panel's line: why it can't run (`curador indisponível: <reason>`), today's jobs and the running token count.
struct CuratorStatus: Codable, Sendable {
    var available: Bool
    var reason: String?
    var today: Int
    var cap: Int
    var queued: Int
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

/// One job at a time from a durable queue (`<dir>/jobs/<createdAt ms>-<id>.json`, 0600 in 0700 dirs), corrections first.
/// Runs on an enqueue, a cap change or the 10-minute tick; stops while the daily cap is reached, the cap is 0 or the
/// runner is unavailable (jobs wait). A job whose handler fails `maxAttempts` times goes to `failed/`.
actor Curator {
    typealias Call = @Sendable (CuratorCall) async throws(ProtocolError) -> CuratorOutput
    typealias Handler = @Sendable (CuratorJob, Call) async throws -> Void

    static let tick: Duration = .seconds(600)
    static let inputMax = 12_000
    static let timeout: Duration = .seconds(60)
    static let maxAttempts = 3
    static let queueMax = 200
    static let dedupeWindow: TimeInterval = 60

    struct Config: Codable { var cap = 40; var model = "haiku" }
    struct Usage: Codable { var day = ""; var today = 0; var inputTokens = 0; var outputTokens = 0; var costUSD = 0.0 }

    private let dir: URL, runner: any CuratorRunner, clock: any Clock<Duration>, now: @Sendable () -> Date
    private var jobs: [CuratorJob] = []
    private var config = Config(), usage = Usage()
    /// dedupe key → when last enqueued or finished (in memory: a restart forgets the 60 s window)
    private var recent: [String: Date] = [:]
    private var handler: Handler?
    private var loop: Task<Void, Never>?, ticker: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?, woken = false
    /// Jobs whose last attempt failed: retried on the next tick, not on every enqueue.
    private var backoff: Set<UUID> = [], ticked = false

    init(dir: URL, runner: any CuratorRunner, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = Date.init) {
        self.dir = dir; self.runner = runner; self.clock = clock; self.now = now
        let fm = FileManager.default
        for d in [dir, dir.appendingPathComponent("jobs"), dir.appendingPathComponent("failed")] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(d.path, 0o700)
        }
        func load<T: Decodable>(_ name: String) -> T? {
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? Self.decoder.decode(T.self, from: $0) }
        }
        config = load("config.json") ?? Config()
        usage = load("usage.json") ?? Usage()
        let names = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("jobs").path)) ?? []
        for n in names.sorted() where n.hasSuffix(".json") {
            let u = dir.appendingPathComponent("jobs/\(n)")
            if let j = (try? Data(contentsOf: u)).flatMap({ try? Self.decoder.decode(CuratorJob.self, from: $0) }) { jobs.append(j); continue }
            // an unknown kind (a later Collie's) or a damaged file: kept aside, never run
            FileHandle.standardError.write(Data("collied: curator: unreadable job \(n) moved to failed/\n".utf8))
            _ = rename(u.path, dir.appendingPathComponent("failed/\(n)").path)
        }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = .sortedKeys; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()

    private func file(_ j: CuratorJob) -> URL {
        dir.appendingPathComponent("jobs/\(Int64(j.createdAt.timeIntervalSince1970 * 1000))-\(j.id.uuidString).json")
    }

    /// Temp + rename (like `MemoryStore.write`), 0600.
    private func write(_ v: some Encodable, to dest: URL) {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let data = try? Self.encoder.encode(v),
              FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, dest.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            FileHandle.standardError.write(Data("collied: curator: cannot write \(dest.lastPathComponent)\n".utf8))
            return
        }
    }

    /// false: a duplicate (same `dedupe` queued, or seen within 60 s), or the queue is full (a correction evicts the
    /// oldest proposals job instead).
    func enqueue(_ j: CuratorJob) -> Bool {
        let t = now()
        if jobs.contains(where: { $0.dedupe == j.dedupe }) { return false }
        if let seen = recent[j.dedupe], t.timeIntervalSince(seen) < Self.dedupeWindow { return false }
        if jobs.count >= Self.queueMax {
            guard j.kind == .correction,
                  let old = jobs.filter({ $0.kind == .proposals }).min(by: { $0.createdAt < $1.createdAt }) else { return false }
            remove(old)
        }
        recent = recent.filter { t.timeIntervalSince($0.value) < Self.dedupeWindow }
        recent[j.dedupe] = t
        jobs.append(j)
        write(j, to: file(j))
        wake()
        return true
    }

    func queued(kind: CuratorJobKind) -> [CuratorJob] { jobs.filter { $0.kind == kind } }

    func setCap(_ n: Int) {
        config.cap = max(0, n)
        write(config, to: dir.appendingPathComponent("config.json"))
        wake()
    }

    func status() async -> CuratorStatus {
        rollDay()
        var reason = capReason()
        if reason == nil, case .unavailable(let why) = await runner.availability() { reason = why }
        rollDay()
        return CuratorStatus(available: reason == nil, reason: reason, today: usage.today, cap: config.cap, queued: jobs.count,
                             inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, costUSD: usage.costUSD)
    }

    func start(handler: @escaping Handler) {
        guard loop == nil else { return }
        self.handler = handler
        loop = Task { await self.run() }
        let clock = self.clock
        ticker = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.tick) } catch { return }
                await self.tickWake()
            }
        }
    }

    func stop() {
        loop?.cancel(); ticker?.cancel(); loop = nil; ticker = nil; handler = nil   // the handler holds the router
        waiter?.resume(); waiter = nil
    }

    /// Clears `backoff` at the next pass, not now (a drain in progress may still be adding the job it just failed).
    private func tickWake() { ticked = true; wake() }

    private func wake() {
        if let w = waiter { waiter = nil; w.resume() } else { woken = true }
    }

    private func sleepUntilWoken() async {
        if woken { woken = false; return }
        await withCheckedContinuation { waiter = $0 }
    }

    private func run() async {
        while !Task.isCancelled {
            if ticked { ticked = false; backoff = [] }
            await drain()
            await sleepUntilWoken()
        }
    }

    /// Local calendar day.
    private func day() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func rollDay() { let d = day(); if usage.day != d { usage.day = d; usage.today = 0 } }

    private func capReason() -> String? {
        if config.cap == 0 { return "desligado" }
        rollDay()
        return usage.today >= config.cap ? "limite diário atingido (\(config.cap))" : nil
    }

    /// Corrections first, then oldest; a failed job waits for the next tick.
    private func drain() async {
        while !Task.isCancelled, let handler {
            let next = jobs.filter { !backoff.contains($0.id) }
                .min { ($0.kind == .correction ? 0 : 1, $0.createdAt) < ($1.kind == .correction ? 0 : 1, $1.createdAt) }
            guard let job = next, capReason() == nil, await runner.availability() == .available else { return }
            do {
                try await handler(job, { c throws(ProtocolError) in try await self.call(c) })
                remove(job)
                recent[job.dedupe] = now()
            } catch let e as ProtocolError where e.code == .unavailable {
                return   // logged out / cap mid-run: the job waits, no attempt spent
            } catch {
                backoff.insert(job.id)
                fail(job)
            }
        }
    }

    private func fail(_ job: CuratorJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].attempts += 1
        if jobs[i].attempts >= Self.maxAttempts {
            write(jobs[i], to: dir.appendingPathComponent("failed/\(file(job).lastPathComponent)"))
            remove(job)
            recent[job.dedupe] = now()
        } else {
            write(jobs[i], to: file(job))
        }
    }

    private func remove(_ job: CuratorJob) {
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: file(job))
    }

    /// One runner call: the input cut to `inputMax` characters, counted against today's cap, usage persisted.
    private func call(_ c: CuratorCall) async throws(ProtocolError) -> CuratorOutput {
        if let why = capReason() { throw ProtocolError(code: .unavailable, message: why) }
        var c = c
        c.input = String(c.input.prefix(Self.inputMax))
        usage.today += 1
        write(usage, to: dir.appendingPathComponent("usage.json"))
        let out = try await runner.run(c, model: config.model, timeout: Self.timeout)
        usage.inputTokens += out.inputTokens; usage.outputTokens += out.outputTokens; usage.costUSD += out.costUSD
        write(usage, to: dir.appendingPathComponent("usage.json"))
        return out
    }
}

extension CommandRouter {
    /// A job's work (Tasks 5/6 fill each kind). ponytail: until then a job waits (unavailable spends no attempt).
    func curate(_ job: CuratorJob, _ call: Curator.Call) async throws {
        throw ProtocolError(code: .unavailable, message: "sem tratador para \(job.kind.rawValue)")
    }
}
