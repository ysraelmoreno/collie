import Foundation
import CollieCore
import CollieProtocol

/// Shepherd-only commands. Leashes are the only permission: every target is resolved within
/// `ConnectionGraph.reachable(from: shepherd)`; no admin power is involved.
extension CommandRouter {
    func shepherd(_ r: Request, from tid: UUID) async throws -> JSONValue {
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.isShepherd else {
            throw ProtocolError(code: .notShepherd, message: "'\(r.command)' is Shepherd-only"
                + (r.command == "summon" ? tr("; peça a quem te convocou (collie ask <nome> --no-wait) ou ao usuário para te marcar como Pastor no app", "; ask whoever summoned you (collie ask <name> --no-wait) or the user to mark you as a Shepherd in the app") : ""))
        }
        func peer(_ k: String) throws -> TerminalRecord { try ConnectionGraph.resolve(name: try need(r, k), from: me.id, in: ws) }
        // same rule for panels: within the Shepherd's reach (canvas: leashed to it; dock: always)
        func reachablePanel(_ name: String) throws -> Panel {
            let p = try findPanel(name)
            guard ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.id == p.id }) else {
                throw ProtocolError(code: .notConnected, message: "No connection to panel '\(p.name)'. Connect it first.")
            }
            return p
        }
        switch r.command {
        case "summon": return try await summon(r, by: me)
        case "field.list", "field.land", "field.drop": return try await fieldCommand(r, by: me)
        case "dismiss":
            let t = try peer("target")
            // a sub-Shepherd only by the one that summoned it; its own summoned go first (the app's Shepherd never)
            guard !t.isShepherd || t.summonedBy == me.id else { throw ProtocolError(code: .invalidArgs, message: "cannot dismiss Shepherd '\(t.name)'") }
            for d in summonedTree(of: t.id) { try await remove(d) }
            try await remove(t)
        case "leash":
            // both ends already within reach: the Shepherd itself doesn't count, leashing it to a stranger would widen its reach
            if let (t, p) = try panelPair(r, terminal: { try ConnectionGraph.resolve(name: $0, from: me.id, in: ws) },
                                          panel: reachablePanel) {
                try await leash(t, p)
            } else {
                try await leash(try peer("a"), try peer("b"))
            }
        case "unleash":
            func peerOrSelf(_ name: String) throws -> TerminalRecord {
                do { return try ConnectionGraph.resolve(name: name, from: me.id, in: ws) } catch {
                    guard error.code == .notConnected && me.name.caseInsensitiveCompare(name) == .orderedSame else { throw error }
                    return me
                }
            }
            if let (t, p) = try panelPair(r, terminal: peerOrSelf, panel: reachablePanel) {
                try await unleash(t, p)
            } else {
                try await unleash(try peerOrSelf(try need(r, "a")), try peerOrSelf(try need(r, "b")))
            }
        case "leash.request": return try await requestLeash(r, by: me)
        case "notify":
            let m = try need(r, "message")
            guard m.count <= 2000 else { throw ProtocolError(code: .invalidArgs, message: "'message' exceeds 2000 characters") }
            await hub.emit(.notify(me.id, message: m))
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
        return .object([:])
    }

    /// Most terminals a sub-Shepherd (one summoned by a Shepherd) keeps alive, and how deep a chain of them goes below an
    /// app-marked Shepherd (app → sub → sub-sub). ponytail: constants; two concurrent summons may overshoot the ceiling by one.
    static let subShepherdCeiling = 6, subShepherdDepth = 2

    /// How many `summonedBy` steps lead from `rec` to a terminal nobody summoned (the app's Shepherd: 0).
    func summonDepth(of rec: TerminalRecord) -> Int {
        var n = 0, cur = rec
        while n <= Self.subShepherdDepth + 8, let up = cur.summonedBy, let p = ws.terminals.first(where: { $0.id == up }) { n += 1; cur = p }
        return n
    }

    /// Everything `id` summoned, deepest first (so a dismissal removes the leaves before the branch).
    func summonedTree(of id: UUID) -> [TerminalRecord] {
        ws.terminals.filter { $0.summonedBy == id }.flatMap { summonedTree(of: $0.id) + [$0] }
    }

    /// `--connect a,b`: terminals and canvas panels the Shepherd `me` already reaches (never a free terminal, a headless
    /// or a dock panel), all checked before anything is created. `panels: false` (a new panel's): terminals only.
    func connectTargets(_ r: Request, by me: TerminalRecord, panels: Bool = true) throws -> (terminals: [TerminalRecord], panels: [Panel]) {
        var ts: [TerminalRecord] = [], ps: [Panel] = []
        for n in (str(r, "connect") ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty {
            if let p = panel(named: n) {
                guard panels else { throw ProtocolError(code: .invalidArgs, message: "cannot connect a panel to a panel ('\(p.name)')") }
                if p.placement == .headless { throw ProtocolError(code: .invalidArgs, message: "a headless panel is reachable only by the terminal that opened it") }
                guard p.placement == .canvas else { throw ProtocolError(code: .invalidArgs, message: "dock panels need no leash ('\(p.name)')") }
                guard ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.id == p.id }) else {
                    throw ProtocolError(code: .notConnected, message: "No connection to panel '\(p.name)'. Connect it first.")
                }
                ps.append(p)
            } else {
                if let t = ws.terminals.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { try refuseFreeLeash(t.id) }
                ts.append(try ConnectionGraph.resolve(name: n, from: me.id, in: ws))
            }
        }
        return (ts, ps)
    }

    /// Leashes `rec` to the `--connect` targets of `r`, re-checked now (after the caller's awaits a target may have left reach).
    func wire(_ rec: TerminalRecord, _ r: Request, by me: TerminalRecord) async throws {
        let (ts, ps) = try connectTargets(r, by: me)
        for t in ts { try await leash(rec, t) }
        for p in ps { try await leash(rec, p) }   // link refuses a panel closed meanwhile
    }

    /// `lane` (M3.3, the loop's own; no request carries it): the new terminal stands in `me`'s paddock with the lane as
    /// its folder and its project, so its sandbox is the lane's (strict, closed to the paddock's worktree and the other lanes).
    /// `scratch` (F2 X1, the loop's own; no request carries it): a reviewer, born in that empty folder the daemon made,
    /// as its folder and its project: never the worktree, so nothing the judged agent committed loads there.
    func summon(_ r: Request, by me: TerminalRecord, lane: URL? = nil, scratch: URL? = nil) async throws -> JSONValue {
        let name = try need(r, "name")
        try refuseFree(r)
        try refuseFreeSummoner(me)
        let sub = me.summonedBy != nil   // a sub-Shepherd: summoned, not marked by the app
        if sub {
            guard str(r, "paddock") == nil else {
                throw ProtocolError(code: .notShepherd, message: "a sub-Shepherd stays in its summoner's paddock: no --paddock")
            }
            let live = ws.terminals.filter { $0.summonedBy == me.id }.count
            guard live < Self.subShepherdCeiling else {
                throw ProtocolError(code: .invalidArgs, message: "a sub-Shepherd keeps at most \(Self.subShepherdCeiling) terminals ('\(me.name)' has \(live)): dismiss one first")
            }
        }
        let asShepherd = flag(r, "shepherd")
        if asShepherd, summonDepth(of: me) + 1 > Self.subShepherdDepth {
            throw ProtocolError(code: .invalidArgs, message: "sub-Shepherds go at most depth \(Self.subShepherdDepth) below the app's Shepherd ('\(me.name)' is at depth \(summonDepth(of: me)))")
        }
        try reserve(name); defer { launching.remove(name.lowercased()) }
        // no preset: the Shepherd's own (with its command, for a custom one); a shell only when asked for
        let preset = try str(r, "preset").map { try Preset.parse($0) } ?? me.preset
        let command = str(r, "command") ?? (str(r, "preset") == nil ? me.command : nil)
        let model = str(r, "model")
        if let model {
            try ClaudeModel.validate(model)
            let probe = TerminalRecord(id: UUID(), name: name, preset: preset, command: command, cwd: "/", isShepherd: false)
            guard preset == .claude || AgentLaunch.isClaude(probe) || Self.agentName(probe) == "cursor" else {
                throw ProtocolError(code: .invalidArgs, message: "--model is for claude; '\(name)' would run \(preset.rawValue)")
            }
        }
        if let t = try lookup(name) {
            let hint = ConnectionGraph.reachable(from: me.id, in: ws).contains { $0.id == t.id }
                ? "it is leashed to you: collie ask \(t.name) \"…\"" : "not leashed to you. " + ConnectionGraph.leashHint(t.name, for: me.id, in: ws)
            throw ProtocolError(code: .invalidArgs, message: "terminal '\(t.name)' already exists; \(hint)")
        }
        _ = try connectTargets(r, by: me)   // before the launch: a refused target creates nothing
        // F4: `--field` (or the paddock's `fields.default`): checked before anything is made; never for the loop's own
        let fieldPick = lane == nil && scratch == nil ? try await fieldWanted(r, name: name, by: me, preset: preset, asShepherd: asShepherd) : nil
        let id = UUID()
        var fieldLane: Lane?
        var paddockId = me.paddockId, cwd = me.cwd
        var allowed = try await projectRoot(of: me)   // the new terminal's project stays within it
        if let f = str(r, "paddock") {
            let fl = try findPaddock(f)
            // user-created paddocks (createdBy nil) are open only to a Shepherd standing in them
            guard fl.createdBy == me.id || fl.id == me.paddockId else {
                throw ProtocolError(code: .notShepherd, message: "paddock '\(fl.name)' belongs to another Shepherd")
            }
            paddockId = fl.id; cwd = fl.path; allowed = ProjectRoot.resolve(cwd: fl.path, paddock: fl)
        }
        cwd = SignedAppCheck.realPath(URL(fileURLWithPath: str(r, "cwd") ?? cwd))   // spawned as checked (no symlink swap)
        if let lane {
            // the daemon put the lane there itself: no card. Only sandboxed, in the work's paddock, and with the lane
            // its own git toplevel (what `ProjectRoot` finds from inside it): else refused, the lane stays untouched
            guard sandboxed(me), str(r, "paddock") == nil, str(r, "cwd") == nil, let p = ws.paddocks.first(where: { $0.id == paddockId }) else {
                throw ProtocolError(code: .unavailable, message: "a lane's agent runs only sandboxed, in the work's paddock")
            }
            cwd = try Self.vetLane(lane, paddock: p).path
            guard ProjectRoot.resolve(cwd: cwd, paddock: nil, home: sandboxHomeDir).path == cwd else {
                throw ProtocolError(code: .unavailable, message: "lane \(cwd) is not its own project root")
            }
        }
        if let fieldPick {
            // F4: the daemon cuts it from the paddock's HEAD (its own git), then vets it as a lane: same strict profile
            let fl = try await LaneWorktree.createField(repoRoot: URL(fileURLWithPath: fieldPick.paddock.repoRoot), base: fieldPick.base,
                                                        name: name, owner: id, host: fieldGit(fieldPick.paddock))
            fieldLane = fl
            do {
                cwd = try Self.vetLane(fl.path, paddock: fieldPick.paddock).path
                guard ProjectRoot.resolve(cwd: cwd, paddock: nil, home: sandboxHomeDir).path == cwd else {
                    throw ProtocolError(code: .unavailable, message: "field \(cwd) is not its own project root")
                }
            } catch { await unfield(id, fl, paddock: fieldPick.paddock); throw error }
        }
        if let scratch {
            // the daemon made the folder itself: no card, as for a lane
            guard lane == nil, str(r, "paddock") == nil, str(r, "cwd") == nil else {
                throw ProtocolError(code: .unavailable, message: "a reviewer runs only in its own scratch folder")
            }
            cwd = SignedAppCheck.realPath(scratch)
        }
        // DX backlog 15, strict mode: outside the project only into a folder the user released to this Shepherd; else a card
        var anywhere = startedOpen(me)
        if lane == nil, scratch == nil, fieldLane == nil, !anywhere, !ProjectRoot.contains(cwd, root: allowed) {
            let released = SandboxGrantStore.applicable(sandboxGrants, terminal: me.id, project: me.projectRoot, lot: ws.lot(of: me.id)?.id)
                .contains { $0.access == .write && ProjectRoot.contains(cwd, root: URL(fileURLWithPath: $0.path)) }
            guard released else {
                // a card only for a terminal actually sandboxed (the others' denials raise none either)
                let card = sandboxKnown.contains(me.id)
                if card { await raise(SandboxDenial(terminal: me.id, op: "write", path: cwd, requested: true, reason: "summon \(name) em \(cwd)")) }
                throw ProtocolError(code: .invalidArgs, message: "--cwd \(cwd) is outside your project \(allowed.path)"
                    + (card ? ": a card asks the user to release it; summon again once they do" : ""))
            }
            anywhere = true
        }
        let root = lane != nil || scratch != nil || fieldLane != nil ? URL(fileURLWithPath: cwd)
            : try childProject(cwd: cwd, paddock: ws.paddocks.first { $0.id == paddockId }, allowed: allowed, open: anywhere)
        var rec = TerminalRecord(id: id, name: name, preset: preset, command: command,
                                 cwd: cwd, isShepherd: false, paddockId: paddockId, projectRoot: root.path)
        if let fl = fieldLane { rec.field = FieldRef(name: name, branch: fl.branch, base: fl.base, path: cwd) }
        rec.model = model
        rec.isShepherd = asShepherd   // before the launch: COLLIE_SHEPHERD and the Shepherd orientation come with the first session
        rec.summonedBy = me.id
        // F2 X4: a reviewer is marked before it exists, so no other loop of the paddock ever counts it as working;
        // unmarked again if the summon fails
        var born = false
        if scratch != nil { loopReviewers.insert(rec.id) }
        defer { if scratch != nil, !born { loopReviewers.remove(rec.id) } }
        var result: [String: JSONValue]
        do {
            result = try await launch(rec)
            try await ensurePaddock(of: rec)
        } catch {
            // F2 Y2a: a reviewer that fails after its launch (`persist`, its paddock gone) goes BEFORE it is unmarked:
            // else, alive and unmarked, it is "another agent working" until the daemon starts again
            if scratch != nil { try? await remove(rec) }
            await unfield(rec.id, fieldLane, paddock: fieldPick?.paddock)   // F4: nothing worked in it yet
            if fieldLane != nil { try? await remove(rec) }
            throw error
        }
        do {
            try await leash(me, rec)
            try await wire(rec, r, by: me)   // re-checked: a target may have left reach during the launch
            // F2 W1: a reviewer joins no lot (no lot_board of the judged agent's group, reviewerNoMcp)
            if scratch == nil, let l = ws.lot(of: me.id) { try await place([rec.id], in: l.id); result["lot"] = .string(l.name) }   // grouping, never reach
        } catch { await unfield(rec.id, fieldLane, paddock: fieldPick?.paddock); try? await remove(rec); throw error }
        if let fl = fieldLane { result["field"] = .object(["name": .string(name), "branch": .string(fl.branch), "path": .string(cwd)]) }
        if let p = str(r, "prompt"), !p.isEmpty {
            // the summon exists either way: report, don't fail (a retry would hit "already exists")
            do { try await asks.inject(to: rec.id, prompt: p) } catch {
                result["promptError"] = .string("\(error.code.rawValue): \(error.message)")
            }
        }
        born = true
        return .object(result)
    }
}

extension Preset {
    /// The one validation of a preset's text: every command that takes `preset` goes through here.
    static func parse(_ s: String) throws(ProtocolError) -> Preset {
        guard let p = Preset(rawValue: s) else {
            throw ProtocolError(code: .invalidArgs, message: "preset must be shell|claude|codex|cursor|custom")
        }
        return p
    }
}
