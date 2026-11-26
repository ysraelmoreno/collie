import Foundation
import CollieCore
import CollieProtocol

/// In priority order: a correction runs first, then the re-check of a contested memory, the promotion gate, proposals,
/// pitfalls, conversations, consolidation, noticed procedures. Raw values are on disk (queued jobs): never rename one.
enum CuratorJobKind: String, Codable, Sendable, CaseIterable {
    case correction, verifyContested, verifyPromotion, proposals, pitfall, conversation, consolidate, procedure, docTerms
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
    /// The daily job cap; nil: none (the default). 0: off.
    var cap: Int?
    var queued: Int
    /// Jobs parked in `failed/` (3 failed attempts, or an unreadable file) in the last `Curator.failedKeep`: older ones are deleted,
    /// so the app's "curador falhando" alert goes away once the curator works again.
    var failed: Int
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    /// The chosen curator (`CuratorProvider`), its model (`""`: its default), trust and where its data goes.
    var provider = "claude"
    var model = "haiku"
    var trust = "full"
    var destination = "Anthropic"
    /// Every provider this build knows (Task 12), chosen or not: what the Preferences picker shows.
    var providers: [CuratorProviderStatus] = []
}

/// One provider in the picker: installed (its CLI found, no token spent), available now and, when not, why;
/// `consentNeeded`: choosing it opens the consent sheet first.
struct CuratorProviderStatus: Codable, Sendable, Equatable {
    var provider: String
    var installed: Bool
    var available: Bool
    /// "disponível", or the reason it isn't ("claude não encontrado", "claude sem login", …).
    var availability: String
    var consentNeeded: Bool
    var destination: String
}

/// One job at a time from a durable queue (`<dir>/jobs/<createdAt ms>-<id>.json`, 0600 in 0700 dirs), by kind priority.
/// Runs on an enqueue, a cap change or the 10-minute tick; stops while the daily cap is reached, the cap is 0 or the
/// runner is unavailable (jobs wait). A job whose handler fails `maxAttempts` times goes to `failed/`.
/// How a job's answer read (Task 9): `junk` = not the expected shape, `allDropped` = every op dropped by validation.
/// An empty answer (`{"ops":[]}`, `{"items":[]}`, `{"chunks":[]}`) is `ok`.
enum CuratorJobResult: Sendable, Equatable { case ok, junk, allDropped }

actor Curator {
    typealias Call = @Sendable (CuratorCall) async throws(ProtocolError) -> CuratorOutput
    /// The router's: the job, its one-call door, the chosen provider's input cap; how the answer read.
    typealias JobHandler = @Sendable (CuratorJob, Call, _ inputMax: Int) async throws -> CuratorJobResult
    /// Tests' shorthand (every answer `ok`).
    typealias Handler = @Sendable (CuratorJob, Call) async throws -> Void
    /// A handler throws this for an answer it can't read: it spends an attempt and counts toward the pause.
    static func junk(_ what: String) -> ProtocolError { ProtocolError(code: .internal, message: "curator: junk answer (\(what))") }
    static let pauseWindow = 20, pauseBad = 10

    static let tick: Duration = .seconds(600)
    static let inputMax = 12_000
    static let timeout: Duration = .seconds(60)
    static let maxAttempts = 3
    /// How long a parked job stays in `failed/` (kept to be looked at, never retried); then `pruneFailed` deletes it.
    static let failedKeep: TimeInterval = 7 * 86_400

    /// Deletes the `failed/*.json` last modified more than `failedKeep` before `now`.
    static func pruneFailed(_ dir: URL, now: Date) {
        let fm = FileManager.default
        for n in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) where n.hasSuffix(".json") {
            let u = dir.appendingPathComponent(n)
            guard let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) > failedKeep else { continue }
            try? fm.removeItem(at: u)
        }
    }
    /// ma4 2a: the consolidation pass calls this each cycle, so a parked job leaves `failed/` without a restart.
    func pruneFailed(now t: Date) { Self.pruneFailed(dir.appendingPathComponent("failed"), now: t) }
    static let queueMax = 200
    static let dedupeWindow: TimeInterval = 60

    /// `model` stays Claude's (an older daemon reads only `cap` and `model`). E7: each field decoded on its own — missing or
    /// of a wrong type is its default, an unknown provider is `claude` — so an older file keeps its cap, and an older
    /// daemon's rewrite (only `cap`/`model`) falls back to Claude with nothing consented (the safe side).
    struct Config: Codable {
        static let providers: Set = ["claude", "cursor"]
        /// Jobs a day; nil (missing, or of a wrong type): no cap, the default. 0: off.
        var cap: Int?
        var model = "haiku"
        var provider = "claude"
        /// Provider → model (`""` or missing: the provider's default).
        var models: [String: String] = [:]
        /// Providers other than Claude the user confirmed sending data to.
        var consented: [String] = []

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
            cap = (try? c.decodeIfPresent(Int.self, forKey: .cap)) ?? nil; model = field(.model, model); models = field(.models, models); consented = field(.consented, consented)
            let p = field(.provider, provider)
            provider = Self.providers.contains(p) ? p : "claude"
        }
    }
    struct Usage: Codable { var day = ""; var today = 0; var inputTokens = 0; var outputTokens = 0; var costUSD = 0.0 }

    let dir: URL
    private let runners: [CuratorProvider: any CuratorRunner], clock: any Clock<Duration>, now: @Sendable () -> Date
    /// Each call is a `curatorRun` event (nil: not logged).
    private let events: MemoryEventLog?
    /// Its CLI is on the user's PATH or in a known dir (`BinaryLocator`); never runs it.
    private let installed: @Sendable (CuratorProvider) async -> Bool
    private var jobs: [CuratorJob] = []
    private var config = Config(), usage = Usage()
    /// dedupe key → when last enqueued or finished (in memory: a restart forgets the 60 s window)
    private var recent: [String: Date] = [:]
    private var handler: JobHandler?
    /// The chosen provider's last `pauseWindow` calls (true: bad). In memory: a restart starts afresh.
    private var outcomes: [CuratorProvider: [Bool]] = [:]
    /// Runner calls made (a job that never called adds nothing to `outcomes`).
    private var calls = 0
    private var loop: Task<Void, Never>?, ticker: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?, woken = false
    /// Jobs whose last attempt failed → the tick count at that failure: retried after a later tick, not on every enqueue
    /// (a tick that came during the failing run doesn't count).
    private var backoff: [UUID: Int] = [:], ticks = 0
    /// The file each job was loaded from or written to (a name recomputed from a decoded date could miss it).
    private var names: [UUID: String] = [:]

    /// One runner: the only provider it knows is its own.
    init(dir: URL, runner: any CuratorRunner, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = Date.init,
         events: MemoryEventLog? = nil) {
        self.init(dir: dir, runners: [runner.info.provider: runner], clock: clock, now: now, events: events)
    }

    init(dir: URL, runners: [CuratorProvider: any CuratorRunner], clock: any Clock<Duration> = ContinuousClock(),
         now: @escaping @Sendable () -> Date = Date.init, events: MemoryEventLog? = nil,
         installed: @escaping @Sendable (CuratorProvider) async -> Bool = {
             BinaryLocator.locate($0.binary, env: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) != nil }) {
        self.dir = dir; self.runners = runners; self.clock = clock; self.now = now; self.events = events; self.installed = installed
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
        Self.pruneFailed(dir.appendingPathComponent("failed"), now: now())
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

    /// The chosen provider (config.json; an unknown one already read as Claude).
    private var provider: CuratorProvider { CuratorProvider(rawValue: config.provider) ?? .claude }
    /// The chosen provider's model (`""`: its default). Claude's stays in `model` (older daemons read it).
    private func model(_ p: CuratorProvider) -> String { p == .claude ? config.model : config.models[p.rawValue] ?? "" }
    /// The chosen runner's info; a provider this build has no runner for is shown as limited, its data going to it.
    var active: CuratorProviderInfo {
        runners[provider]?.info ?? CuratorProviderInfo(provider: provider, trust: .limited, destination: provider.rawValue.capitalized,
                                                       structuredOutput: false, reportsUsage: false, timeout: Self.timeout,
                                                       inputMax: Self.inputMax)
    }

    /// Claude needs no consent (it is today's curator); any other provider only after `consent`. `model` nil keeps the
    /// stored one. The running job finishes on the old provider; the next ones go to the new one.
    static let badModel = "modelo inválido: use letras, números e . _ : / - (começando por letra ou número)"
    /// Review A6: a model id (`""`: the provider's default) can never read as a flag or carry a space or newline.
    static func validModel(_ m: String) -> Bool { m.isEmpty || m.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/-]*/) != nil }

    func setProvider(_ p: CuratorProvider, model m: String?) throws(ProtocolError) {
        if let m, !Self.validModel(m) { throw ProtocolError(code: .invalidArgs, message: Self.badModel) }
        guard p == .claude || config.consented.contains(p.rawValue) else {
            throw ProtocolError(code: .unavailable, message: "falta confirmar nas Preferências")
        }
        guard runners[p] != nil else { throw ProtocolError(code: .unavailable, message: Self.notInBuild) }
        config.provider = p.rawValue
        if let m { if p == .claude { config.model = m } else { config.models[p.rawValue] = m } }
        outcomes[p] = nil   // another provider or model: the pause starts afresh
        write(config, to: dir.appendingPathComponent("config.json"))
        wake()
    }

    /// The user confirmed sending data to `p` (the consent sheet).
    func consent(_ p: CuratorProvider) {
        guard !config.consented.contains(p.rawValue) else { return }
        config.consented.append(p.rawValue)
        write(config, to: dir.appendingPathComponent("config.json"))
    }

    static let notInBuild = "provedor ainda não habilitado nesta versão"
    static let consentMissing = "falta confirmar nas Preferências"

    /// The chosen provider's availability: unconsented or missing in this build is unavailable, never run.
    private func availability() async -> CuratorAvailability { await availability(provider).0 }

    /// `p`'s availability (no token: the runner's cached login check) and whether only a consent stands in the way.
    /// The runner's own reason comes first (not installed, logged out): consenting wouldn't fix those.
    private func availability(_ p: CuratorProvider) async -> (CuratorAvailability, consentNeeded: Bool) {
        guard let r = runners[p] else { return (.unavailable(Self.notInBuild), false) }
        let a = await r.availability()
        guard a == .available else { return (a, false) }
        let consented = config.consented.contains(p.rawValue)
        guard p == .claude || consented else { return (.unavailable(Self.consentMissing), true) }
        let w = outcomes[p] ?? [], bad = w.filter { $0 }.count
        if bad >= Self.pauseBad { return (.unavailable("saída inválida em \(bad) de \(w.count) (troque de modelo)"), false) }
        let admitted = Self.admit(await r.billing(), provider: p, consented: consented)
        return (admitted, admitted != .available)
    }

    /// The billing policy (spec 2026-11-17 E3), the same for every provider: a login billed in a plan curates; one
    /// billed per use, or not recognized, only with that provider's consent on file (Task 12: no silent token billing).
    static func admit(_ b: CuratorBilling, provider p: CuratorProvider, consented: Bool) -> CuratorAvailability {
        if case .included = b { return .available }
        if consented { return .available }
        return .unavailable("\(p.rawValue.capitalized): login com cobrança por uso ou não reconhecido; consentimento necessário")
    }

    /// Every provider of this build, in `allCases` order (the picker's).
    private func providerStatuses() async -> [CuratorProviderStatus] {
        var out: [CuratorProviderStatus] = []
        for p in CuratorProvider.allCases {
            let (a, consent) = await availability(p)
            let why: String = switch a {
            case .available: "disponível"
            case .unavailable(let w): w
            case .exhausted(let w, _): w
            }
            out.append(CuratorProviderStatus(provider: p.rawValue, installed: await installed(p), available: a == .available,
                                             availability: why, consentNeeded: consent,
                                             destination: runners[p]?.info.destination ?? p.rawValue.capitalized))
        }
        return out
    }

    /// "Testar agora": the chosen provider's availability and model list; zero generation.
    func test() async -> (availability: String, models: [String]) {
        let why: String = switch await availability() {
        case .available: "disponível"
        case .unavailable(let w): w
        case .exhausted(let w, _): w
        }
        return (why, await runners[provider]?.models() ?? [])
    }

    /// "Testar com uma chamada": one synthetic call per answer format through `call` (each counts in today's cap and is
    /// logged with `test: true`, outside the stats' runs and failures: ma4 2d); nothing is applied. `ok`: the answer has the format's list; `junk`: it doesn't; else the error's text.
    func testCalls() async throws(ProtocolError) -> [(format: String, result: String)] {
        if case .unavailable(let why) = await availability() { throw ProtocolError(code: .unavailable, message: why) }
        let instructions = "Isto é um teste do Collie, sem dados reais. Responda só com a lista vazia."
        var out: [(String, String)] = []
        for (key, schema) in [("ops", CuratorOps.schema), ("items", ConversationCapture.schema), ("chunks", DocTerms.schema)] {
            let job = CuratorJob(id: UUID(), kind: .correction, store: "", payload: .null, dedupe: "", createdAt: now(), attempts: 0)
            do throws(ProtocolError) {
                let o = try await call(CuratorCall(instructions: instructions, input: "teste", schema: schema), job: job, test: true)
                if case .object(let x) = o.json, case .array? = x[key] { out.append((key, "ok")) } else { out.append((key, "junk")) }
            } catch {
                out.append((key, String(error.message.prefix(200))))
            }
        }
        return out
    }

    /// nil: no daily cap.
    func setCap(_ n: Int?) {
        config.cap = n.map { max(0, $0) }
        write(config, to: dir.appendingPathComponent("config.json"))
        wake()
    }

    func status() async -> CuratorStatus {
        rollDay()
        var reason = capReason()
        if reason == nil {
            switch await availability() {
            case .available: break
            case .unavailable(let why): reason = why
            case .exhausted(_, let until):
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                reason = "cota do \(provider.rawValue) esgotada até " + f.string(from: until ?? now().addingTimeInterval(ClaudeCuratorRunner.exhaustedFor))
            }
        }
        rollDay()
        return CuratorStatus(available: reason == nil, reason: reason, today: usage.today, cap: config.cap, queued: jobs.count,
                             failed: ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path)) ?? [])
                                 .filter { $0.hasSuffix(".json") }.count,
                             inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, costUSD: usage.costUSD,
                             provider: provider.rawValue, model: model(provider), trust: active.trust.rawValue, destination: active.destination,
                             providers: await providerStatuses())
    }

    func start(handler: @escaping Handler) { start(job: { j, call, _ in try await handler(j, call); return .ok }) }

    func start(job handler: @escaping JobHandler) {
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
        rollDay()   // first, cap or not: `call` counts into today right after this
        guard let cap = config.cap else { return nil }   // no cap: nothing to reach, nothing to hold back
        if cap == 0 { return "desligado" }
        if usage.today >= cap { return "limite diário atingido (\(cap))" }
        return usage.today >= Self.limit(cap, for: kind) ? "resto do limite diário reservado às correções" : nil
    }

    /// By kind (`CuratorJobKind.priority`), then oldest; a failed job waits for the next tick.
    private func drain() async {
        while !Task.isCancelled, let handler {
            let next = jobs.filter { (backoff[$0.id].map { $0 < ticks } ?? true) && capReason($0.kind) == nil }
                .min { ($0.kind.priority, $0.createdAt) < ($1.kind.priority, $1.createdAt) }
            guard let job = next, await availability() == .available else { return }
            count(job, +1)   // R9: on disk before the run (a crash still counts)
            let p = provider, before = calls
            do {
                let r = try await handler(job, { c throws(ProtocolError) in try await self.call(c, job: job) }, active.inputMax)
                if calls > before { note(p, bad: r != .ok) }
                remove(job)
                recent[job.dedupe] = now()
            } catch let e as ProtocolError where e.code == .unavailable {
                count(job, -1)
                return   // logged out / cap mid-run (before any run): the job waits, no attempt spent
            } catch {
                if (error as? ProtocolError)?.message.hasPrefix("curator: junk answer") == true { note(p, bad: true) }
                backoff[job.id] = ticks
                fail(job)
            }
        }
    }

    private func note(_ p: CuratorProvider, bad: Bool) {
        var w = outcomes[p, default: []]
        w.append(bad)
        outcomes[p] = Array(w.suffix(Self.pauseWindow))
    }

    /// `s` within `max` unicode scalars, cut inside its fence: the data before the closing `DADOS-<nonce>` mark loses its
    /// end, both marks stay. nil: too long with no fence, or not even the opening mark fits.
    static func fit(_ s: String, max: Int) -> String? {
        if s.unicodeScalars.count <= max { return s }
        guard let close = s.matches(of: /DADOS-[0-9a-f]{32}/).last?.range,
              let open = s.range(of: String(s[close])), open.lowerBound < close.lowerBound else { return nil }
        let tail = s[close.lowerBound...], room = max - tail.unicodeScalars.count - 1
        guard room >= s[..<open.upperBound].unicodeScalars.count else { return nil }
        return String(String.UnicodeScalarView(s[..<close.lowerBound].unicodeScalars.prefix(room))) + "\n" + tail
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
            Self.pruneFailed(dir.appendingPathComponent("failed"), now: now())
            remove(job)
            recent[job.dedupe] = now()
        }
    }

    private func remove(_ job: CuratorJob) {
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: file(job))
        names[job.id] = nil; backoff[job.id] = nil
    }

    /// A failure that says nothing about the job: the sandbox blocked the CLI, there is no network or name resolution, or its
    /// workspace folder is gone. Retried later without spending an attempt (63 jobs once went to `failed/` in a day on a DNS error).
    static func isEnvironmentFailure(_ message: String) -> Bool {
        ["curador bloqueado pelo sandbox", "getaddrinfo", "enotfound", "eai_again", "econnrefused", "enetunreach", "enetdown",
         "could not resolve host", "network is unreachable", "workspace directory does not exist"]
            .contains { message.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// One runner call: the input cut to `inputMax` unicode scalars (≤ 48 KB of argv), counted against today's cap,
    /// usage persisted. R7: only the cap waits; any failure of the run itself (nonzero exit, `is_error`, junk, timeout)
    /// is rethrown as `.internal`, so it spends an attempt — a poison job reaches `failed/` instead of heading the queue.
    /// Two exceptions wait without spending one: the runner exhausted (quota) and an environment failure (the provider
    /// unavailable, or `isEnvironmentFailure`); the latter counts as a bad call, so a provider that never works gets paused.
    private func call(_ c: CuratorCall, job: CuratorJob, test: Bool = false) async throws(ProtocolError) -> CuratorOutput {
        if let why = capReason(job.kind) { throw ProtocolError(code: .unavailable, message: why) }
        // the provider is fixed for this call: a switch meanwhile takes the next one
        let p = provider, m = model(p)
        guard let runner = runners[p] else { throw ProtocolError(code: .unavailable, message: "\(p.rawValue) não encontrado") }
        let info = runner.info
        var c = c
        // never a cut outside the fence (the closing mark would go): over the cap with no fence, the job fails
        guard let fitted = Self.fit(c.input, max: info.inputMax) else { throw ProtocolError(code: .internal, message: "curator: input over limit") }
        c.input = fitted
        calls += 1
        usage.today += 1
        write(usage, to: dir.appendingPathComponent("usage.json"))
        let out: CuratorOutput, started = ContinuousClock.now
        func logged(_ ok: Bool, _ reason: String?, _ o: CuratorOutput?) {
            let d = ContinuousClock.now - started
            var e = MemoryEvent(type: .curatorRun, job: job.kind.rawValue, ok: ok, reason: reason, inputTokens: o?.inputTokens,
                                outputTokens: o?.outputTokens, costUSD: o?.costUSD,
                                durationMs: Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000))
            e.provider = p.rawValue; e.model = m; e.test = test ? true : nil
            e.place(store: job.store)
            events?.emit(e)
        }
        do {
            var o = try await runner.run(c, model: m, timeout: info.timeout)
            o.curatedBy = CuratedBy(provider: p.rawValue, model: m, trust: info.trust)
            out = o
        } catch {
            logged(false, String(error.message.prefix(200)), nil)
            if error.message.hasPrefix("resposta ilegível") { note(p, bad: true) }   // the runner couldn't read it either
            // E6: a credit/quota refusal left the runner exhausted: the job waits, no attempt spent (`drain` gives it back)
            if case .exhausted = await runner.availability() { throw ProtocolError(code: .unavailable, message: error.message) }
            // not this job's fault: the CLI cannot run here (no login, blocked, no network); it waits and is not marked failed
            if case .unavailable = await runner.availability() { throw ProtocolError(code: .unavailable, message: error.message) }
            if Self.isEnvironmentFailure(error.message) { note(p, bad: true); throw ProtocolError(code: .unavailable, message: error.message) }
            throw error.code == .unavailable ? ProtocolError(code: .internal, message: error.message) : error
        }
        logged(true, nil, out)
        usage.inputTokens += out.inputTokens ?? 0; usage.outputTokens += out.outputTokens ?? 0; usage.costUSD += out.costUSD ?? 0
        write(usage, to: dir.appendingPathComponent("usage.json"))
        return out
    }
}
