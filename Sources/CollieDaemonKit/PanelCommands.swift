import Foundation
import CollieCore
import CollieProtocol

/// One plugin event kept in a panel's ring.
struct PanelEvent: Sendable { let seq: Int; let name: String; let payload: JSONValue }
let panelEventCap = 200

/// `panel.*` and `events`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Terminals see only reachable panels (canvas: corded; dock: everyone). Only a Maestro opens panels; it closes
/// the ones it created or is corded to, and moves only its own.
extension CommandRouter {
    func panelCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        func refuse(_ m: String) -> ProtocolError { ProtocolError(code: .notMaestro, message: m) }
        func maestroOnly() throws(ProtocolError) {
            if let me = caller, !me.isMaestro { throw refuse("'\(r.command)' is Maestro-only") }
        }
        let visible = caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels

        switch r.command {
        case "panel.list":
            return try isoJSON(visible)
        case "panel.open":
            try maestroOnly()
            let pluginId = try need(r, "plugin")
            guard let spec = PluginRegistry.spec(pluginId) else {
                throw ProtocolError(code: .notFound, message: "Plugin '\(pluginId)' not found")
            }
            let placement = try placementArg(r, spec)
            guard let storage = StorageScope(rawValue: str(r, "storage") ?? "isolated") else {
                throw ProtocolError(code: .invalidArgs, message: "storage must be isolated|workspace|global")
            }
            let device = pluginId == "device" ? try await devices.resolveSerial(str(r, "serial")) : nil
            var name = str(r, "name") ?? ""
            if r.args["name"] == nil {   // default: <plugin>-<lowest free n>
                func taken(_ n: String) -> Bool {
                    launching.contains(n.lowercased()) || panel(named: n) != nil
                        || ws.terminals.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame }
                }
                var i = 1
                while taken("\(pluginId)-\(i)") { i += 1 }
                name = "\(pluginId)-\(i)"
            }
            guard !name.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'name'") }
            if let t = try lookup(name) { throw ProtocolError(code: .invalidArgs, message: "'\(name)' is the name of terminal '\(t.name)'") }
            try reserve(name); defer { launching.remove(name.lowercased()) }   // also refuses an existing panel name
            var state: [String: JSONValue] = ["storage": .string(storage.rawValue)]
            if let u = str(r, "url") { state["url"] = .string(u) }
            if let device { state["serial"] = .string(device.serial); state["platform"] = .string(device.platform) }
            let (p, designWarning, _) = try await openPanel(name: name, pluginId: pluginId, placement: placement, state: state,
                                                         file: pluginId == "design" ? try need(r, "file") : nil,
                                                         floor: placement == .canvas || pluginId == "design"
                                                             ? try canvasFloor(str(r, "floor"), caller: caller) : nil, caller: caller)
            guard !designWarning.isEmpty, case .object(var o) = try isoJSON(p) else { return try isoJSON(p) }
            o.merge(designWarning) { _, b in b }   // the panel is open; its file just lacks the library
            return .object(o)
        case "panel.close":
            try maestroOnly()
            let p = try findPanel(try need(r, "name"))
            if let me = caller, p.createdBy != me.id, !ws.connections.contains(where: { Set([$0.a, $0.b]) == Set([me.id, p.id]) }) {
                throw refuse("only the Maestro that opened panel '\(p.name)' or one corded to it can close it")
            }
            try await remove(p)
            return .object([:])
        case "panel.move":
            try maestroOnly()
            let p = try findPanel(try need(r, "name"))
            if let me = caller, p.createdBy != me.id { throw refuse("only the Maestro that opened panel '\(p.name)' can move it") }
            guard let spec = PluginRegistry.spec(p.pluginId) else {
                throw ProtocolError(code: .unavailable, message: "Plugin '\(p.pluginId)' is not available")
            }
            let placement = try placementArg(r, spec)
            guard let i = ws.panels.firstIndex(where: { $0.id == p.id }) else { return .object([:]) }
            let canvas = placement == .canvas, before = ws.panels[i]
            ws.panels[i].placement = placement
            ws.panels[i].floorId = canvas ? (try canvasFloor(str(r, "floor"), caller: caller) ?? p.floorId) : nil
            // docked: reachable by everyone, its cords go; onto the canvas: the moving Maestro keeps it in reach
            let gone = canvas ? [] : ws.connections.filter { $0.a == p.id || $0.b == p.id }
            if !canvas { ws.connections.removeAll { $0.a == p.id || $0.b == p.id } }
            var added: Connection?
            if canvas, let me = caller, !ws.connections.contains(where: { Set([$0.a, $0.b]) == Set([me.id, p.id]) }) {
                added = Connection(a: me.id, b: p.id); ws.connections.append(added!)
            }
            do { try await persist() } catch {   // put back what this move changed (re-read: other commands ran meanwhile)
                if let j = ws.panels.firstIndex(where: { $0.id == p.id }) {
                    ws.panels[j].placement = before.placement; ws.panels[j].floorId = before.floorId
                    let live = Set(ws.terminals.map(\.id))
                    ws.connections += gone.filter { c in live.contains(c.a == p.id ? c.b : c.a) && !ws.connections.contains(c) }
                }
                if let added { ws.connections.removeAll { $0 == added } }
                throw error
            }
            for c in gone { await hub.emit(.disconnected(c)) }
            let moved = try ensurePanel(p)
            await hub.emit(.panel(moved))
            if let added, ws.connections.contains(added) { await hub.emit(.connected(added)) }
            return try isoJSON(moved)
        case "events":
            let since: Int
            switch r.args["since"] {
            case nil, .null?: since = 0
            case .number(let n)?: since = Int(exactly: n) ?? -1
            case .string(let s)?: since = Int(s) ?? -1
            default: since = -1
            }
            guard since >= 0 else { throw ProtocolError(code: .invalidArgs, message: "'since' must be a sequence number >= 0") }
            var panels = visible
            if let n = str(r, "panel") {
                let p = try findPanel(n)
                guard visible.contains(where: { $0.id == p.id }) else {
                    throw ProtocolError(code: .notConnected, message: "No connection to panel '\(p.name)'. Connect it first.")
                }
                panels = [p]
            }
            let rows = panels.flatMap { p in
                (panelEvents[p.id] ?? []).filter { $0.seq > since }.map { (p.name, $0) }
            }.sorted { $0.1.seq < $1.1.seq }
            return .object(["seq": .number(Double(eventSeq)), "events": .array(rows.map { name, e in
                .object(["seq": .number(Double(e.seq)), "panel": .string(name), "name": .string(e.name), "payload": e.payload])
            })])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// `panel.open` once `name` is reserved: the design file (`file`, created on `floor` when new), the record (on `floor`
    /// when on the canvas), the opening Maestro's cord, persist, events. Returns the panel, any `designSystemError`, and
    /// whether the design file was created by this call.
    func openPanel(name: String, pluginId: String, placement: PanelPlacement, state: [String: JSONValue], file: String?,
                   floor: UUID?, caller: TerminalRecord?) async throws -> (Panel, [String: JSONValue], fileCreated: Bool) {
        var state = state, designWarning: [String: JSONValue] = [:], fileCreated = false
        if let file {   // a new name: created on the panel's floor, with the active design system's library
            let deadline = design.deadline("panel.open")
            let (id, created) = try await design.fileId(named: file, floor: floor, deadline: deadline)
            fileCreated = created
            if created, let f = try await design.list().first(where: { $0.id == id }) {
                designWarning = await enableActiveSystem(f, deadline).filter { $0.key == "designSystemError" }
            }
            state["file"] = .string(id)
        }
        let canvas = placement == .canvas
        let p = Panel(id: UUID(), name: name, pluginId: pluginId, placement: placement,
                      floorId: canvas ? floor : nil, state: state, createdBy: caller?.id)
        ws.panels.append(p)
        // the opening Maestro reaches its canvas panel through a cord; a docked one needs none
        let cord = caller.flatMap { me in canvas ? Connection(a: me.id, b: p.id) : nil }
        if let cord { ws.connections.append(cord) }
        do { try await persist() } catch {
            ws.panels.removeAll { $0.id == p.id }
            ws.connections.removeAll { $0.a == p.id || $0.b == p.id }
            throw error
        }
        try ensurePanel(p)   // closed (or its Maestro killed) during the persist: emit nothing stale
        if pluginId == "device" { await watchDevices() }
        await hub.emit(.panel(p))
        if let cord, ws.connections.contains(cord) { await hub.emit(.connected(cord)) }
        return (p, designWarning, fileCreated)
    }

    /// Appends a plugin event to `panel`'s ring (oldest dropped past `panelEventCap`). Unknown panels are ignored.
    func record(panel: UUID, name: String, payload: JSONValue) {
        guard ws.panels.contains(where: { $0.id == panel }) else { return }
        eventSeq += 1
        var ring = panelEvents[panel] ?? []
        ring.append(PanelEvent(seq: eventSeq, name: name, payload: payload))
        if ring.count > panelEventCap { ring.removeFirst(ring.count - panelEventCap) }
        panelEvents[panel] = ring
    }

    func panel(named name: String) -> Panel? {
        ws.panels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    /// After an await: `p`'s current record, unless it was closed meanwhile.
    @discardableResult private func ensurePanel(_ p: Panel) throws(ProtocolError) -> Panel {
        guard let cur = ws.panels.first(where: { $0.id == p.id }) else {
            throw ProtocolError(code: .notFound, message: "Panel '\(p.name)' was closed meanwhile")
        }
        return cur
    }
    func findPanel(_ name: String) throws(ProtocolError) -> Panel {
        guard let p = panel(named: name) else { throw ProtocolError(code: .notFound, message: "Panel '\(name)' not found") }
        return p
    }

    /// `a`/`b` naming one terminal and one panel (either order): that pair. nil when neither names a panel.
    func panelPair(_ r: Request, terminal: (String) throws -> TerminalRecord,
                   panel: (String) throws -> Panel) throws -> (TerminalRecord, Panel)? {
        let a = try need(r, "a"), b = try need(r, "b")
        switch (self.panel(named: a) != nil, self.panel(named: b) != nil) {
        case (false, false): return nil
        case (true, true): throw ProtocolError(code: .invalidArgs, message: "cannot connect a panel to a panel")
        case (true, false): return (try terminal(b), try panel(a))
        case (false, true): return (try terminal(a), try panel(b))
        }
    }

    /// Cords terminal `t` to canvas panel `p` (idempotent).
    func cord(_ t: TerminalRecord, _ p: Panel) async throws {
        guard p.placement == .canvas else { throw ProtocolError(code: .invalidArgs, message: "dock panels need no cord") }
        try await link(t.id, p.id)
    }
    func uncord(_ t: TerminalRecord, _ p: Panel) async throws { try await unlink(t.id, p.id) }

    /// Closes `p`: drops its cords and events, persists, emits `.disconnected` per cord, then `.panelRemoved`.
    func remove(_ p: Panel) async throws {
        ws.panels.removeAll { $0.id == p.id }
        panelEvents[p.id] = nil
        await devices.panelClosed(p.id)
        await design.panelClosed(p.id, openFiles: openDesignFiles)
        if p.pluginId == "device" { await watchDevices() }
        let gone = ws.connections.filter { $0.a == p.id || $0.b == p.id }
        ws.connections.removeAll { $0.a == p.id || $0.b == p.id }
        try await persist()
        for c in gone { await hub.emit(.disconnected(c)) }
        await hub.emit(.panelRemoved(p.id))
    }

    /// A canvas panel's floor: the Maestro's own (ground if that floor is gone or being deleted); for the admin (the
    /// app), the optional `floor` argument (ground when absent).
    func canvasFloor(_ floorName: String?, caller: TerminalRecord?) throws(ProtocolError) -> UUID? {
        if let caller {
            guard let fid = caller.floorId, !floorDeleting.contains(fid), ws.floors.contains(where: { $0.id == fid }) else { return nil }
            return fid
        }
        guard let floorName else { return nil }
        return try findFloor(floorName).id
    }

    private func placementArg(_ r: Request, _ spec: PluginSpec) throws(ProtocolError) -> PanelPlacement {
        guard let s = str(r, "placement") else { return spec.defaultPlacement }
        guard let pl = PanelPlacement(rawValue: s), spec.placements.contains(pl) else {
            throw ProtocolError(code: .invalidArgs, message: "placement must be one of "
                                + spec.placements.map(\.rawValue).joined(separator: "|"))
        }
        return pl
    }
}
