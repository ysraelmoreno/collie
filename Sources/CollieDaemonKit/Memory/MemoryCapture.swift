import Foundation
import CollieCore
import CollieProtocol

/// Learnings captured from a work's record, deterministically (no model, no network): `Done:` notes and decision notes
/// become decisions, a deferred task's reason a decision, a dropped task's reason a pitfall. The chunk's commit subjects
/// are only body context, never a memory of their own. Every record is `proposed` (never injected until approved; it
/// expires to `discarded` after 14 days), scrubbed of tokens, edit links and env-like values, from "captura (<terminal>)".
enum MemoryCapture {
    static let maxTitle = 120, maxBody = 1200, maxCommits = 5

    static let stopReason = "Antes de encerrar: registre decisões e armadilhas deste trabalho com collie memory save --scope lot (ou responda 'nada a registrar')."
    /// Outside a lot `--scope lot` would be refused: the same ask, for the project.
    static let stopReasonNoLot = stopReason.replacingOccurrences(of: "--scope lot", with: "--scope project")

    /// The commits recorded after `mark` (default: the last Stop ask's); all of them without one, or when it was archived.
    static func newCommits(_ w: Work, after mark: String?? = nil) -> ArraySlice<String> {
        guard let mark = mark ?? w.capturedCommit, let i = w.commits.lastIndex(of: mark) else { return w.commits[...] }
        return w.commits[(i + 1)...]
    }

    /// A new chunk since the last capture: a task done after it, or a new commit (what Claude's Stop asks about).
    static func hasNewWork(_ w: Work) -> Bool {
        let since = w.capturedAt ?? .distantPast
        return !newCommits(w).isEmpty || w.tasks.contains { $0.state == .done && $0.updatedAt > since }
    }

    /// `since`/`afterCommit`: the last proposals' mark (`proposedAt`/`proposedCommit`).
    static func candidates(work w: Work, since: Date, afterCommit: String? = nil, terminal: String, lot: UUID?,
                           secrets: Set<String> = []) -> [MemoryRecord] {
        func clean(_ s: String) -> String { LotBoards.scrub(s, secrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines) }
        let commits = newCommits(w, after: .some(afterCommit)).suffix(maxCommits).map(clean)
        let context = [w.title.isEmpty ? "" : "Trabalho: \(clean(w.title))",
                       commits.isEmpty ? "" : "Commits: " + commits.joined(separator: "; ")].filter { !$0.isEmpty }
        var out: [MemoryRecord] = []
        func add(_ kind: MemoryKind, _ title: String, _ detail: String) {
            let t = String(clean(title).split(whereSeparator: \.isNewline).joined(separator: " ").prefix(maxTitle))
            guard !t.isEmpty else { return }
            out.append(MemoryRecord(kind: kind, scope: lot == nil ? .project : .lot, lotId: lot, subject: t, title: t,
                                    body: String(([clean(detail)] + context).filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(maxBody)),
                                    status: .proposed, origin: "captura (\(clean(terminal)))"))
        }
        for n in w.notes where n.at > since {
            if n.text.hasPrefix("Done: ") { add(.decision, String(n.text.dropFirst("Done: ".count)), n.text) }
            else if n.decision { add(.decision, n.text, n.text) }
        }
        for t in w.tasks where t.updatedAt > since {
            guard let r = t.reason else { continue }
            if t.state == .deferred { add(.decision, "Adiado: \(t.title)", r) }
            if t.state == .abandoned { add(.pitfall, "Abandonado: \(t.title)", r) }
        }
        return out
    }
}

extension CommandRouter {
    /// When `w`'s learnings were last captured, and whether `me` saved a memory itself since then (or since the work
    /// opened) in any store it writes to. ponytail: reads every record of those stores; an index column if they grow big.
    func captureState(_ me: TerminalRecord, _ w: Work) async -> (last: Date?, saved: Bool) {
        let since = w.capturedAt ?? w.openedAt, origin = "\(me.name) (\(me.preset.rawValue))"
        var stores = [await memory.repo(for: me.cwd)]
        if stores[0] !== memory.global { stores.append(memory.global) }
        if let l = ws.lot(of: me.id) { stores.append(await memory.lotStore(l.id)) }
        for s in stores {
            let saved = (try? await s.run { m in m.store.all().records.contains { $0.origin == origin && $0.createdAt > since } }) ?? false
            if saved { return (w.capturedAt, true) }
        }
        return (w.capturedAt, false)
    }

    /// Claude's `Stop`: the reason to make the agent record what it learned — at most once per chunk of new work (done
    /// tasks, commits since the last capture), never when it saved a memory itself meanwhile. The chunk is marked captured
    /// either way. nil: no ask (also on any error: fail open).
    func stopAsk(_ tid: UUID) async -> String? {
        guard let me = ws.terminals.first(where: { $0.id == tid }) else { return nil }
        do {
            guard let w = try await work.active(terminal: tid), MemoryCapture.hasNewWork(w) else { return nil }
            let state = await captureState(me, w)
            guard try await mark(w) else { return nil }   // a concurrent Stop or capture took this chunk
            return state.saved ? nil : ws.lot(of: me.id) != nil ? MemoryCapture.stopReason : MemoryCapture.stopReasonNoLot
        } catch { workLog("stop ask: \((error as? ProtocolError)?.message ?? "\(error)")"); return nil }
    }

    /// Marks `w`'s chunk asked about unless another Stop marked it since `w` was read; true when this one did.
    private func mark(_ w: Work) async throws -> Bool {
        let now = Date(), was = w.capturedAt
        try await work.update(w.id) { x in
            guard x.capturedAt == was else { return }
            x.capturedAt = now; x.capturedCommit = x.commits.last
        }
        return try await work.get(w.id)?.capturedAt == now
    }

    /// The continued Stop after an ask: the capture turn is over. Its own `collie memory save` must not count as a save
    /// in the next chunk (it would skip that chunk's ask), so the ask mark moves past it; the commit mark stays.
    /// ponytail: not when a task was done during the capture turn (moving the mark would hide it): then that save
    /// can still skip the next ask once. A separate save cutoff if that shows.
    func captureContinued(_ tid: UUID) async {
        do {
            guard let w = try await work.active(terminal: tid), w.capturedAt != nil, !MemoryCapture.hasNewWork(w) else { return }
            let now = Date()
            try await work.update(w.id) { x in if !MemoryCapture.hasNewWork(x) { x.capturedAt = now } }
        } catch { workLog("capture continued: \((error as? ProtocolError)?.message ?? "\(error)")") }
    }

    /// Work done, compaction, session end (every agent): the work's new learnings become proposals in the terminal's lot
    /// (else its project, else the global store), rewritten by the local model when there is one. R6: written whatever
    /// the agent answered to a Stop ask; the chunk is marked only once they are on disk (a failed write is retried by the
    /// next trigger). One capture a work at a time, so two triggers never write the same chunk twice. Never fails its caller.
    func captureProposals(_ workId: UUID) async {
        // ponytail: 50 ms polling while another trigger's capture (maybe a slow model call) runs; a waiter list if it shows
        while capturing.contains(workId) { try? await Task.sleep(for: .milliseconds(50)) }
        capturing.insert(workId)
        defer { capturing.remove(workId) }
        let readAt = Date()   // the mark: what is written after this read is the next chunk
        do {
            guard let w = try await work.get(workId), let me = ws.terminals.first(where: { $0.id == w.terminalId }) else { return }
            let lot = ws.lot(of: me.id), secrets = await auth.secrets()
            let found = MemoryCapture.candidates(work: w, since: w.proposedAt ?? .distantPast, afterCommit: w.proposedCommit,
                                                 terminal: me.name, lot: lot?.id, secrets: secrets)
            guard !found.isEmpty else { return }
            let store = if let lot { await memory.lotStore(lot.id) } else { await memory.repo(for: me.cwd) }
            var recs: [MemoryRecord] = []
            for var r in found {
                if store === memory.global { r.scope = .global }   // outside git
                if let x = await assistant.rewriteProposal(title: r.title, body: r.body) {
                    let t = String(LotBoards.scrub(x.title, secrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines).prefix(MemoryCapture.maxTitle))
                    if !t.isEmpty { r.title = t; r.body = String(LotBoards.scrub(x.body, secrets: secrets).prefix(MemoryCapture.maxBody)) }
                }
                recs.append(r)
            }
            // `write`, not `save`: a proposal replaces nothing until it is approved
            let out = recs
            try await store.run { m in for r in out { try m.store.write(r) } }
            await enqueueProposals(out.map(\.id), store: store)   // the curator activates, merges or drops them
            let last = w.commits.last
            try await work.update(w.id) { $0.proposedAt = readAt; $0.proposedCommit = last }
        } catch { workLog("capture: \((error as? ProtocolError)?.message ?? "\(error)")") }
    }
}
