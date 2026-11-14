import Foundation
import CollieCore

extension CommandRouter {
    /// The usage lifecycle of one project store (a repo root; never a lot or the global one), after the deterministic
    /// cleanup: migrate, tiers, promotion gates, claim checks, unused archive, proposals, prune, "Precisa de você".
    /// Tiers come only from `lifecycle.json`: nothing in a memory's `.md` sets them.
    func lifecyclePass(_ store: RepoMemory, now: Date = Date()) async {
        guard let root = store.root, store.lotId == nil else { return }
        let lc = memory.lifecycle, facts = config.gitFacts(root)
        let records = (try? await store.run { $0.store.all().records }) ?? []
        // the user's kinds keep their entry and tag, but are never checked, archived or promoted automatically
        let eligible = records.filter { LifecycleRules.eligible($0) && !MemoryLearning.usersKind($0.kind) }
        let day = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.string(from: now) }()

        // (1) migration: an eligible record with no entry starts provisional now (its clock starts here, not at createdAt);
        // (2) tiers recomputed, a contested longTerm stored as earned
        await lc.update(records.filter(LifecycleRules.eligible).map(\.id), now: now) { e in
            let t = LifecycleRules.tier(for: e, now: now)
            if t != e.tier { e.tier = t; e.tierSince = now }
        }
        var entries = await lc.all()

        // (3) promotion gates (≤ 3 a day, in `enqueuePromotion`); a recent re-check waits out its cooldown
        for r in eligible {
            guard let e = entries[r.id], LifecycleRules.promotionCandidate(e, now: now),
                  e.recheckedAt.map({ now.timeIntervalSince($0) >= LifecycleRules.verifyCooldown }) ?? true else { continue }
            _ = await memory.enqueuePromotion(r.id, now: now)
        }

        // (4) claim checks: a failure contests the memory (a flag of session "claim-check") and queues its re-check
        // ponytail: no per-pass cap; ceiling = uncontested eligible records × (8 branches × ≤ 4 + 8 SHAs × ≤ 2) git calls
        // (only bodies naming a branch or SHA call git; each ≤ 10 s), once a day per store. Cap or cache facts if a pass gets slow.
        for r in eligible {
            guard let e = entries[r.id], !e.contestedNow,
                  e.recheckedAt.map({ now.timeIntervalSince($0) >= LifecycleRules.verifyCooldown }) ?? true else { continue }
            let failures = await ClaimChecks.check(r, facts: facts)
            guard !failures.isEmpty else { continue }
            let reason = failures.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: ", ")
            await lc.update(r.id, now: now) { e in
                e.flags.append(LifecycleFlag(verdict: .outdated, session: "claim-check", day: day, reason: String(reason.prefix(CuratorOps.lineMax))))
                e.contestedNow = true; e.lastContestedAt = now
            }
            _ = await enqueueVerify(r.id, kind: .verifyContested)   // no curator: the failed check archives it now
        }
        entries = await lc.all()

        // (5) provisional and unused for 21 days: archived (reversible), each in the digest
        let items = LifecycleRules.unusedPlan(records: eligible, entries: entries, now: now)
        if !items.isEmpty {
            do {
                let changed = try await store.run { try MemoryCleanup.apply(items, store: $0.store) }
                let rows = changed.compactMap { c -> DigestEntry? in
                    guard let item = items.first(where: { $0.id == c.id }), let b = records.first(where: { $0.id == c.id }) else { return nil }
                    return DigestEntry(id: UUID(), at: Date(), action: "aposentado", title: b.title, reason: item.reason, store: store.key,
                                       created: [], before: [b], undone: false, resolved: false)
                }
                try MemoryEventLog.$source.withValue("consolidation") { try digest.append(rows) }
            } catch { memoryLog("lifecycle unused \(store.path): \(error)") }
        }

        // (6) a work-capture proposal 14 days old that nobody is handling and whose claims hold: active, provisional from now
        let (keep, asked) = await proposalState()
        for r in records where r.scope == .project && r.status == .proposed && !r.reviewed && !MemoryLearning.usersKind(r.kind)
            && !keep.contains(r.id) && !asked.contains(r.id) && now.timeIntervalSince(r.createdAt) >= MemoryCleanup.proposalAge {
            guard await ClaimChecks.check(r, facts: facts).isEmpty else { continue }
            let job = CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: .null, dedupe: "", createdAt: Date(), attempts: 0)
            do {
                let rows = try await applyOps([.activate(id: r.id, reason: "proposta de 14 dias com checagens ok")], job: job)
                if rows.contains(where: { $0.action == "ativado" }) { await lc.update(r.id, now: now) { $0 = LifecycleEntry(tierSince: now) } }
                try MemoryEventLog.$source.withValue("consolidation") { try digest.append(rows) }
            } catch { memoryLog("lifecycle proposal \(store.path): \(error)") }
        }

        // (7) entries of ids no project store holds (30 days) go
        var known = Set<UUID>()
        for s in await memory.projectStores() { known.formUnion((try? await s.run { $0.store.all().records.map(\.id) }) ?? []) }
        if !known.isEmpty { await lc.prune(knownIds: known, now: now) }

        // (8) "Precisa de você": a pinned/reviewed memory contested, or one contested 14 days; once per contest
        let current = (try? await store.run { $0.store.all().records }) ?? []
        let asks = digest.since(.distantPast).filter { $0.action == "ask" }
        var rows: [DigestEntry] = []
        for r in current where r.scope == .project && r.status == .active {
            guard let e = entries[r.id], e.contestedNow, let at = e.lastContestedAt else { continue }
            let users = r.pinned || r.reviewed
            guard users || LifecycleRules.eligible(r) && now.timeIntervalSince(at) >= LifecycleRules.contestedAskAfter,
                  !asks.contains(where: { $0.at >= at && $0.before.contains { $0.id == r.id } }) else { continue }
            let days = Int(now.timeIntervalSince(at) / 86_400)
            rows.append(DigestEntry(id: UUID(), at: now, action: "ask", title: "Memória contestada: \"\(MemoryLearning.oneLine(r.title, max: 60))\"",
                                    reason: users ? "memória fixada ou editada pelo usuário foi marcada como errada ou velha"
                                                  : "contestada há \(days) dias sem veredito",
                                    store: store.key, created: [], before: [r], undone: false, resolved: false))
        }
        do { try MemoryEventLog.$source.withValue("consolidation") { try digest.append(rows) } } catch { memoryLog("lifecycle asks: \(error)") }
    }
}
