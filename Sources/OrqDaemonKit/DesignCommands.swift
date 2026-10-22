import Foundation
import OrqCore
import OrqProtocol

extension CommandRouter {
    /// A `design.*` command, run by the daemon. Cords are the only permission (a canvas panel needs one, a docked one is
    /// open to all); a panel-bound command edits the panel's file through the caller's own client. `design.files`,
    /// `design.new` and `design.help` have no panel; `design.link` answers only the admin (the app).
    func designCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        switch r.command {
        case "design.files":
            let visible = (caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels).filter { $0.pluginId == "design" }
            return .array(try await design.list().map { f in
                .object(["name": .string(f.name),
                         "panels": .array(visible.filter { $0.state["file"] == .string(f.id) }.map(\.name).sorted().map { .string($0) })])
            })
        case "design.new":
            let floor: UUID?
            if let me = caller {   // a terminal's files go on its own floor
                if r.args["floor"] != nil { throw ProtocolError(code: .invalidArgs, message: "--floor is for the app only") }
                floor = me.floorId.flatMap { id in ws.floors.contains { $0.id == id } ? id : nil }
            } else {
                floor = try str(r, "floor").map { n throws(ProtocolError) in try findFloor(n).id }
            }
            let deadline = design.deadline(r.command)
            let f = try await design.create(try need(r, "name"), floor: floor, deadline: deadline)
            var out: [String: JSONValue] = ["name": .string(f.name)]
            out.merge(await enableActiveSystem(f, deadline)) { _, b in b }
            return .object(out)
        case "design.help":
            // figcraft's commands, then Orq's own design.system.* (one line each), kept by the same query
            let q = (try str(r, "query") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let own: [JSONValue] = (PluginRegistry.spec("design")?.commands ?? []).filter { c in
                c.name.hasPrefix("design.system.") && (q.isEmpty || c.name.lowercased().contains(q) || c.summary.lowercased().contains(q))
            }.map { .object(["id": .string($0.name), "help": .string($0.summary)]) }
            guard case .array(let rows) = try await design.help(str(r, "query")) else { return .array(own) }
            return .array(rows + own)
        case "design.system.list":
            return .array(try await systems.list().map { ds in
                var active = ws.floors.filter { $0.designSystem == ds.id }.map { JSONValue.string("floor:\($0.name)") }
                    .sorted { "\($0)" < "\($1)" }
                if ws.designSystem == ds.id { active.append(.string("workspace")) }
                var row: [String: JSONValue] = ["name": .string(ds.name), "version": .number(Double(ds.version)), "active": .array(active)]
                if let v = ds.reverted { row["reverted"] = .number(Double(v)) }
                return .object(row)
            })
        case "design.system.history":
            return try isoJSON(try await systems.history(name: try need(r, "name")))
        case "design.system.create", "design.system.publish", "design.system.revert":
            let name = try need(r, "name"), reason = try systemReason(r)
            let by = caller?.name ?? "app"
            let out: DesignSystemService.Outcome, kind: String
            switch r.command {
            case "design.system.create":
                out = try await systems.create(name: name, from: str(r, "from"), reason: reason, by: by)
                kind = "created"
            default:
                let ds = try await systems.system(named: name)
                if let me = caller {   // a terminal changes only a system whose Design panel it reaches
                    let fid = JSONValue.string(ds.fileId.uuidString.lowercased())
                    guard ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.pluginId == "design" && $0.state["file"] == fid }) else {
                        throw ProtocolError(code: .notConnected, message: "'\(r.command)' needs a cord to a Design panel of '\(name)'")
                    }
                }
                let to = r.command == "design.system.revert" ? try DeviceService.int(r.args, "to", 1...1_000_000) : nil
                if r.command == "design.system.revert", to == nil { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'to'") }
                // the version and its propagation under the scope lock: the users can't change scope meanwhile
                // ponytail: held for the whole publish (one deadline for the wait and the work); a scope change waits for it
                let deadline = design.deadline(r.command)
                try await lockDesignScopes(deadline); defer { designScopeBusy = false }
                let users = try await screenFiles().filter { activeSystem(floor: $0.floorId) == ds.id }
                if let to {
                    out = try await systems.revert(name: name, to: to, reason: reason, by: by, users: users, deadline: deadline)
                    kind = "reverted"
                } else {
                    out = try await systems.publish(name: name, reason: reason, by: by, users: users, force: flag(r, "force"), deadline: deadline)
                    kind = "published"
                }
            }
            let ds = out.system
            var res: [String: JSONValue] = ["name": .string(ds.name), "version": .number(Double(ds.version))]
            if let e = out.snapshotError { res["snapshotError"] = .string("the version is out but its snapshot was not kept: \(e)") }
            if !out.files.isEmpty { res["files"] = try isoJSON(out.files) }
            if let e = await decide(subject: "design system \(ds.name)", title: "Design system \(ds.name) v\(ds.version) (\(kind))",
                                    body: "Reason: \(reason)" + Self.filesLine(out.files), by: Self.origin(caller)) { res["memoryError"] = .string(e) }
            await systemChanged(["name": .string(ds.name), "version": .number(Double(ds.version)), "kind": .string(kind)])
            return .object(res)
        case "design.system.use", "design.system.undo":
            return try await activate(r, caller: caller)
        case "design.system.tokens", "design.system.bind", "design.system.style", "design.system.place", "design.system.mode":
            // the panel's file (cord rule as any panel-bound command); its effective system picks the library
            let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "design", from: caller?.id, in: ws)
            guard case .string(let fid)? = panel.state["file"], let f = try await design.list().first(where: { $0.id == fid }),
                  !(try await systems.systemFileIds()).contains(fid), let id = activeSystem(floor: f.floorId),
                  let ds = try await systems.list().first(where: { $0.id == id }) else {
                throw ProtocolError(code: .invalidArgs, message: "no active design system for this file")
            }
            return try await systems.wrapped(r.command, r.args, ds: ds, panel: panel, file: fid,
                                             caller: caller.map { ($0.id.uuidString, $0.name) } ?? ("app", "app"))
        case "design.link" where caller != nil:
            throw ProtocolError(code: .unauthorized, message: "'design.link' is for the app only")
        case "design.export" where str(r, "format") == "html":   // a complete document, kept as an artifact
            let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "design", from: caller?.id, in: ws)
            let node = str(r, "node"), deadline = design.deadline(r.command)   // one for the whole export
            let (f, snap) = try await design.htmlSnapshot(panel: panel, caller: caller.map { ($0.id.uuidString, $0.name) } ?? ("app", "app"),
                                                          node: node, deadline: deadline)
            return try await exportHTML(f, node: node, snapshot: snap, by: Self.origin(caller), deadline: deadline)
        default:
            let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "design", from: caller?.id, in: ws)
            var args = r.args; args["panel"] = nil
            return try await design.run(r.command, panel: panel, caller: caller.map { ($0.id.uuidString, $0.name) } ?? ("app", "app"),
                                        args: args, cwd: r.cwd)
        }
    }

    /// `use` / `undo`: the scope's (`--floor`, else the workspace's) active design system set, then applied to each of
    /// the scope's screen files (per file; one's failure leaves the others). A floor without its own (`--none`, or an
    /// undo of its first one) follows the workspace's again, which is then applied to it. Workspace: admin or a
    /// Maestro on the ground; a floor: admin, the Maestro that created it, or a Maestro standing in a user-created one.
    private func activate(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        let reason = try systemReason(r), undo = r.command == "design.system.undo", none = !undo && flag(r, "none")
        let named = try str(r, "floor").map { n throws(ProtocolError) in try findFloor(n) }
        if let me = caller {
            let standing = me.floorId.flatMap { id in ws.floors.first { $0.id == id } }   // a floor since deleted: ground
            if let named, !(me.isMaestro && (named.createdBy == me.id || (named.createdBy == nil && named.id == standing?.id))) {
                throw ProtocolError(code: .notMaestro, message: "only the Maestro that created floor '\(named.name)' can set its design system")
            }
            if named == nil, !me.isMaestro { throw ProtocolError(code: .notMaestro, message: "'\(r.command)' is Maestro-only") }
            if named == nil, standing != nil {
                throw ProtocolError(code: .notMaestro, message: "only the app or a Maestro on the ground can change the workspace design system; use --floor for your floor")
            }
        }
        if none, r.args["name"] != nil { throw ProtocolError(code: .invalidArgs, message: "pass a design system or --none, not both") }
        let deadline = design.deadline(r.command)
        try await lockDesignScopes(deadline); defer { designScopeBusy = false }
        // re-read after the wait: the floor may have changed or gone meanwhile
        var floor: Floor?
        if let named {
            guard let f = ws.floors.first(where: { $0.id == named.id }) else {
                throw ProtocolError(code: .notFound, message: "Floor '\(named.name)' was deleted meanwhile")
            }
            floor = f
        }
        let scope = floor.map { "floor:\($0.name)" } ?? "workspace"
        let effective = floor.map { $0.designSystem ?? ws.designSystem } ?? ws.designSystem
        let wsId = ws.designSystem
        let workspaceSystem = wsId == nil ? nil : try await systems.list().first { $0.id == wsId }
        let own: UUID?, target: DesignSystem?   // the scope's new value, and the system its files get
        if undo {
            if let prev = try await systems.previous(floorId: floor?.id, current: effective) {
                target = prev
                own = floor != nil && prev.id == ws.designSystem ? nil : prev.id   // the workspace's again: follow it
            } else if let floor, floor.designSystem != nil {   // a floor's first one undone: it follows the workspace
                own = nil; target = workspaceSystem
            } else {
                throw ProtocolError(code: .notFound, message: "no earlier design system in \(scope)")
            }
        } else if none {
            own = nil; target = floor == nil ? nil : workspaceSystem
        } else {
            target = try await systems.system(named: try need(r, "name")); own = target?.id
        }
        func set(_ v: UUID?) throws(ProtocolError) {
            guard let floor else { ws.designSystem = v; return }
            guard let i = ws.floors.firstIndex(where: { $0.id == floor.id }) else {
                throw ProtocolError(code: .notFound, message: "Floor '\(floor.name)' was deleted meanwhile")
            }
            ws.floors[i].designSystem = v
        }
        let before = floor.map(\.designSystem) ?? ws.designSystem
        try set(own)
        do { try await persist() } catch { try? set(before); throw error }
        if let floor, let f = ws.floors.first(where: { $0.id == floor.id }) { await hub.emit(.floor(f)) }

        var res: [String: JSONValue] = ["scope": .string(scope), "system": target.map { .string($0.name) } ?? .null]
        if floor != nil && own == nil { res["inherits"] = .bool(true) }
        var files: [FileOutcome] = []
        if let target {   // nothing to apply (the workspace cleared): the files' bindings stay as they are
            let scoped = try await screenFiles().filter { f in
                if let floor { return f.floorId == floor.id }
                return ws.floors.first { $0.id == f.floorId }?.designSystem == nil
            }
            let (out, historyError) = await applyAndLog(target, to: scoped, kind: undo ? "undone" : "activated", scope: scope,
                                                        floorId: floor?.id, by: caller?.name ?? "app", reason: reason, deadline)
            files = out
            if let historyError { res["historyError"] = .string(historyError) }
        }
        res["files"] = try isoJSON(files)
        let what = target.map { "\($0.name) v\($0.version)" } ?? "none"
        let follows = res["inherits"] != nil ? " (following the workspace)" : ""
        let subject = floor.map { "design system ativo (andar \($0.name))" } ?? "design system ativo"
        if let e = await decide(subject: subject, title: "Design system ativo\(floor.map { " (andar \($0.name))" } ?? ""): \(what)\(follows)",
                                body: "Reason: \(reason)\nSystem: \(what)\(follows)" + Self.filesLine(files), by: Self.origin(caller), floor: floor) {
            res["memoryError"] = .string(e)
        }
        await systemChanged(["name": target.map { .string($0.name) } ?? .null, "version": target.map { .number(Double($0.version)) } ?? .null,
                             "kind": .string(target == nil ? "cleared" : undo ? "undone" : "activated"), "scope": .string(scope)])
        return .object(res)
    }

    /// `ds` applied to `files`, then the event in its history; the outcomes and what the history did not keep.
    private func applyAndLog(_ ds: DesignSystem, to files: [DesignService.File], kind: String, scope: String, floorId: UUID?,
                             by: String, reason: String, _ deadline: ContinuousClock.Instant) async -> ([FileOutcome], String?) {
        let out = await systems.apply(ds, to: files, deadline: deadline)
        do {
            try await systems.logActivation(ds, kind: kind, scope: scope, floorId: floorId, by: by, reason: reason, files: out)
            return (out, nil)
        } catch {
            return (out, "the change was not kept in the history: \((error as? ProtocolError)?.message ?? "\(error)")")
        }
    }

    /// One scope change at a time, across the workspace and every floor (a floor follows the workspace).
    func lockDesignScopes(_ deadline: ContinuousClock.Instant) async throws {
        while designScopeBusy {
            guard ContinuousClock.now < deadline else { throw ProtocolError(code: .timeout, message: "design systems are changing; try again") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        designScopeBusy = true
    }

    /// After `floor.delete`: the deleted floor's files are ground now; when it had its own system, the workspace's is
    /// applied to them, and recorded as the workspace's decision (nil: nothing to do).
    func groundFloorFiles(of f: Floor, caller: TerminalRecord?) async -> JSONValue? {
        guard f.designSystem != nil else { return nil }
        let deadline = design.deadline("design.system.use")   // the same budget as a scope change
        do {
            try await lockDesignScopes(deadline); defer { designScopeBusy = false }
            guard let id = ws.designSystem, let ds = try await systems.list().first(where: { $0.id == id }) else { return nil }
            let files = try await screenFiles().filter { $0.floorId == f.id }
            let (out, historyError) = await applyAndLog(ds, to: files, kind: "activated", scope: "workspace", floorId: nil, by: caller?.name ?? "app",
                                                        reason: "floor '\(f.name)' was deleted: its files follow the workspace", deadline)
            await systemChanged(["name": .string(ds.name), "version": .number(Double(ds.version)), "kind": .string("activated"),
                                 "scope": .string("workspace")])
            var o: [String: JSONValue] = ["system": .string(ds.name), "files": try isoJSON(out)]
            if let historyError { o["historyError"] = .string(historyError) }
            if let e = await decide(subject: "design system ativo", title: "Design system ativo: \(ds.name) v\(ds.version)",
                                    body: "Reason: floor '\(f.name)' was deleted: its files follow the workspace\nSystem: \(ds.name) v\(ds.version)"
                                        + Self.filesLine(out), by: Self.origin(caller)) { o["memoryError"] = .string(e) }
            return .object(o)
        } catch {
            return .object(["error": .string((error as? ProtocolError)?.message ?? "\(error)")])
        }
    }

    /// The reason of a `design.system.*` change: kept in history and memory, so no link or key in it.
    private func systemReason(_ r: Request) throws -> String {
        let reason = DesignService.scrub(try need(r, "reason").trimmingCharacters(in: .whitespacesAndNewlines), [])
        guard !reason.isEmpty, reason.count <= 1000 else {
            throw ProtocolError(code: .invalidArgs, message: "the reason must be 1-1000 characters")
        }
        return reason
    }

    private static func filesLine(_ files: [FileOutcome]) -> String {
        files.isEmpty ? "" : "\nFiles: " + files.map { "\($0.file) (\($0.ok ? $0.detail : "failed: \($0.detail)"))" }.joined(separator: ", ")
    }

    /// A decision kept where its scope lives, whoever made it (so a later one supersedes it): a floor's in that floor's
    /// worktree repo, the workspace's and a system's own (publish, revert) in the global store; what was not recorded.
    private func decide(subject: String, title: String, body: String, by: String, floor: Floor? = nil) async -> String? {
        do {
            _ = try await saveDecision(subject: subject, title: title, body: body, cwd: floor?.path, by: by)
            return nil
        } catch {   // the change is made already: say what was not recorded rather than fail
            return "the decision was not recorded: \((error as? ProtocolError)?.message ?? "\(error)")"
        }
    }

    /// A decision's origin: the terminal and its preset, or "app".
    static func origin(_ caller: TerminalRecord?) -> String { caller.map { "\($0.name) (\($0.preset.rawValue))" } ?? "app" }

    /// `designsystem.changed` to every Design panel.
    func systemChanged(_ payload: [String: JSONValue]) async {
        for p in ws.panels where p.pluginId == "design" || p.pluginId == "designsystems" { await pluginEmitted(panel: p.id, name: "designsystem.changed", payload: .object(payload)) }
    }

    /// The design system active on `floor` (its own, else the workspace's; a floor gone: ground).
    func activeSystem(floor: UUID?) -> UUID? {
        ws.floors.first { $0.id == floor }?.designSystem ?? ws.designSystem
    }

    /// Design files that are not design systems.
    func screenFiles() async throws -> [DesignService.File] {
        let sys = try await systems.systemFileIds()
        return try await design.list().filter { !sys.contains($0.id) }
    }

    /// A new screen file in a scope with an active design system: that system's library enabled in it now (under the
    /// scope lock). The reply's fields: `designSystem` (its name) or the warning `designSystemError`; none when no
    /// system is active there.
    func enableActiveSystem(_ f: DesignService.File, _ deadline: ContinuousClock.Instant) async -> [String: JSONValue] {
        guard activeSystem(floor: f.floorId) != nil else { return [:] }
        do { try await lockDesignScopes(deadline) } catch {
            return ["designSystemError": .string("design systems are changing; library not enabled — run design.system.use again or retry")]
        }
        defer { designScopeBusy = false }
        guard let id = activeSystem(floor: f.floorId) else { return [:] }   // re-read: cleared meanwhile
        do {
            guard let ds = try await systems.list().first(where: { $0.id == id }) else { return [:] }
            let o = await systems.apply(ds, to: [f], deadline: deadline).first
            guard let o, o.ok else {
                return ["designSystemError": .string("\(ds.name): library not enabled (\(o?.detail ?? "no answer")) — run design.system.use again or retry")]
            }
            return ["designSystem": .string(ds.name)]
        } catch {
            return ["designSystemError": .string("library not enabled: \((error as? ProtocolError)?.message ?? "\(error)")")]
        }
    }

    /// The files open design panels show.
    var openDesignFiles: Set<String> {
        Set(ws.panels.compactMap { p in if p.pluginId == "design", case .string(let f)? = p.state["file"] { f } else { nil } })
    }
}
