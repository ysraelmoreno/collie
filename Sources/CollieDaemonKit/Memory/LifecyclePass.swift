import Foundation
import CollieCore

extension CommandRouter {
    /// The usage lifecycle of one project store (a repo root; never a lot or the global one), after the deterministic
    /// cleanup: migrate, tiers, promotion gates, claim checks, unused archive, proposals, prune, "Precisa de você".
    /// Tiers come only from `lifecycle.json`: nothing in a memory's `.md` sets them.
    func lifecyclePass(_ store: RepoMemory, now: Date = Date()) async {
        guard let root = store.root, store.lotId == nil else { return }
        let lc = memory.lifecycle, facts = config.gitFacts(root)
        guard let records = try? await store.run({ $0.store.all().records }) else { return }   // unreadable: nothing judged, nothing pruned
        // the user's kinds keep their entry and tag, but are never checked, archived or promoted automatically
        let eligible = records.filter { LifecycleRules.eligible($0) && !MemoryLearning.usersKind($0.kind) }
        let day = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.string(from: now) }()

        // (1) migration: an eligible record with no entry starts provisional now (its clock starts here, not at createdAt);
        // (2) provisional → earned stored; a contested longTerm is never demoted on disk (`tier(for:)` reads it as earned
        // until a valid re-check clears the contest)
        let fresh = Set(records.map(\.id)).subtracting(await lc.all().keys)   // entries born now: no claim check this pass
        // (2b) a tier earned in another store or for another text starts over here (`LifecycleRules.effective`)
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        await lc.update(records.filter(LifecycleRules.eligible).map(\.id), now: now) { id, e in
            guard let r = byId[id] else { return }
            let eff = LifecycleRules.effective(e, r, store: store.key)
            if eff != e { e = eff; e.tierSince = now }
            e.store = store.key
            let t = LifecycleRules.tier(for: e, now: now)
            if e.tier != .longTerm, t != e.tier { e.tier = t; e.tierSince = now }
            if e.tier != .provisional, e.textHash == nil { e.textHash = LifecycleRules.textHash(r) }   // earned now (or an older entry)
        }
        var entries = await lc.all()

        // (3) promotion gates (≤ 3 a day, in `enqueuePromotion`); a recent gate waits out its cooldown, an undone promotion never comes back
        for r in eligible {
            guard let e = entries[r.id], e.promotionUndone != true, LifecycleRules.promotionCandidate(e, now: now),
                  e.gatedAt.map({ now.timeIntervalSince($0) >= LifecycleRules.verifyCooldown }) ?? true else { continue }
            _ = await memory.enqueuePromotion(r.id, now: now)
        }

        // (4) claim checks: a failure contests the memory (a flag of session "claim-check") and queues its re-check
        // ponytail: at most 10 contests a pass (no flood of re-checks or no-model archives); the checks themselves are uncapped:
        // ceiling = uncontested eligible records × (8 branches × ≤ 4 + 8 SHAs × ≤ 2) git calls (only bodies naming a branch or
        // SHA call git; each ≤ 10 s), once a day per store. Cap the checks or cache facts if a pass gets slow.
        var contests = 0
        for r in eligible where contests < LifecycleRules.maxClaimContestsPerPass && !fresh.contains(r.id) {
            guard let e = entries[r.id], !e.contestedNow else { continue }
            // a re-check judged this very text: never contested again for it (nor inside the cooldown)
            if let at = e.recheckedAt, r.updatedAt <= at || now.timeIntervalSince(at) < LifecycleRules.verifyCooldown { continue }
            let failures = await ClaimChecks.check(r, facts: facts, knownIds: byId.keys)
            guard !failures.isEmpty else { continue }
            let reason = failures.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: ", ")
            await lc.update(r.id, now: now) { e in
                e.flags.append(LifecycleFlag(verdict: .outdated, session: "claim-check", day: day, reason: String(reason.prefix(CuratorOps.lineMax))))
                e.contestedNow = true; e.lastContestedAt = now
            }
            contests += 1
            if e.tier == .longTerm { memory.noteLifecycle(.demoted, r.id, store: store.key) }
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
                    return DigestEntry(id: UUID(), at: max(now, Date()), action: "aposentado", title: b.title, reason: item.reason, store: store.key,
                                       created: [], before: [b], undone: false, resolved: false)
                }
                try MemoryEventLog.$source.withValue("lifecycle") { try digest.append(rows) }
            } catch { memoryLog("lifecycle unused \(store.path): \(error)") }
        }

        // (6) a work-capture proposal 14 days old that nobody is handling and whose claims hold: active, provisional from now
        let (keep, asked) = await proposalState()
        for r in records where r.scope == .project && r.status == .proposed && !r.reviewed && !MemoryLearning.usersKind(r.kind)
            && !keep.contains(r.id) && !asked.contains(r.id) && now.timeIntervalSince(r.createdAt) >= MemoryCleanup.proposalAge {
            guard await ClaimChecks.check(r, facts: facts, knownIds: byId.keys).isEmpty else { continue }
            let job = CuratorJob(id: UUID(), kind: .verifyContested, store: store.key, payload: .null, dedupe: "", createdAt: now, attempts: 0)
            do {
                let rows = try await applyOps([.activate(id: r.id, reason: "proposta de 14 dias com checagens ok")], job: job)
                if rows.contains(where: { $0.action == "ativado" }) { await lc.update(r.id, now: now) { $0 = LifecycleEntry(tierSince: now, store: store.key) } }
                try MemoryEventLog.$source.withValue("consolidation") { try digest.append(rows.map { var x = $0; x.at = now; return x }) }
            } catch { memoryLog("lifecycle proposal \(store.path): \(error)") }
        }

        // (7) this store's entries whose id it no longer holds (30 days) go; other stores' entries are theirs to judge
        await lc.prune(store: store.key, knownIds: Set(records.map(\.id)), now: now)

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
