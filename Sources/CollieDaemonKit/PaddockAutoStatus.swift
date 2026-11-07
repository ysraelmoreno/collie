import Foundation
import CollieCore
import CollieProtocol

/// A paddock's status, computed from its terminals' badges (DX 19): blocked (a card waits), working (an agent mid-turn),
/// else review (work to land) or idle (nothing to land). Done comes from the land. A status set by hand, or the land's
/// done, holds until the computed one changes.
enum PaddockAutoStatus {
    enum Activity: Equatable { case blocked, working, quiet }

    /// attention (an approval or a prompt waiting) beats working beats quiet (idle, stopped, no badge yet).
    static func activity(_ badges: [StatusBadge?]) -> Activity {
        if badges.contains(.attention) { return .blocked }
        if badges.contains(.working) { return .working }
        return .quiet
    }

    static func quiet(pending: Bool) -> PaddockStatus { pending ? .review : .idle }

    /// The status to show now, nil to keep `shown`. `last`: the previous computed status (nil: none yet).
    /// Done holds while quiet: closing a landed paddock's terminals is not new work.
    static func apply(computed: PaddockStatus, last: PaddockStatus?, shown: PaddockStatus) -> PaddockStatus? {
        guard computed != last, computed != shown else { return nil }
        if shown == .done, computed != .working, computed != .blocked { return nil }
        return computed
    }

    /// Commits on the branch the base lacks, or uncommitted changes (Collie's own folder aside). A folder paddock: none.
    /// git reads the worktree (no network); under `GitRunner.sandbox` when the caller sets one.
    static func pending(_ f: Paddock) async throws(ProtocolError) -> Bool {
        guard !f.isFolder else { return false }
        let dir = URL(fileURLWithPath: f.path)
        let ahead = try await GitRunner.run(["rev-list", "--count", "\(f.baseBranch)..\(f.branch)"], in: dir, timeout: .seconds(20))
        if ahead.status == 0, (Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 { return true }
        let st = try await GitRunner.run(["status", "--porcelain", "--", ".", ":(exclude).collie", ":(exclude).orq"], in: dir,
                                         timeout: .seconds(20))
        return st.status == 0 && !st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension CommandRouter {
    /// Recomputes every paddock after a terminal event (badge change, spawn, exit, removal). git runs only when a paddock
    /// turns quiet; staying quiet costs nothing.
    func refreshPaddockStatuses() async {
        let badges = await hub.currentBadges
        for f in ws.paddocks {
            let act = PaddockAutoStatus.activity(ws.terminals.filter { $0.paddockId == f.id }.map { badges[$0.id] })
            let last = paddockComputed[f.id]
            let computed: PaddockStatus
            switch act {
            case .blocked: computed = .blocked
            case .working: computed = .working
            case .quiet:
                if last == .review || last == .idle { continue }   // already quiet: no git
                // R4: an open-mode terminal of the paddock could have planted git config: run under its profile
                let open = ws.terminals.first { $0.paddockId == f.id && startedOpen($0) && sandboxed($0) }
                let profile = open.map { SandboxLaunch.profileFile($0.id, root: config.paths.root) }
                let pending = (try? await GitRunner.$sandbox.withValue(profile) { try await PaddockAutoStatus.pending(f) }) ?? false
                computed = PaddockAutoStatus.quiet(pending: pending)
            }
            // re-read after the awaits: the paddock may be gone or changed
            guard let i = ws.paddocks.firstIndex(where: { $0.id == f.id }) else { continue }
            paddockComputed[f.id] = computed
            guard let s = PaddockAutoStatus.apply(computed: computed, last: last, shown: ws.paddocks[i].status) else { continue }
            ws.paddocks[i].status = s
            try? await persist()
            await hub.emit(.paddock(ws.paddocks[i]))
        }
    }
}
