import Foundation
import CollieCore
import CollieProtocol

/// F3: one `LaneIntegrator` per paddock, so the loop's lanes and the fields land through one FIFO queue on the paddock's
/// branch; and the fields landing now (one land per field at a time).
actor PaddockIntegrators {
    private var byPaddock: [UUID: LaneIntegrator] = [:], landing: Set<String> = []

    /// The paddock's integrator: `make`'s, the first time.
    func integrator(paddock: UUID, make: @Sendable () -> LaneIntegrator) -> LaneIntegrator {
        if let i = byPaddock[paddock] { return i }
        let i = make()
        byPaddock[paddock] = i
        return i
    }

    /// The field (`branch`) starts landing; false: it already is.
    func beginLanding(_ branch: String) -> Bool { landing.insert(branch).inserted }
    func endLanding(_ branch: String) { landing.remove(branch) }
    /// F4: the field (`branch`) is landing now (its dismissal removes the worktree only after).
    func isLanding(_ branch: String) -> Bool { landing.contains(branch) }
}

/// F3: a field's land: the integrator joins the field's branch to the paddock's, the gate again on the merged tree.
enum FieldLand {
    enum Outcome: Sendable, Equatable {
        case landed(sha: String)
        /// Conflict or broken gate: undone by the integrator; `patch`: the field's new code (`git diff base..branch`).
        case conflict(reason: String, patch: URL?)
        /// Nothing ran: another land of the field, or the paddock not free in time (the caller tells the Shepherd).
        case waiting(reason: String)
    }

    static let alreadyLanding = "já integrando"
    /// Spec, answer 6: how long a land waits for the paddock to be free.
    static let paddockWait: Duration = .seconds(600)

    /// `dir`: the paddock's worktree (the integrator's); `host`: this land's (its `othersWorking` is who blocks the
    /// paddock); `patches`: `<root>/fields`. Waits while the tree's tracked files are dirty or someone is in a turn in
    /// it, up to `wait`, looking every `poll`.
    static func land(_ lane: Lane, dir: URL, integrators: PaddockIntegrators, integrator: LaneIntegrator, host: any LoopHost,
                     gate: String?, gateTimeout: Duration, patches: URL,
                     wait: Duration = paddockWait, poll: Duration = .seconds(2)) async -> Outcome {
        guard lane.isField else { return .conflict(reason: "'\(lane.branch)' não é branch de field", patch: nil) }
        guard await integrators.beginLanding(lane.branch) else { return .waiting(reason: alreadyLanding) }
        let out = await landing(lane, dir: dir, integrator: integrator, host: host, gate: gate, gateTimeout: gateTimeout,
                                patches: patches, wait: wait, poll: poll)
        await integrators.endLanding(lane.branch)
        return out
    }

    private static func landing(_ lane: Lane, dir: URL, integrator: LaneIntegrator, host: any LoopHost, gate: String?,
                                gateTimeout: Duration, patches: URL, wait: Duration, poll: Duration) async -> Outcome {
        let deadline = ContinuousClock.now + wait
        while true {
            let st = try? await host.git(["--literal-pathspecs", "status", "--porcelain", "--untracked-files=no"], in: dir)
            var why: String?
            if st?.status != 0 { why = "git status falhou no cercado" }
            else if st?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { why = "árvore do cercado com mudanças não commitadas" }
            else if let who = await host.othersWorking() { why = "'\(who)' está num turno no cercado" }
            guard let why else { break }
            if ContinuousClock.now >= deadline || Task.isCancelled { return .waiting(reason: why) }
            // ponytail: polled like the loop's `othersStillWorking`; an event per turn's end if 2 s per look bites
            await WorkLoop.nap(poll)
        }
        let name = String(lane.branch.dropFirst(LaneWorktree.fieldBranchPrefix.count))
        let r: LaneIntegrator.Result
        do {
            r = try await integrator.integrate(lane, title: "field \(name)", attempt: 1, tries: 1, gate: gate, gateTimeout: gateTimeout, as: host)
        } catch { return .conflict(reason: error.message, patch: nil) }
        switch r.outcome {
        case .integrated, .noop: return .landed(sha: r.head)
        case .wait(let why): return .waiting(reason: why)
        case .retryFromNewBase(let why), .defer(let why), .leftDirty(let why):
            return .conflict(reason: why, patch: await patch(lane, name: name, dir: dir, host: host, into: patches))
        }
    }

    /// Spec, answer 7: `<patches>/<name>-<n>.patch` (the lowest free n), `git diff <base>..<branch>`, 0600. `base` ""
    /// (a field found again by name): the merge base with the paddock's HEAD. Nil when git cannot say, there is no diff,
    /// or it cannot be written.
    static func patch(_ lane: Lane, name: String, dir: URL, host: any LoopHost, into patches: URL) async -> URL? {
        var base = lane.base
        if base.isEmpty, let mb = try? await host.git(["merge-base", "HEAD", lane.branch], in: dir), mb.status == 0 {
            base = mb.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !base.isEmpty, let d = try? await host.git(["diff", "--binary", "\(base)..\(lane.branch)"], in: dir), d.status == 0, !d.truncated,
              !d.stdout.isEmpty else { return nil }   // F5: no diff, no file
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: patches, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        var n = 1
        while fm.fileExists(atPath: patches.appendingPathComponent("\(name)-\(n).patch").path) { n += 1 }
        let f = patches.appendingPathComponent("\(name)-\(n).patch")
        return fm.createFile(atPath: f.path, contents: Data(d.stdout.utf8), attributes: [.posixPermissions: 0o600]) ? f : nil
    }
}

/// F3: the host of one field's land, on the daemon: git and the gate in the paddock's worktree under the Shepherd's own
/// profile (it commits there), and who blocks the paddock by `CommandRouter.fieldPaddockBusy`. It runs no agents.
struct FieldLandHost: LoopHost {
    let router: CommandRouter, paddock: UUID, dir: URL, shepherd: UUID?, root: URL
    let profile: URL?, env: [String: String]

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        throw ProtocolError(code: .unavailable, message: "a field's land summons no agent")
    }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        throw ProtocolError(code: .unavailable, message: "a field's land asks no agent")
    }
    func working(_ terminal: UUID) async -> Bool { await router.targetBusy(terminal) }
    func dismiss(_ terminal: UUID) async {}
    func othersWorking() async -> String? { await router.fieldPaddockBusy(paddock: paddock, dir: dir, shepherd: shepherd) }
    func anyoneWorking() async -> String? { await othersWorking() }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await RouterLoopHost.loopGit(args, in: dir, profile: try live())
    }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        try await RouterLoopHost.runCheck(command, in: dir, profile: try live(), env: env, timeout: timeout)
    }
    /// F4: the fields' birth and removal (`CommandRouter.fieldGit`): the daemon's own git, never a profile, as the lanes'.
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await RouterLoopHost.loopGit(args, in: dir, profile: nil)
    }
    func laneGit(_ args: [String], stdin: Data?, timeout: Duration, cap: Int, in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await RouterLoopHost.loopGit(args, in: dir, profile: nil, stdin: stdin, timeout: timeout, cap: cap)
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { false }
    func patchDir(_ work: UUID) -> URL { root.appendingPathComponent("fields") }
    func now() -> Date { Date() }

    /// Never unsandboxed because the profile went missing.
    private func live() throws(ProtocolError) -> URL? {
        if let profile, !FileManager.default.fileExists(atPath: profile.path) {
            throw ProtocolError(code: .unavailable, message: "o perfil de sandbox do Pastor sumiu; o land do field não roda sem sandbox")
        }
        return profile
    }
}

extension CommandRouter {
    /// F3: lands the field `lane` of the agent `terminal`, for the Shepherd `by` (nil: the app; then its summoner's
    /// profile). The gate is `collie-work.json`'s committed at the paddock's HEAD. `asRequest`: `by` is blocked in this
    /// call (`field land`), a wait like an `ask`. Keeps `rec.field.state` (`landing`, then `landed`/`conflict`/as it was).
    func landField(_ lane: Lane, terminal: UUID, by: UUID?, asRequest: Bool = false) async -> FieldLand.Outcome {
        guard let rec = ws.terminals.first(where: { $0.id == terminal }), let pid = rec.paddockId,
              let p = ws.paddocks.first(where: { $0.id == pid }), !p.isFolder else {
            return .conflict(reason: "o agente do field ou o cercado dele não existe", patch: nil)
        }
        let shepherd = by ?? rec.summonedBy, dir = URL(fileURLWithPath: p.path), root = config.paths.root
        var profile: URL?, env = await loopUserEnv()
        if let home = config.sandboxHome {
            guard let s = shepherd.flatMap({ id in ws.terminals.first { $0.id == id } }), sandboxed(s) else {
                return .conflict(reason: "sem Pastor com sandbox para integrar o field", patch: nil)
            }
            profile = SandboxLaunch.profileFile(s.id, root: root)
            env = RouterLoopHost.checkEnv(env, sandbox: (s.id, root, config.shell, home))
        } else { env = RouterLoopHost.checkEnv(env, sandbox: nil) }
        let host = FieldLandHost(router: self, paddock: pid, dir: dir, shepherd: shepherd, root: root, profile: profile, env: env)
        let head = (try? await host.git(["rev-parse", "HEAD"], in: dir))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gate: String?
        switch await WorkConfigFile.config(base: head, dir: dir) {
        case .success(let c): gate = c?.gate
        case .failure(let e): return .conflict(reason: "collie-work.json do HEAD: \(e.message)", patch: nil)
        }
        let integrator = await integrators.integrator(paddock: pid) { LaneIntegrator(host: host, dir: dir) }
        if asRequest, let by { fieldLandHolds[by, default: 0] += 1 }
        let before = rec.field?.state
        setFieldState(terminal, .landing)
        let out = await FieldLand.land(lane, dir: dir, integrators: integrators, integrator: integrator, host: host, gate: gate,
                                       gateTimeout: WorkLoop.defaultCheckTimeout, patches: host.patchDir(UUID()))
        if asRequest, let by { fieldLandHolds[by, default: 1] -= 1; if fieldLandHolds[by] ?? 0 <= 0 { fieldLandHolds[by] = nil } }
        switch out {
        case .landed: setFieldState(terminal, .landed)
        case .conflict: setFieldState(terminal, .conflict)
        case .waiting(let why): if why != FieldLand.alreadyLanding, let before { setFieldState(terminal, before) }
        }
        try? await persist()
        return out
    }

    private func setFieldState(_ terminal: UUID, _ s: FieldRef.State) {
        guard let i = ws.terminals.firstIndex(where: { $0.id == terminal }), ws.terminals[i].field != nil else { return }
        ws.terminals[i].field?.state = s
    }

    /// F3: who is in a turn in the paddock's worktree `dir`, but the agents of lanes and fields (their own trees) and the
    /// Shepherd `shepherd` when all it has open is waiting (`fieldShepherdOnlyWaits`).
    func fieldPaddockBusy(paddock: UUID, dir: URL, shepherd: UUID?) async -> String? {
        var skip: UUID?
        if let s = shepherd {
            let live = (ownWaits[s]?.values.map { $0 } ?? []).filter { (lastToolCall[s] ?? -1) < $0.seq && Self.clientAlive($0.pid) }.count
            let waits = live + (await asks.blocking(from: s)) + (fieldLandHolds[s] ?? 0)
            if Self.fieldShepherdOnlyWaits(open: openRequests[s] ?? 0, waits: waits) { skip = s }
        }
        for t in Self.loopReaching(ws.terminals, paddock: paddock, starter: skip, dir: dir, reviewers: loopReviewers)
        where !LaneWorktree.isLane(URL(fileURLWithPath: t.cwd)) {
            if await targetBusy(t.id) { return t.name }
        }
        return nil
    }

    /// F3 (spec, answer 6): the Shepherd only waits: every request it has open is an `ask`, a `wait`/`work wait` or a
    /// `field land` (and there is one). A Shepherd with nothing open counts by its turn alone.
    static func fieldShepherdOnlyWaits(open: Int, waits: Int) -> Bool { waits > 0 && open <= waits }
}
