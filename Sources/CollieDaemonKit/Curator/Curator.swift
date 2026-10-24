import Foundation
import CollieCore
import CollieProtocol

/// In priority order: a correction runs first, then proposals, pitfalls, consolidation, noticed procedures.
enum CuratorJobKind: String, Codable, Sendable, CaseIterable {
    case correction, proposals, pitfall, consolidate, procedure
    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

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
    /// Jobs parked in `failed/` (3 failed attempts, or an unreadable file).
    var failed: Int
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

/// One job at a time from a durable queue (`<dir>/jobs/<createdAt ms>-<id>.json`, 0600 in 0700 dirs), by kind priority.
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
    /// Jobs whose last attempt failed → the tick count at that failure: retried after a later tick, not on every enqueue
    /// (a tick that came during the failing run doesn't count).
    private var backoff: [UUID: Int] = [:], ticks = 0
    /// The file each job was loaded from or written to (a name recomputed from a decoded date could miss it).
    private var names: [UUID: String] = [:]

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
            if let j = (try? Data(contentsOf: u)).flatMap({ try? Self.decoder.decode(CuratorJob.self, from: $0) }) {
                // R9: attempts are saved before each run, so a job that crashed the daemon on its last one is parked here
                if j.attempts >= Self.maxAttempts {
                    FileHandle.standardError.write(Data("collied: curator: job \(n) crashed \(j.attempts) runs, moved to failed/\n".utf8))
                    _ = rename(u.path, dir.appendingPathComponent("failed/\(n)").path)
                    continue
                }
                jobs.append(j); self.names[j.id] = n; continue
            }
            // an unknown kind (a later Collie's) or a damaged file: kept aside, never run
            FileHandle.standardError.write(Data("collied: curator: unreadable job \(n) moved to failed/\n".utf8))
            _ = rename(u.path, dir.appendingPathComponent("failed/\(n)").path)
        }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = .sortedKeys; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()

    private func file(_ j: CuratorJob) -> URL {
        if names[j.id] == nil { names[j.id] = "\(Int64(j.createdAt.timeIntervalSince1970 * 1000))-\(j.id.uuidString).json" }
        return dir.appendingPathComponent("jobs/\(names[j.id]!)")
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

    /// Drops a queued job (a running one finishes; its handler sees the change).
    func cancel(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        remove(j)
        recent[j.dedupe] = now()
    }

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
                             failed: ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path)) ?? [])
                                 .filter { $0.hasSuffix(".json") }.count,
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

    private func tickWake() { ticks += 1; wake() }

    private func wake() {
        if let w = waiter { waiter = nil; w.resume() } else { woken = true }
    }

    private func sleepUntilWoken() async {
        if woken { woken = false; return }
        await withCheckedContinuation { waiter = $0 }
    }

    private func run() async {
        while !Task.isCancelled {
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

    /// R8: the last quarter of the daily cap is the corrections' (40: the others stop at 30).
    static func limit(_ cap: Int, for kind: CuratorJobKind) -> Int { kind == .correction ? cap : cap - cap / 4 }

    private func capReason(_ kind: CuratorJobKind = .correction) -> String? {
        if config.cap == 0 { return "desligado" }
        rollDay()
        if usage.today >= config.cap { return "limite diário atingido (\(config.cap))" }
        return usage.today >= Self.limit(config.cap, for: kind) ? "resto do limite diário reservado às correções" : nil
    }

    /// By kind (`CuratorJobKind.priority`), then oldest; a failed job waits for the next tick.
    private func drain() async {
        while !Task.isCancelled, let handler {
            let next = jobs.filter { (backoff[$0.id].map { $0 < ticks } ?? true) && capReason($0.kind) == nil }
                .min { ($0.kind.priority, $0.createdAt) < ($1.kind.priority, $1.createdAt) }
            guard let job = next, await runner.availability() == .available else { return }
            count(job, +1)   // R9: on disk before the run (a crash still counts)
            do {
                try await handler(job, { c throws(ProtocolError) in try await self.call(c, kind: job.kind) })
                remove(job)
                recent[job.dedupe] = now()
            } catch let e as ProtocolError where e.code == .unavailable {
                count(job, -1)
                return   // logged out / cap mid-run (before any run): the job waits, no attempt spent
            } catch {
                backoff[job.id] = ticks
                fail(job)
            }
        }
    }

    private func count(_ job: CuratorJob, _ d: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].attempts += d
        write(jobs[i], to: file(job))
    }

    /// The attempt was counted before the run.
    private func fail(_ job: CuratorJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if jobs[i].attempts >= Self.maxAttempts {
            write(jobs[i], to: dir.appendingPathComponent("failed/\(file(job).lastPathComponent)"))
            remove(job)
            recent[job.dedupe] = now()
        }
    }

    private func remove(_ job: CuratorJob) {
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: file(job))
        names[job.id] = nil; backoff[job.id] = nil
    }

    /// One runner call: the input cut to `inputMax` unicode scalars (≤ 48 KB of argv), counted against today's cap,
    /// usage persisted. R7: only the cap waits; any failure of the run itself (nonzero exit, `is_error`, junk, timeout)
    /// is rethrown as `.internal`, so it spends an attempt — a poison job reaches `failed/` instead of heading the queue.
    private func call(_ c: CuratorCall, kind: CuratorJobKind) async throws(ProtocolError) -> CuratorOutput {
        if let why = capReason(kind) { throw ProtocolError(code: .unavailable, message: why) }
        var c = c
        c.input = String(String.UnicodeScalarView(c.input.unicodeScalars.prefix(Self.inputMax)))
        usage.today += 1
        write(usage, to: dir.appendingPathComponent("usage.json"))
        let out: CuratorOutput
        do { out = try await runner.run(c, model: config.model, timeout: Self.timeout) } catch {
            throw error.code == .unavailable ? ProtocolError(code: .internal, message: error.message) : error
        }
        usage.inputTokens += out.inputTokens; usage.outputTokens += out.outputTokens; usage.costUSD += out.costUSD
        write(usage, to: dir.appendingPathComponent("usage.json"))
        return out
    }
}
