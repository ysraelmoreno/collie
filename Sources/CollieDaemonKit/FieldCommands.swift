import Foundation
import CollieCore
import CollieProtocol

/// F4: `summon --field`'s checks, `field list|land|drop`, and what dismissing a field's agent leaves (spec "Comandos",
/// "Dispensa", answers 3, 8, 10). A field is created and removed by the daemon's own git (`fieldGit`), as a lane.
extension CommandRouter {
    private func fieldError(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    /// The daemon's own git for the fields of `p` (birth, removal, the wip patch, `field list`): no profile, as the
    /// lanes' (`laneGit`); the Shepherd's profile writes neither `<paddocks>/field-*` nor `<common>/worktrees/field-*`.
    func fieldGit(_ p: Paddock) -> FieldLandHost {
        FieldLandHost(router: self, paddock: p.id, dir: URL(fileURLWithPath: p.path), shepherd: nil, root: config.paths.root, profile: nil, env: [:])
    }

    /// The lane of `f`, a field of paddock `p` (the base comes with it: its patch is `base..branch`).
    static func fieldLane(_ f: FieldRef, paddock p: Paddock) -> Lane {
        Lane(repoRoot: URL(fileURLWithPath: p.repoRoot), path: URL(fileURLWithPath: f.path), branch: f.branch, base: f.base)
    }

    /// `summon`: the paddock and the base sha of a field to cut, or nil for no field. `--field` asks for one;
    /// `fields.default` of `collie-work.json` as committed at the paddock's HEAD (answer 10) asks for one where `--field`
    /// would be allowed. Refuses `--field` with `--no-field`, without the sandbox, for a shell, with `--paddock`/`--cwd`
    /// or `--shepherd`, for a name no field takes (before any git), beside a loop in lanes (answer 3), and past `fields.max`.
    func fieldWanted(_ r: Request, name: String, by me: TerminalRecord, preset: Preset, asShepherd: Bool) async throws(ProtocolError) -> (paddock: Paddock, base: String)? {
        let on = flag(r, "field"), off = flag(r, "no-field")
        if on && off { throw fieldError(tr("--field e --no-field juntos: escolha um",
        "--field and --no-field together: choose one")) }
        guard !off, let p = ws.paddocks.first(where: { $0.id == me.paddockId }), !p.isFolder else {
            if on { throw fieldError(tr("--field precisa de um cercado com worktree git: você não está num",
        "--field needs a paddock with a git worktree: you are not in one")) }
            return nil
        }
        let shapeRefusal: String? =
            !sandboxed(me) ? tr("--field só com o sandbox de terminais: o agente de um field roda no sandbox estrito dele",
        "--field only with the terminal sandbox: a field's agent runs in its strict sandbox")
            : preset == .shell ? tr("--field é para agentes, não para shell",
        "--field is for agents, not for a shell")
            : str(r, "paddock") != nil || str(r, "cwd") != nil ? tr("--field não aceita --paddock nem --cwd: o field é cortado do seu cercado",
        "--field does not accept --paddock or --cwd: the field is cut from your paddock")
            : asShepherd ? tr("--field não aceita --shepherd: um sub-Pastor fica no cercado",
        "--field does not accept --shepherd: a sub-Shepherd stays in the paddock")
            : (try? LaneWorktree.validate(field: name)) == nil ? tr("nome de field inválido '\(name)' (o field leva o nome do agente: a-z, 0-9 e '-', até 40)",
        "invalid field name '\(name)' (the field takes the agent's name: a-z, 0-9 and '-', up to 40)") : nil
        if on, let shapeRefusal { throw fieldError(shapeRefusal) }
        let git = fieldGit(p)
        guard let h = try? await git.laneGit(["rev-parse", "HEAD"], in: git.dir), h.status == 0 else {
            if on { throw fieldError(tr("o HEAD do cercado '\(p.name)' não se lê: nenhum field cortado",
        "the HEAD of paddock '\(p.name)' cannot be read: no field cut")) }
            return nil
        }
        let head = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // answer 10: the committed file, never the tree (an agent turns no default on by editing); invalid: the defaults
        let fields = ((try? await WorkConfigFile.config(base: head, dir: git.dir).get()) ?? nil)?.fields ?? ProjectWorkConfig.FieldsConfig()
        guard on || (fields.default && shapeRefusal == nil) else { return nil }
        let hint = on ? "" : tr(" (fields.default do collie-work.json; --no-field convoca sem field)", " (fields.default of collie-work.json; --no-field summons without a field)")
        let lanes = ((try? await work.list(includeClosed: true)) ?? []).contains {
            $0.paddockId == p.id && $0.loop?.state == .running && ($0.loop?.parallel ?? 1) > 1
        }
        if lanes { throw fieldError(tr("há um laço em faixas (work run --parallel) rodando neste cercado: field e faixas não convivem; espere ele terminar\(hint)",
        "a loop with lanes (work run --parallel) is running in this paddock: fields and lanes do not coexist; wait for it to finish\(hint)")) }
        let live = ws.terminals.filter { $0.paddockId == p.id && $0.field != nil }.count
        guard live < fields.max else {
            throw fieldError(tr("limite de fields deste cercado atingido: \(live) de \(fields.max) (fields.max); dispense um agente de field ou collie field drop <nome>\(hint)",
        "this paddock's field limit reached: \(live) of \(fields.max) (fields.max); dismiss a field agent or collie field drop <name>\(hint)"))
        }
        return (p, head)
    }

    /// Undoes a field a failed summon cut: off the record, worktree and branch gone (nothing was worked there).
    func unfield(_ terminal: UUID, _ lane: Lane?, paddock: Paddock?) async {
        guard let lane, let paddock else { return }
        if let i = ws.terminals.firstIndex(where: { $0.id == terminal }) { ws.terminals[i].field = nil }
        let git = fieldGit(paddock)
        try? await LaneWorktree.remove(lane, host: git)
        _ = try? await git.laneGit(["branch", "-D", lane.branch], in: lane.repoRoot)
    }

    /// `<root>/fields`: the fields' patches (answer 7).
    var fieldPatches: URL { config.paths.root.appendingPathComponent("fields") }

    /// Answer 8: the field `f` of paddock `p` leaves: `<root>/fields/<name>-wip.patch` with what is not committed
    /// (tracked and untracked, never ignored), then the worktree (never `branch -D`). A land in flight ends first: the
    /// worktree goes after it, in the background (`landHeld`: the caller holds the field's land lock, so now). A wip
    /// patch that fails or would be cut short keeps the worktree (`kept`): nothing uncommitted is lost unsaid.
    /// Returns the line for the Shepherd.
    func retireField(_ f: FieldRef, paddock p: Paddock, landHeld: Bool = false) async -> (line: String, wip: FieldWip, kept: Bool) {
        let lane = Self.fieldLane(f, paddock: p), git = fieldGit(p)
        let wip = await Self.wipPatch(lane, name: f.name, host: git, into: fieldPatches, cap: fieldWipCap)
        if case .failed(let why) = wip {
            return (tr("[collie] field \(f.name) dispensado, worktree mantida em \(lane.path.path): o patch do não commitado falhou (\(why)); "
                    + "commite ou salve à mão e rode collie field drop \(f.name).",
                    "[collie] field \(f.name) dismissed, worktree kept at \(lane.path.path): the patch of the uncommitted work failed (\(why)); "
                    + "commit or save by hand and run collie field drop \(f.name)."), wip, true)
        }
        let line = tr("[collie] field \(f.name) dispensado: branch \(f.branch) mantido", "[collie] field \(f.name) dismissed: branch \(f.branch) kept") + (wip.url.map { tr("; não commitado em \($0.path)", "; uncommitted work in \($0.path)") } ?? "")
            + tr("; collie field drop \(f.name) apaga o branch (guarda um patch).", "; collie field drop \(f.name) deletes the branch (keeps a patch).")
        let integrators = integrators
        let remove: @Sendable () async -> Void = {
            // ponytail: polled, as the land's own wait for the paddock (`FieldLand.landing`)
            while await integrators.isLanding(lane.branch) { await WorkLoop.nap(.milliseconds(500)) }
            try? await LaneWorktree.remove(lane, host: git)
        }
        if landHeld { try? await LaneWorktree.remove(lane, host: git) }
        else if await integrators.isLanding(lane.branch) { Task { await remove() } } else { await remove() }
        return (line, wip, false)
    }

    /// `<into>/<name>-wip.patch` (0600, replaced): `git diff HEAD` and every untracked file not ignored, as new files.
    /// `.none`: no worktree, or nothing uncommitted. `.failed`: git could not say, an output passed `cap` (a big
    /// untracked file is named), or the file could not be written; the caller keeps the worktree.
    static func wipPatch(_ lane: Lane, name: String, host: some LoopHost, into dir: URL, cap: Int = 64 << 20) async -> FieldWip {
        guard FileManager.default.fileExists(atPath: lane.path.path) else { return .none }
        func run(_ args: [String]) async -> ProcessResult? { try? await host.laneGit(args, stdin: nil, timeout: .seconds(120), cap: cap, in: lane.path) }
        guard let d = await run(["diff", "--binary", "HEAD"]), d.status == 0 else { return .failed(tr("git diff HEAD falhou",
        "git diff HEAD failed")) }
        if d.truncated { return .failed(tr("o diff passa do limite de \(cap) bytes",
        "the diff is over the limit of \(cap) bytes")) }
        var out = d.stdout, big: [String] = []
        guard let u = await run(["ls-files", "-z", "--others", "--exclude-standard"]), u.status == 0, !u.truncated else {
            return .failed(tr("git ls-files falhou",
        "git ls-files failed"))
        }
        for f in u.stdout.split(separator: "\0").map(String.init) {
            // exit 1: the two differ, as a new file always does
            guard let n = await run(["diff", "--no-index", "--binary", "--", "/dev/null", f]), n.status <= 1 else { return .failed(tr("git diff de \(f) falhou",
        "git diff of \(f) failed")) }
            if n.truncated { big.append(f) } else { out += n.stdout }
        }
        if !big.isEmpty { return .failed(tr("não rastreados grandes demais para o patch: \(big.prefix(5).joined(separator: ", "))",
        "untracked files too big for the patch: \(big.prefix(5).joined(separator: ", "))")) }
        guard !out.isEmpty else { return .none }
        let fm = FileManager.default, file = dir.appendingPathComponent("\(name)-wip.patch")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return .failed(tr("a pasta \(dir.path) não se cria",
        "the folder \(dir.path) cannot be created"))
        }
        try? fm.removeItem(at: file)
        return fm.createFile(atPath: file.path, contents: Data(out.utf8), attributes: [.posixPermissions: 0o600]) ? .saved(file) : .failed(tr("\(file.path) não se grava",
        "\(file.path) cannot be written"))
    }

    /// `field.list|land|drop` for the Shepherd `me`, on the fields of its own paddock.
    func fieldCommand(_ r: Request, by me: TerminalRecord) async throws -> JSONValue {
        guard let p = ws.paddocks.first(where: { $0.id == me.paddockId }), !p.isFolder else {
            throw fieldError(tr("fields vivem num cercado com worktree git: você não está num",
        "fields live in a paddock with a git worktree: you are not in one"))
        }
        let git = fieldGit(p)
        if r.command == "field.list" {
            var rows: [JSONValue] = []
            for t in ws.terminals where t.paddockId == p.id {
                guard let f = t.field else { continue }
                let range = f.base.isEmpty ? "HEAD..\(f.branch)" : "\(f.base)..\(f.branch)"
                let n = (try? await git.laneGit(["rev-list", "--count", range], in: git.dir)).flatMap { $0.status == 0 ? Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
                rows.append(.object(["name": .string(f.name), "agent": .string(t.name), "branch": .string(f.branch), "base": .string(f.base),
                                     "commits": n.map { .number(Double($0)) } ?? .null, "state": .string(f.state.rawValue)]))
            }
            return .object(["fields": .array(rows)])
        }
        let name = try need(r, "name")
        try LaneWorktree.validate(field: name)
        let rec = ws.terminals.first { $0.paddockId == p.id && $0.field?.name == name }
        // spec "Comandos": only the Shepherd that summoned the agent (the app: not in this delivery)
        if let rec, rec.summonedBy != me.id { throw ProtocolError(code: .notShepherd, message: tr("só o Pastor que convocou '\(rec.name)' integra ou descarta o field dele",
        "only the Shepherd that summoned '\(rec.name)' lands or discards its field")) }
        switch r.command {
        case "field.land":
            guard let rec, let f = rec.field else {
                throw fieldError(tr("field '\(name)' sem agente neste cercado: integre collie/field/\(name) à mão, ou collie field drop \(name)",
        "field '\(name)' has no agent in this paddock: land collie/field/\(name) by hand, or collie field drop \(name)"))
            }
            let out = await landSettled(Self.fieldLane(f, paddock: p), terminal: rec.id, by: me.id, asRequest: true)
            switch out {
            case .landed(let sha): return .object(["outcome": .string("landed"), "sha": .string(sha)])
            case .conflict(let why, let patch):
                return .object(["outcome": .string("conflict"), "reason": .string(why), "patch": patch.map { .string($0.path) } ?? .null])
            case .waiting(let why):
                // answer 6: the paddock not free in 10 min; the field stays ready, this reply is the Shepherd's notice
                if why != FieldLand.alreadyLanding, let i = ws.terminals.firstIndex(where: { $0.id == rec.id }) {
                    ws.terminals[i].field?.state = .ready
                    try? await persist()
                }
                return .object(["outcome": .string("waiting"), "reason": .string(why),
                                "message": .string(tr("[collie] field \(name) não integrou: \(why); tente de novo: collie field land \(name)",
        "[collie] field \(name) did not land: \(why); try again: collie field land \(name)"))])
            }
        case "field.drop":
            // the field's land lock for the whole drop: no land starts on a branch going away (a check's queued land
            // finds it taken), and none is running now
            let branch = rec?.field?.branch ?? LaneWorktree.fieldBranchPrefix + name
            guard await integrators.beginLanding(branch) else { throw fieldError(tr("field '\(name)': \(FieldLand.alreadyLanding); drop depois",
        "field '\(name)': \(FieldLand.alreadyLanding); drop later")) }
            let res: Result<JSONValue, Error>
            do { res = .success(try await dropField(name, rec: rec, paddock: p, keepBranch: flag(r, "keep-branch"))) } catch { res = .failure(error) }
            await integrators.endLanding(branch)
            return try res.get()
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// `field drop` with the field's land lock held: its agent (if on record) goes, then its worktree after a wip patch
    /// that worked, then (unless `keepBranch`) its branch after a patch of its commits.
    private func dropField(_ name: String, rec: TerminalRecord?, paddock p: Paddock, keepBranch: Bool) async throws -> JSONValue {
        let git = fieldGit(p), lane: Lane, wip: FieldWip
        if let rec, let f = rec.field {
            lane = Self.fieldLane(f, paddock: p)
            // the agent goes, then its field (wip patch, worktree); off the record first: no dismissal notice, this
            // reply says it all
            if let i = ws.terminals.firstIndex(where: { $0.id == rec.id }) { ws.terminals[i].field = nil }
            try await remove(rec)
            await fieldProbe?("drop")
            let out = await retireField(f, paddock: p, landHeld: true)
            if out.kept { throw fieldError(out.line) }
            wip = out.wip
        } else {
            // the paddocks folder is the repository's: a field of a live agent (here or in another paddock) is never
            // dropped by name. ponytail: no live agent, so no summoner on record: any Shepherd of the paddock drops it
            let branch = LaneWorktree.fieldBranchPrefix + name
            if let owner = ws.terminals.first(where: { $0.field?.name == name || $0.field?.branch == branch }) {
                let where_ = ws.paddocks.first { $0.id == owner.paddockId }?.name ?? "?"
                throw ProtocolError(code: .notShepherd, message: tr("field '\(name)' é do agente vivo '\(owner.name)' do cercado '\(where_)': só o Pastor dele o descarta",
        "field '\(name)' belongs to the live agent '\(owner.name)' of paddock '\(where_)': only its Shepherd discards it"))
            }
            guard let l = await LaneWorktree.field(named: name, repoRoot: URL(fileURLWithPath: p.repoRoot), host: git) else {
                throw ProtocolError(code: .notFound, message: tr("nenhum field '\(name)' neste cercado",
        "no field '\(name)' in this paddock"))
            }
            lane = l
            wip = await Self.wipPatch(lane, name: name, host: git, into: fieldPatches, cap: fieldWipCap)
            if case .failed(let why) = wip {
                throw fieldError(tr("field '\(name)': worktree mantida em \(lane.path.path), o patch do não commitado falhou (\(why)); commite ou salve à mão e tente de novo",
        "field '\(name)': worktree kept at \(lane.path.path), the patch of the uncommitted work failed (\(why)); commit or save by hand and try again"))
            }
            try await LaneWorktree.remove(lane, host: git)
        }
        var o: [String: JSONValue] = ["branch": .string(lane.branch)]
        if let u = wip.url { o["wip"] = .string(u.path) }
        if keepBranch { o["kept"] = .bool(true); return .object(o) }
        if let patch = await FieldLand.patch(lane, name: name, dir: git.dir, host: git, into: fieldPatches) { o["patch"] = .string(patch.path) }
        let d = try await git.laneGit(["branch", "-D", lane.branch], in: lane.repoRoot)
        guard d.status == 0 else { throw fieldError("git branch -D \(lane.branch): \(d.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        o["kept"] = .bool(false)
        return .object(o)
    }

    // MARK: F5: back by itself (spec "Volta", answers 4, 5, 9)

    func fieldCheckBegin(_ terminal: UUID) { if ws.terminals.contains(where: { $0.id == terminal && $0.field != nil }) { fieldChecks[terminal, default: 0] += 1 } }
    func fieldCheckEnd(_ terminal: UUID) {
        guard let n = fieldChecks[terminal] else { return }
        fieldChecks[terminal] = n > 1 ? n - 1 : nil
    }

    /// Answer 4: something tracked changed, or untracked and not ignored, in the field's tree `dir` (the daemon's git,
    /// no profile). Git that cannot say counts as dirty: nothing unjudged lands.
    static func fieldDirty(_ dir: URL) async -> Bool {
        guard let r = try? await RouterLoopHost.loopGit(["status", "--porcelain"], in: dir, profile: nil), r.status == 0, !r.truncated else { return true }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Answer 4, the try's verdict: dirty as `fieldDirty`; clean, the HEAD it judged is kept for the land
    /// (`fieldJudged`): the land merges that sha. A HEAD git cannot read counts as dirty.
    func fieldJudge(_ terminal: UUID, _ dir: URL) async -> Bool {
        fieldJudged[terminal] = nil
        guard !(await Self.fieldDirty(dir)), let h = await Self.rev("HEAD", in: dir) else { return true }
        fieldJudged[terminal] = h
        return false
    }

    /// Answer 5: a passing check on a field's agent queues its land and the ask ends now; the result reaches the
    /// Shepherd as a notice. Any other report goes back as it came. The land takes the sha the check judged, and only
    /// while it is the tip of the field's branch with the field's HEAD on that branch: nothing unjudged lands.
    func fieldAfterCheck(_ terminal: UUID, _ check: AskCheckReport?) async -> AskCheckReport? {
        let judged = fieldJudged.removeValue(forKey: terminal)
        guard var c = check, c.status == .passed, let rec = ws.terminals.first(where: { $0.id == terminal }), let f = rec.field,
              let p = ws.paddocks.first(where: { $0.id == rec.paddockId }) else { return check }
        if await integrators.isLanding(f.branch) { c.field = FieldNote(land: .skipped, reason: FieldLand.alreadyLanding); return c }
        let dir = URL(fileURLWithPath: f.path)
        // ponytail: no sha kept (a report with no field gate behind it, as the tests' own): the field's HEAD now
        let sha: String? = if let judged { judged } else { await Self.rev("HEAD", in: dir) }
        let tip = await Self.rev("refs/heads/" + f.branch, in: URL(fileURLWithPath: p.repoRoot))
        guard let sha, tip == sha, await Self.fieldOnBranch(dir, f.branch) else {
            c.field = FieldNote(land: .skipped, reason: tr("o commit julgado não é a ponta de \(f.branch)",
        "the judged commit is not the tip of \(f.branch)"))
            return c
        }
        c.field = FieldNote(land: .queued)
        let lane = Self.fieldLane(f, paddock: p)
        Task {
            let out = await self.landSettled(lane, terminal: terminal, by: nil, tip: sha)
            let line: String
            switch out {
            case .landed(let sha): line = tr("[collie] field \(f.name) integrado em \(sha.prefix(8))",
        "[collie] field \(f.name) landed at \(sha.prefix(8))")
            case .conflict(let why, let patch): line = tr("[collie] field \(f.name) não integrou: \(why); patch: \(patch?.path ?? "nenhum")", "[collie] field \(f.name) did not land: \(why); patch: \(patch?.path ?? "none")")
            case .waiting(let why): line = tr("[collie] field \(f.name) não integrou: \(why); patch: nenhum (collie field land \(f.name) tenta de novo)",
        "[collie] field \(f.name) did not land: \(why); patch: none (collie field land \(f.name) tries again)")
            }
            await self.fieldNotify(terminal, line)
        }
        return c
    }

    /// `landField`, then (landed) the field rebased on the paddock's new HEAD (answer 9). `tip`: the sha to merge.
    func landSettled(_ lane: Lane, terminal: UUID, by: UUID?, asRequest: Bool = false, tip: String? = nil) async -> FieldLand.Outcome {
        let out = await landField(lane, terminal: terminal, by: by, asRequest: asRequest, tip: tip)
        if case .landed = out { await rebaseField(terminal, checkBusy: true) }
        return out
    }

    /// The commit `what` names in `dir` (the daemon's git), nil when git cannot say.
    static func rev(_ what: String, in dir: URL) async -> String? {
        guard let r = try? await RouterLoopHost.loopGit(["rev-parse", "--verify", "-q", what + "^{commit}"], in: dir, profile: nil), r.status == 0 else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// The field's HEAD is its own branch: the agent writes its worktree's HEAD, and a HEAD pointed at another branch
    /// (or detached) is never moved nor merged by the daemon's git.
    static func fieldOnBranch(_ dir: URL, _ branch: String) async -> Bool {
        guard let r = try? await RouterLoopHost.loopGit(["symbolic-ref", "-q", "HEAD"], in: dir, profile: nil), r.status == 0 else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/" + branch
    }

    /// Answer 9: the field's branch moved onto the paddock's HEAD, only with its HEAD on its own branch, its agent out
    /// of a turn (`checkBusy`: asked now; the end of its turn needs not) and its tracked tree clean; else `behind`,
    /// tried again at its next turn's end. Its commits not in the paddock are rebased in a scratch worktree (the
    /// field's tree is never mid-rebase); the field then takes the result by `reset --keep`, after the same look
    /// again: a change made meanwhile is never discarded (git refuses, and the field stays `behind`). Done: `working`
    /// from the new `base`. A rebase that conflicts touches nothing: `conflict`.
    func rebaseField(_ terminal: UUID, checkBusy: Bool) async {
        guard let rec = ws.terminals.first(where: { $0.id == terminal }), let f = rec.field,
              let p = ws.paddocks.first(where: { $0.id == rec.paddockId }) else { return }
        let git = fieldGit(p), dir = URL(fileURLWithPath: f.path), repo = URL(fileURLWithPath: p.repoRoot)
        func set(_ st: FieldRef.State, base: String? = nil) async {
            guard let i = ws.terminals.firstIndex(where: { $0.id == terminal }), ws.terminals[i].field?.branch == f.branch else { return }
            ws.terminals[i].field?.state = st
            if let base { ws.terminals[i].field?.base = base }
            try? await persist()
        }
        func free() async -> Bool {
            guard !(checkBusy ? await targetBusy(terminal) : false), await Self.fieldOnBranch(dir, f.branch),
                  let st = try? await git.laneGit(["status", "--porcelain", "--untracked-files=no"], in: dir), st.status == 0 else { return false }
            return st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard await free(), let tip = await Self.rev("refs/heads/" + f.branch, in: repo), let head = await Self.rev("HEAD", in: git.dir) else {
            await set(.behind); return
        }
        var to = head
        if (try? await git.laneGit(["merge-base", "--is-ancestor", tip, head], in: repo))?.status != 0 {
            guard let r = await LaneWorktree.rebased(tip, onto: head, repoRoot: repo, scratch: fieldPatches, host: git) else {
                await set(.conflict)
                await fieldNotify(terminal, tr("[collie] field \(f.name): o rebase em \(head.prefix(8)) conflitou; nada mudou no field",
        "[collie] field \(f.name): the rebase onto \(head.prefix(8)) conflicted; nothing changed in the field"))
                return
            }
            to = r
        }
        await fieldProbe?("rebase.reset")
        // measured again right before: a new turn, an edit or a commit since waits for the next turn's end
        guard await free(), await Self.rev("refs/heads/" + f.branch, in: repo) == tip,
              (try? await git.laneGit(["reset", "-q", "--keep", to], in: dir))?.status == 0 else { await set(.behind); return }
        await set(.working, base: head)
    }

    /// The end of a field agent's turn: `behind` tries its rebase again; `working` with commits past `base` and no
    /// `ask --check` in flight becomes `ready`, with one notice to the Shepherd.
    func fieldTurnEnded(_ terminal: UUID) async {
        guard let rec = ws.terminals.first(where: { $0.id == terminal }), let f = rec.field,
              let p = ws.paddocks.first(where: { $0.id == rec.paddockId }) else { return }
        switch f.state {
        case .behind: await rebaseField(terminal, checkBusy: false)
        case .working:
            guard fieldChecks[terminal] == nil else { return }
            let git = fieldGit(p), range = f.base.isEmpty ? "HEAD..\(f.branch)" : "\(f.base)..\(f.branch)"
            guard let n = try? await git.laneGit(["rev-list", "--count", range], in: git.dir), n.status == 0,
                  (Int(n.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0,
                  let i = ws.terminals.firstIndex(where: { $0.id == terminal }), ws.terminals[i].field?.state == .working else { return }
            ws.terminals[i].field?.state = .ready
            try? await persist()
            await fieldNotify(terminal, "[collie] field \(f.name) pronto para integrar: collie field land \(f.name)")
        default: return
        }
    }

    /// A field notice to the Shepherd that summoned `terminal`'s agent, typed once it is quiet.
    func fieldNotify(_ terminal: UUID, _ line: String) async {
        await fieldTell(ws.terminals.first(where: { $0.id == terminal })?.summonedBy, line)
    }

    /// A field notice to the Shepherd `up` (an agent), typed once it is quiet.
    func fieldTell(_ up: UUID?, _ line: String) async {
        fieldNoticeLog = Array((fieldNoticeLog + [line]).suffix(20))
        guard let up, let s = ws.terminals.first(where: { $0.id == up }), Self.isAgent(s) else { return }
        try? await asks.inject(to: s.id, prompt: line, hold: .seconds(1800), afterQuiet: true)
    }
}

/// What a field's wip patch came to (`CommandRouter.wipPatch`).
enum FieldWip: Equatable {
    case none, saved(URL), failed(String)
    var url: URL? { if case .saved(let u) = self { u } else { nil } }
}
