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
        if on && off { throw fieldError("--field e --no-field juntos: escolha um") }
        guard !off, let p = ws.paddocks.first(where: { $0.id == me.paddockId }), !p.isFolder else {
            if on { throw fieldError("--field precisa de um cercado com worktree git: você não está num") }
            return nil
        }
        let shapeRefusal: String? =
            !sandboxed(me) ? "--field só com o sandbox de terminais: o agente de um field roda no sandbox estrito dele"
            : preset == .shell ? "--field é para agentes, não para shell"
            : str(r, "paddock") != nil || str(r, "cwd") != nil ? "--field não aceita --paddock nem --cwd: o field é cortado do seu cercado"
            : asShepherd ? "--field não aceita --shepherd: um sub-Pastor fica no cercado"
            : (try? LaneWorktree.validate(field: name)) == nil ? "nome de field inválido '\(name)' (o field leva o nome do agente: a-z, 0-9 e '-', até 40)" : nil
        if on, let shapeRefusal { throw fieldError(shapeRefusal) }
        let git = fieldGit(p)
        guard let h = try? await git.laneGit(["rev-parse", "HEAD"], in: git.dir), h.status == 0 else {
            if on { throw fieldError("o HEAD do cercado '\(p.name)' não se lê: nenhum field cortado") }
            return nil
        }
        let head = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // answer 10: the committed file, never the tree (an agent turns no default on by editing); invalid: the defaults
        let fields = ((try? await WorkConfigFile.config(base: head, dir: git.dir).get()) ?? nil)?.fields ?? ProjectWorkConfig.FieldsConfig()
        guard on || (fields.default && shapeRefusal == nil) else { return nil }
        let hint = on ? "" : " (fields.default do collie-work.json; --no-field convoca sem field)"
        let lanes = ((try? await work.list(includeClosed: true)) ?? []).contains {
            $0.paddockId == p.id && $0.loop?.state == .running && ($0.loop?.parallel ?? 1) > 1
        }
        if lanes { throw fieldError("há um laço em faixas (work run --parallel) rodando neste cercado: field e faixas não convivem; espere ele terminar\(hint)") }
        let live = ws.terminals.filter { $0.paddockId == p.id && $0.field != nil }.count
        guard live < fields.max else {
            throw fieldError("limite de fields deste cercado atingido: \(live) de \(fields.max) (fields.max); dispense um agente de field ou collie field drop <nome>\(hint)")
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
    /// worktree goes after it, in the background. Returns the line for the Shepherd.
    func retireField(_ f: FieldRef, paddock p: Paddock) async -> String {
        let lane = Self.fieldLane(f, paddock: p), git = fieldGit(p)
        let wip = await Self.wipPatch(lane, name: f.name, host: git, into: fieldPatches)
        let line = "[collie] field \(f.name) dispensado: branch \(f.branch) mantido" + (wip.map { "; não commitado em \($0.path)" } ?? "")
            + "; collie field drop \(f.name) apaga o branch (guarda um patch)."
        let integrators = integrators
        let remove: @Sendable () async -> Void = {
            // ponytail: polled, as the land's own wait for the paddock (`FieldLand.landing`)
            while await integrators.isLanding(lane.branch) { await WorkLoop.nap(.milliseconds(500)) }
            try? await LaneWorktree.remove(lane, host: git)
        }
        if await integrators.isLanding(lane.branch) { Task { await remove() } } else { await remove() }
        return line
    }

    /// `<into>/<name>-wip.patch` (0600, replaced): `git diff HEAD` and every untracked file not ignored, as new files.
    /// Nil: nothing uncommitted, no worktree, or git cannot say.
    static func wipPatch(_ lane: Lane, name: String, host: some LoopHost, into dir: URL) async -> URL? {
        guard FileManager.default.fileExists(atPath: lane.path.path),
              let d = try? await host.laneGit(["diff", "--binary", "HEAD"], in: lane.path), d.status == 0, !d.truncated else { return nil }
        var out = d.stdout
        if let u = try? await host.laneGit(["ls-files", "-z", "--others", "--exclude-standard"], in: lane.path), u.status == 0 {
            for f in u.stdout.split(separator: "\0") {
                // exit 1: the two differ, as a new file always does
                if let n = try? await host.laneGit(["diff", "--no-index", "--binary", "--", "/dev/null", String(f)], in: lane.path),
                   n.status <= 1, !n.truncated { out += n.stdout }
            }
        }
        guard !out.isEmpty else { return nil }
        let fm = FileManager.default, file = dir.appendingPathComponent("\(name)-wip.patch")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        try? fm.removeItem(at: file)
        return fm.createFile(atPath: file.path, contents: Data(out.utf8), attributes: [.posixPermissions: 0o600]) ? file : nil
    }

    /// `field.list|land|drop` for the Shepherd `me`, on the fields of its own paddock.
    func fieldCommand(_ r: Request, by me: TerminalRecord) async throws -> JSONValue {
        guard let p = ws.paddocks.first(where: { $0.id == me.paddockId }), !p.isFolder else {
            throw fieldError("fields vivem num cercado com worktree git: você não está num")
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
        if let rec, rec.summonedBy != me.id { throw ProtocolError(code: .notShepherd, message: "só o Pastor que convocou '\(rec.name)' integra ou descarta o field dele") }
        switch r.command {
        case "field.land":
            guard let rec, let f = rec.field else {
                throw fieldError("field '\(name)' sem agente neste cercado: integre collie/field/\(name) à mão, ou collie field drop \(name)")
            }
            let out = await landField(Self.fieldLane(f, paddock: p), terminal: rec.id, by: me.id, asRequest: true)
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
                                "message": .string("[collie] field \(name) não integrou: \(why); tente de novo: collie field land \(name)")])
            }
        case "field.drop":
            let lane: Lane
            if let rec, let f = rec.field {
                guard await !integrators.isLanding(f.branch) else { throw fieldError("field '\(name)': \(FieldLand.alreadyLanding); drop depois") }
                lane = Self.fieldLane(f, paddock: p)
                // the agent goes, then its field (wip patch, worktree); off the record first: no dismissal notice, this
                // reply says it all
                if let i = ws.terminals.firstIndex(where: { $0.id == rec.id }) { ws.terminals[i].field = nil }
                try await remove(rec)
                _ = await retireField(f, paddock: p)
            } else {
                // ponytail: its agent already dismissed, so no summoner on record: any Shepherd of the paddock drops it
                guard let l = await LaneWorktree.field(named: name, repoRoot: URL(fileURLWithPath: p.repoRoot), host: git) else {
                    throw ProtocolError(code: .notFound, message: "nenhum field '\(name)' neste cercado")
                }
                lane = l
                try await LaneWorktree.remove(lane, host: git)
            }
            var o: [String: JSONValue] = ["branch": .string(lane.branch)]
            if FileManager.default.fileExists(atPath: fieldPatches.appendingPathComponent("\(name)-wip.patch").path) {
                o["wip"] = .string(fieldPatches.appendingPathComponent("\(name)-wip.patch").path)
            }
            if flag(r, "keep-branch") { o["kept"] = .bool(true); return .object(o) }
            if let patch = await FieldLand.patch(lane, name: name, dir: git.dir, host: git, into: fieldPatches) { o["patch"] = .string(patch.path) }
            let d = try await git.laneGit(["branch", "-D", lane.branch], in: lane.repoRoot)
            guard d.status == 0 else { throw fieldError("git branch -D \(lane.branch): \(d.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            o["kept"] = .bool(false)
            return .object(o)
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }
}
