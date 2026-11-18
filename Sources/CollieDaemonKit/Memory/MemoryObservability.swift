import Foundation
import CollieCore
import CollieProtocol

/// `memory.stats`: the event log (`MemoryEventLog`) summed up — usage, maintenance, the learning signal, cost and week-over-
/// week trends. Pure (`compute`): the router hands it the events already filtered to the caller's scope.
/// Savings are never estimated: with no controlled comparison, only trends are shown, with `caveat` saying so.
enum MemoryObservability {
    static let caveat = "economia não medida diretamente (sem comparação controlada); tendências apenas"
    static let deadAfterDays = 30, repeatWithinDays = 14, topMax = 10

    struct Day: Codable, Sendable, Equatable { var day: String; var value: Double }
    struct MemoryRef: Codable, Sendable, Equatable { var id: UUID; var title: String?; var count: Int }
    struct Repeat: Codable, Sendable, Equatable {
        var subject: String
        /// Corrections of this subject in the period, and how many of them came ≤ 14 days after another one.
        var corrections: Int, repeats: Int
        var last: Date
        /// The memory the latest correction was about (its nearest stored memory), when there was one.
        var memory: UUID?
    }
    struct Usage: Codable, Sendable, Equatable {
        var injectionsPerDay: [Day] = [], prompts = 0, promptsWithMemory = 0
        /// promptsWithMemory / prompts; nil without prompts.
        var coverage: Double?
        var top: [MemoryRef] = []
        /// Active memories older than 30 days that were not injected in the last 30 (`deadShare` of those old enough).
        var dead: [MemoryRef] = [], deadShare: Double?
        var searches = 0, searchHits = 0
        /// Beside `coverage` (prompts with a memory), how often an injected memory was used (Leva 1).
        var precision = Precision()
        /// Item 2 phase 1, beside `precision`: how many of its candidates also had evidence.
        var evidence = Evidence()
    }
    /// Leva 1 precision (spec 2026-11-17 memory measurement baseline). Per memory id, not per prompt: `addUse` counts ids.
    /// `injected`: ids injected by prompt relevance (`injected` at `prompt`; pulls, start, rules not). `candidates`: those of
    /// them that can earn a use (`eligible`, logged since Leva 1). `used`: ids the next prompt counted (`used` events);
    /// `corrected`: ids a correction dropped; `unresolved`: the rest (no next prompt, a wrong/outdated flag, or still pending).
    /// `rate` = used ÷ candidates, nil without a candidate. `flags`: explicit `--useful` flags, outside the rate (they can
    /// name any injected memory, not only a prompt's). Each side is counted by its own event's time: an injection and its
    /// use on two sides of the period's edge fall apart (ponytail: one prompt per edge; pair by session if it matters).
    /// `def`: the definition's version (1: this one); a trend across two `def`s is not comparable.
    struct Precision: Codable, Sendable, Equatable {
        var def = 1
        var injected = 0, candidates = 0, used = 0, corrected = 0, unresolved = 0, flags = 0
        var rate: Double?
    }
    /// Use with evidence (spec 2026-11-17 memory useful evidence, phase 1: measured, no rule reads it), `def` 1.
    /// `candidates`: the v1 precision's. `evidenced`: of the ids a next prompt counted (v1 `used`), those its turn cited
    /// (`evidenced` of a prompt's `used`), so `evidenced ≤ used`; `rate` = evidenced ÷ candidates, nil without a candidate.
    /// `byKind`: every evidence of the period by kind (cite|get|flag); `get` and `flag` name any injected memory, not a
    /// prompt's, so like the v1 `flags` they stay outside the rate.
    struct Evidence: Codable, Sendable, Equatable {
        var def = 1, candidates = 0, evidenced = 0
        var rate: Double?
        var byKind: [String: Int] = [:]
    }
    struct Maintenance: Codable, Sendable, Equatable {
        var createdBySource: [String: Int] = [:]
        var undone = 0, undonePct: Double?
        var merges = 0, supersedes = 0, retractionsDelivered = 0, consolidations = 0, archivedLowScore = 0
        /// Open "Parece uma correção sua" confirmations, and open asks (two memories that contradict each other).
        var pendingAsks = 0, openContradictions = 0
        var averageAgeDays: Double?, averageScore: Double?
        var curatorQueued = 0, curatorFailed = 0, curatorRuns = 0, curatorRunFailures = 0
        var lastCuratorRun: Date?
    }
    struct Learning: Codable, Sendable, Equatable {
        var corrections = 0, repeatCorrections = 0
        var repeats: [Repeat] = []
    }
    struct Cost: Codable, Sendable, Equatable {
        var curatorTokensPerDay: [Day] = [], curatorUSDPerDay: [Day] = [], injectedTokensPerDay: [Day] = [], sessionTokensPerDay: [Day] = []
        var curatorTokens = 0, curatorUSD = 0.0, injectedTokens = 0
        var sessionInput = 0, sessionOutput = 0, sessionCacheRead = 0, sessionCacheCreation = 0
        var completedTasks = 0
        /// Session tokens (all four kinds) of the works completed in the period, per work; nil without one.
        var sessionTokensPerTask: Double?
    }
    struct Week: Codable, Sendable, Equatable {
        var start: Date
        var tokensPerTask: Double?, searchesPerTask: Double?, coverage: Double?
        var repeatCorrections = 0, completedTasks = 0
        var precision: Double?
        /// `Evidence.rate` of the week.
        var evidence: Double?
    }
    struct Lifecycle: Codable, Sendable, Equatable {
        /// Effective tiers of the eligible active project records, and how many of them are contested now.
        var provisional = 0, earned = 0, longTerm = 0, contestedOpen = 0
        /// Counted from the period's events.
        var promotions = 0, demotions = 0, provisionalArchived = 0
        var flags = Flags(), verify = Verify()
        struct Flags: Codable, Sendable, Equatable { var useful = 0, wrong = 0, outdated = 0 }
        struct Verify: Codable, Sendable, Equatable { var valid = 0, invalid = 0, deferred = 0 }
    }
    struct Trends: Codable, Sendable, Equatable { var current: Week; var previous: Week }
    /// One agent's memory use (spec 2026-11-17 cursor memory §6). `obedience`: of the Collie asks delivered to it, the
    /// share followed by a `memory_task` before the ask ended (nil without asks); the user's own typing is not seen.
    /// `useful`: its `--useful` flags (a hookless agent has no prompt to count a use by).
    struct AgentUsage: Codable, Sendable, Equatable {
        var sessions = 0, sessionsWithStart = 0, pulls = 0
        var pullsPerSession: Double?
        var asksDelivered = 0
        var obedience: Double?
        var useful = 0
        /// Its prompts' precision (a hookless agent has none: `candidates` 0, `rate` nil).
        var precision = Precision()
        var evidence = Evidence()
    }
    struct Report: Codable, Sendable, Equatable {
        var since: Date, until: Date
        /// The oldest event read (the log may be younger than the period: dead memories need 30 days of it).
        var logSince: Date?
        var caveat = MemoryObservability.caveat
        var usage = Usage(), maintenance = Maintenance(), learning = Learning(), cost = Cost(), lifecycle = Lifecycle()
        var trends: Trends
        /// Keyed by agent; events from before the agent was logged are in none.
        var byAgent: [String: AgentUsage] = [:]
    }

    /// `since` — `7d`, `24h`, `2w` or an ISO 8601 date — as a date before `now`; nil when unreadable.
    static func since(_ s: String, now: Date) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        guard let unit = s.last, let n = Double(s.dropLast()), n >= 0 else { return nil }
        let secs: Double? = switch unit { case "h": 3_600; case "d": 86_400; case "w": 7 * 86_400; default: nil }
        return secs.map { now.addingTimeInterval(-n * $0) }
    }

    /// Events from at least 30 days before `now` (dead memories, repeats and the previous week look back further than the
    /// period); `records`: the active memories in scope; `openDigest`: the digest's open asks/confirmations.
    static func compute(events: [MemoryEvent], since: Date, now: Date, records: [MemoryRecord], scores: [UUID: Double],
                        openDigest: [DigestEntry], curator: CuratorStatus?, lifecycle: [UUID: LifecycleEntry] = [:],
                        calendar: Calendar = .current) -> Report {
        let inPeriod = events.filter { $0.at >= since && $0.at <= now }
        let titles = Dictionary(records.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var r = Report(since: since, until: now, logSince: events.map(\.at).min(),
                       trends: Trends(current: week(events, from: now.addingTimeInterval(-7 * 86_400), to: now),
                                      previous: week(events, from: now.addingTimeInterval(-14 * 86_400), to: now.addingTimeInterval(-7 * 86_400))))
        func series(_ type: MemoryEvent.Kind, _ value: (MemoryEvent) -> Double) -> [Day] {
            perDay(inPeriod.filter { $0.type == type }, from: since, to: now, calendar: calendar, value)
        }

        // usage
        let injected = inPeriod.filter { $0.type == .injected }
        r.usage.injectionsPerDay = series(.injected) { _ in 1 }
        let p = prompts(inPeriod)
        r.usage.prompts = p.all; r.usage.promptsWithMemory = p.with; r.usage.coverage = p.coverage
        var counts: [UUID: Int] = [:]
        for e in injected where e.where != "retraction" { for id in e.ids ?? [] { counts[id, default: 0] += 1 } }
        r.usage.top = counts.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }.prefix(topMax)
            .map { MemoryRef(id: $0.key, title: titles[$0.key], count: $0.value) }
        let deadCut = now.addingTimeInterval(-Double(deadAfterDays) * 86_400)
        let recent = Set(events.filter { $0.type == .injected && $0.at >= deadCut && $0.where != "retraction" }.flatMap { $0.ids ?? [] })
        let old = records.filter { $0.createdAt <= deadCut }
        let dead = old.filter { !recent.contains($0.id) }.sorted { $0.updatedAt < $1.updatedAt }
        r.usage.dead = dead.map { MemoryRef(id: $0.id, title: $0.title, count: 0) }
        r.usage.deadShare = old.isEmpty ? nil : Double(dead.count) / Double(old.count)
        let searched = inPeriod.filter { $0.type == .searched }
        r.usage.searches = searched.count; r.usage.searchHits = searched.reduce(0) { $0 + ($1.hits ?? 0) }
        r.usage.precision = precision(inPeriod)
        r.usage.evidence = evidence(inPeriod)

        // maintenance
        var m = Maintenance()
        for e in inPeriod where e.type == .created { m.createdBySource[e.source ?? "user", default: 0] += 1 }
        let changes = inPeriod.filter { [.created, .merged, .superseded, .archived, .retracted].contains($0.type) }.count
        m.undone = inPeriod.filter { $0.type == .undone }.count
        m.undonePct = changes == 0 ? nil : Double(m.undone) / Double(changes)
        m.merges = inPeriod.filter { $0.type == .merged }.count
        m.supersedes = inPeriod.filter { $0.type == .superseded }.count
        m.retractionsDelivered = injected.filter { $0.where == "retraction" }.reduce(0) { $0 + ($1.ids?.count ?? 0) }
        let runs = inPeriod.filter { $0.type == .curatorRun }
        m.consolidations = runs.filter { $0.job == CuratorJobKind.consolidate.rawValue && $0.ok == true }.count
        m.archivedLowScore = inPeriod.filter { $0.type == .archived && $0.source == "consolidation" }.count
        m.pendingAsks = openDigest.filter { $0.action == "confirmar" && !$0.resolved && !$0.undone }.count
        m.openContradictions = openDigest.filter { $0.action == "ask" && !$0.resolved && !$0.undone }.count
        if !records.isEmpty {
            m.averageAgeDays = records.reduce(0) { $0 + max(0, now.timeIntervalSince($1.createdAt)) / 86_400 } / Double(records.count)
            m.averageScore = records.reduce(0) { $0 + (scores[$1.id] ?? 1) } / Double(records.count)
        }
        m.curatorQueued = curator?.queued ?? 0; m.curatorFailed = curator?.failed ?? 0
        m.curatorRuns = runs.count; m.curatorRunFailures = runs.filter { $0.ok != true }.count
        m.lastCuratorRun = events.filter { $0.type == .curatorRun }.map(\.at).max()
        r.maintenance = m

        // lifecycle
        var lc = Lifecycle()
        for r in records where LifecycleRules.eligible(r) {
            guard let e = lifecycle[r.id] else { lc.provisional += 1; continue }   // no entry yet: provisional
            switch LifecycleRules.tier(for: e, now: now) { case .provisional: lc.provisional += 1; case .earned: lc.earned += 1; case .longTerm: lc.longTerm += 1 }
            if e.contestedNow { lc.contestedOpen += 1 }
        }
        for e in inPeriod {
            switch e.type {
            case .promoted: lc.promotions += 1
            case .demoted: lc.demotions += 1
            case .archivedUnused: lc.provisionalArchived += 1
            case .flagged:
                switch e.verdict { case "useful": lc.flags.useful += 1; case "wrong": lc.flags.wrong += 1; case "outdated": lc.flags.outdated += 1; default: break }
            case .verified:
                switch e.verdict { case "valid": lc.verify.valid += 1; case "invalid": lc.verify.invalid += 1; case "deferred": lc.verify.deferred += 1; default: break }
            default: break
            }
        }
        r.lifecycle = lc

        // learning
        let fix = repeats(events, from: since, to: now)
        r.learning.corrections = fix.corrections; r.learning.repeatCorrections = fix.list.reduce(0) { $0 + $1.repeats }
        r.learning.repeats = fix.list

        // cost
        var c = Cost()
        c.curatorTokensPerDay = series(.curatorRun) { Double(($0.inputTokens ?? 0) + ($0.outputTokens ?? 0)) }
        c.curatorUSDPerDay = series(.curatorRun) { $0.costUSD ?? 0 }
        c.injectedTokensPerDay = series(.injected) { Double($0.tokens ?? 0) }
        c.sessionTokensPerDay = series(.sessionUsage) { Double(sessionTokens($0)) }
        c.curatorTokens = runs.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }
        c.curatorUSD = runs.reduce(0) { $0 + ($1.costUSD ?? 0) }
        c.injectedTokens = injected.reduce(0) { $0 + ($1.tokens ?? 0) }
        for e in inPeriod where e.type == .sessionUsage {
            c.sessionInput += e.inputTokens ?? 0; c.sessionOutput += e.outputTokens ?? 0
            c.sessionCacheRead += e.cacheRead ?? 0; c.sessionCacheCreation += e.cacheCreation ?? 0
        }
        r.byAgent = agents(inPeriod, now: now)
        let t = tasks(events, from: since, to: now)
        c.completedTasks = t.count; c.sessionTokensPerTask = t.perTask
        r.cost = c
        return r
    }

    static func sessionTokens(_ e: MemoryEvent) -> Int {
        (e.inputTokens ?? 0) + (e.outputTokens ?? 0) + (e.cacheRead ?? 0) + (e.cacheCreation ?? 0)
    }

    private static func agents(_ es: [MemoryEvent], now: Date) -> [String: AgentUsage] {
        var out: [String: AgentUsage] = [:]
        for (agent, xs) in Dictionary(grouping: es.filter { $0.agent != nil }, by: { $0.agent! }) {
            func key(_ e: MemoryEvent) -> String? { e.session ?? e.terminal?.uuidString }
            var u = AgentUsage()
            u.sessions = Set(xs.compactMap { [.injected, .noHit, .searched].contains($0.type) ? key($0) : nil }).count
            u.sessionsWithStart = Set(xs.filter { $0.type == .injected && ["start", "compact", "focus"].contains($0.where ?? "") }.compactMap(key)).count
            let pulls = xs.filter { [.injected, .noHit].contains($0.type) && $0.where == "pull" }
            u.pulls = pulls.count
            u.pullsPerSession = u.sessions == 0 ? nil : Double(u.pulls) / Double(u.sessions)
            let delivered = xs.filter { $0.type == .askDelivered }
            u.asksDelivered = delivered.count
            if !delivered.isEmpty {
                let obeyed = delivered.filter { d in
                    let end = xs.first { $0.type == .askDone && $0.ask == d.ask }?.at ?? now
                    return pulls.contains { $0.terminal == d.terminal && $0.at >= d.at && $0.at <= end }
                }
                u.obedience = Double(obeyed.count) / Double(delivered.count)
            }
            u.useful = xs.filter { $0.type == .flagged && $0.verdict == "useful" }.count
            u.precision = precision(xs)
            u.evidence = evidence(xs)
            out[agent] = u
        }
        return out
    }

    static func precision(_ es: [MemoryEvent]) -> Precision {
        var p = Precision()
        for e in es {
            switch e.type {
            case .injected where e.where == "prompt": p.injected += e.ids?.count ?? 0; p.candidates += e.eligible ?? 0
            case .used where e.where != nil: break   // a `get`/`flag` use (item 2): not a prompt's
            case .used where e.reason == "correction": p.corrected += e.hits ?? 0
            case .used: p.used += e.ids?.count ?? 0
            case .flagged where e.verdict == "useful": p.flags += 1
            default: break
            }
        }
        p.unresolved = max(0, p.candidates - p.used - p.corrected)
        p.rate = p.candidates == 0 ? nil : Double(p.used) / Double(p.candidates)
        return p
    }

    static func evidence(_ es: [MemoryEvent]) -> Evidence {
        var e = Evidence(candidates: precision(es).candidates)
        for x in es where x.type == .used {
            for k in x.evidence ?? [] { e.byKind[k, default: 0] += 1 }
            if x.where == nil, x.reason == nil { e.evidenced += x.evidenced?.count ?? 0 }
        }
        e.rate = e.candidates == 0 ? nil : Double(e.evidenced) / Double(e.candidates)
        return e
    }

    /// A prompt is a `noHit` or an `injected` at `prompt` (pushed rules are `rule`: not a prompt of their own).
    private static func prompts(_ es: [MemoryEvent]) -> (all: Int, with: Int, coverage: Double?) {
        let with = es.filter { $0.type == .injected && $0.where == "prompt" }.count
        let all = with + es.filter { $0.type == .noHit && $0.where != "pull" }.count   // a `memory.task` pull is not a prompt
        return (all, with, all == 0 ? nil : Double(with) / Double(all))
    }

    /// Works completed (closed, not by a removal) in [from, to], and their session tokens per work (usage logged any time).
    private static func tasks(_ events: [MemoryEvent], from: Date, to: Date) -> (count: Int, perTask: Double?) {
        let done = Set(events.filter { $0.type == .workClosed && $0.at >= from && $0.at <= to && $0.reason != "removed" }.compactMap(\.work))
        guard !done.isEmpty else { return (0, nil) }
        let tokens = events.filter { $0.type == .sessionUsage && $0.work.map(done.contains) == true }.reduce(0) { $0 + sessionTokens($1) }
        return (done.count, Double(tokens) / Double(done.count))
    }

    /// Corrections in [from, to] by subject (scoped by lot/project: the same words in two projects are two subjects); a
    /// repeat is one that came ≤ 14 days after an earlier correction of its subject (looked up in all `events`).
    private static func repeats(_ events: [MemoryEvent], from: Date, to: Date) -> (corrections: Int, list: [Repeat]) {
        func key(_ e: MemoryEvent) -> String? {
            e.subject.map { "\(e.lot?.uuidString ?? "")|\(e.project ?? "")|\($0)" }
        }
        let all = events.filter { $0.type == .correction }.sorted { $0.at < $1.at }
        var last: [String: Date] = [:], out: [String: Repeat] = [:], order: [String] = [], n = 0
        for e in all {
            guard let k = key(e) else { continue }
            defer { last[k] = e.at }
            guard e.at >= from, e.at <= to else { continue }
            n += 1
            let again = last[k].map { e.at.timeIntervalSince($0) <= Double(repeatWithinDays) * 86_400 } ?? false
            if out[k] == nil { order.append(k) }
            var r = out[k] ?? Repeat(subject: e.subject ?? "", corrections: 0, repeats: 0, last: e.at, memory: nil)
            r.corrections += 1; r.repeats += again ? 1 : 0; r.last = e.at; r.memory = e.ids?.first ?? r.memory
            out[k] = r
        }
        return (n, order.compactMap { out[$0] }.filter { $0.repeats > 0 }.sorted { ($0.repeats, $0.last) > ($1.repeats, $1.last) })
    }

    private static func week(_ events: [MemoryEvent], from: Date, to: Date) -> Week {
        let w = events.filter { $0.at >= from && $0.at < to }
        let t = tasks(events, from: from, to: to.addingTimeInterval(-0.001))
        let searches = w.filter { $0.type == .searched }.count
        return Week(start: from, tokensPerTask: t.perTask, searchesPerTask: t.count == 0 ? nil : Double(searches) / Double(t.count),
                    coverage: prompts(w).coverage, repeatCorrections: repeats(events, from: from, to: to.addingTimeInterval(-0.001)).list.reduce(0) { $0 + $1.repeats },
                    completedTasks: t.count, precision: precision(w).rate, evidence: evidence(w).rate)
    }

    /// One value per local day from `from` to `to` (days without events: 0).
    private static func perDay(_ es: [MemoryEvent], from: Date, to: Date, calendar: Calendar, _ value: (MemoryEvent) -> Double) -> [Day] {
        var sums: [String: Double] = [:]
        for e in es { sums[MemoryEventLog.day(e.at, calendar: calendar), default: 0] += value(e) }
        var out: [Day] = [], d = calendar.startOfDay(for: from)
        while d <= to, out.count < 400 {
            let k = MemoryEventLog.day(d, calendar: calendar)
            out.append(Day(day: k, value: sums[k] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
