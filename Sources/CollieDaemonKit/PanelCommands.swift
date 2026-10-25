import Foundation
import CollieCore
import CollieProtocol

/// One plugin event kept in a panel's ring.
struct PanelEvent: Sendable { let seq: Int; let name: String; let payload: JSONValue }
let panelEventCap = 200

/// `panel.*` and `events`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Terminals see only reachable panels (canvas: leashed; dock: everyone; headless: its creator; `panel.list` also lists it
/// to the creator's leashed Shepherd, which can't reach it). A Shepherd opens any panel, closes the ones it created or is leashed to, and moves only its own. Any other
/// terminal opens only browsers (headless unless `--visible`, leashed to it, at most `testerBrowserCap`) and Prévias (canvas,
/// leashed, at most as many, counted apart) and closes and moves only its own.
extension CommandRouter {
    func panelCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        func refuse(_ m: String) -> ProtocolError { ProtocolError(code: .notShepherd, message: m) }
        let visible = caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels

        let tester = caller.map { !$0.isShepherd } ?? false

        switch r.command {
        case "panel.list":
            return try isoJSON(visible + (caller.map { ConnectionGraph.listedHeadless(from: $0.id, in: ws) } ?? []))
        case "panel.open":
            let pluginId = try need(r, "plugin")
            if tester, pluginId != "browser", pluginId != "preview" { throw refuse("a terminal that isn't a Shepherd opens only browser and preview panels") }
            guard let spec = PluginRegistry.spec(pluginId) else {
                throw ProtocolError(code: .notFound, message: "Plugin '\(pluginId)' not found")
            }
            var placement = flag(r, "visible") ? PanelPlacement.canvas : try placementArg(r, spec)
            if tester, pluginId == "preview" {
                guard placement == .canvas else { throw refuse("a terminal that isn't a Shepherd opens Prévias on the canvas") }
            } else if tester {
                if r.args["placement"] == nil, !flag(r, "visible") { placement = .headless }
                guard placement == .canvas || placement == .headless else { throw refuse("a terminal that isn't a Shepherd opens browsers headless or --visible on the canvas") }
            }
            // --connect: a Shepherd wires its new canvas panel to terminals it reaches, checked before it opens
            var wirer: TerminalRecord?
            if r.args["connect"] != nil {
                guard let me = caller, me.isShepherd else { throw refuse("--connect is Shepherd-only") }
                guard placement == .canvas else { throw ProtocolError(code: .invalidArgs, message: "--connect needs a canvas panel (dock panels need no leash)") }
                _ = try connectTargets(r, by: me, panels: false); wirer = me
            }
            if placement == .headless, caller == nil {   // nothing would ever close it
                throw ProtocolError(code: .invalidArgs, message: "placement headless is for terminals")
            }
            // a request still in flight from an exited terminal would leave a panel nothing closes; no await after this
            // until the panel is appended (cap, name), except the device/design lookups
            if let me = caller, await registry.process(me.id)?.isRunning != true {
                throw ProtocolError(code: .notRunning, message: "terminal '\(me.name)' is not running")
            }
            let slot = tester && pluginId == "preview" ? try caller.map { me throws(ProtocolError) in try reservePreview(me) } : nil
            defer { if let me = caller, let slot { releasePreview(me, slot) } }
            if tester, let me = caller, pluginId == "browser", ws.panels.count(where: { $0.createdBy == me.id && $0.pluginId == pluginId }) >= Self.testerBrowserCap {
                throw ProtocolError(code: .tooMany, message: "at most \(Self.testerBrowserCap) open browsers per terminal; close one with `panel close`")
            }
            guard let storage = StorageScope(rawValue: str(r, "storage") ?? "isolated") else {
                throw ProtocolError(code: .invalidArgs, message: "storage must be isolated|workspace|global")
            }
            let device = pluginId == "device" ? try await devices.resolveSerial(str(r, "serial")) : nil
            var name = str(r, "name") ?? ""
            if r.args["name"] == nil { name = freePanelName(pluginId) }
            guard !name.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'name'") }
            if let t = try lookup(name) { throw ProtocolError(code: .invalidArgs, message: "'\(name)' is the name of terminal '\(t.name)'") }
            try reserve(name); defer { launching.remove(name.lowercased()) }   // also refuses an existing panel name
            var state: [String: JSONValue] = ["storage": .string(storage.rawValue)]
            if let u = str(r, "url") { state["url"] = .string(u) }
            if pluginId == "diagram" || pluginId == "preview", let f = str(r, "file") { state["file"] = .string(f) }
            if pluginId == "preview", let a = str(r, "artifact") { state["artifact"] = .string(a) }
            if let device { state["serial"] = .string(device.serial); state["platform"] = .string(device.platform) }
            let (p, designWarning, _) = try await openPanel(name: name, pluginId: pluginId, placement: placement, state: state,
                                                         file: pluginId == "design" ? try need(r, "file") : nil,
                                                         paddock: placement == .canvas || pluginId == "design"
                                                             ? try canvasPaddock(str(r, "paddock"), caller: caller) : nil, caller: caller,
                                                         reservation: slot)
            do {   // re-checked after openPanel's awaits; all or nothing
                for t in try wirer.map({ try connectTargets(r, by: $0, panels: false).terminals }) ?? [] { try await leash(t, p) }
            } catch { try? await remove(p); throw error }
            guard !designWarning.isEmpty, case .object(var o) = try isoJSON(p) else { return try isoJSON(p) }
            o.merge(designWarning) { _, b in b }   // the panel is open; its file just lacks the library
            return .object(o)
        case "panel.close":
            let p = try findPanel(try need(r, "name"))
            if tester, p.createdBy != caller?.id { throw refuse("a terminal that isn't a Shepherd closes only the panels it opened") }
            if let me = caller, p.createdBy != me.id, !ws.connections.contains(where: { Set([$0.a, $0.b]) == Set([me.id, p.id]) }) {
                throw refuse("only the Shepherd that opened panel '\(p.name)' or one leashed to it can close it")
            }
            try await remove(p)
            return .object([:])
        case "panel.move":
            let p = try findPanel(try need(r, "name"))
            if let me = caller, p.createdBy != me.id {
                throw refuse(tester ? "a terminal that isn't a Shepherd moves only the panels it opened" : "only the Shepherd that opened panel '\(p.name)' can move it")
            }
            guard let spec = PluginRegistry.spec(p.pluginId) else {
                throw ProtocolError(code: .unavailable, message: "Plugin '\(p.pluginId)' is not available")
            }
            let placement = try placementArg(r, spec)
            if placement == .canvas, let me = caller { try refuseFreeLeash(me.id) }   // before anything changes
            // ponytail: headless stays headless (its lifecycle is its creator's); add a move out when someone asks for it
            if placement == .headless || p.placement == .headless {
                throw ProtocolError(code: .invalidArgs, message: "a headless panel can't be moved; close it and open another")
            }
            if tester, placement != .canvas { throw refuse("a terminal that isn't a Shepherd keeps its browsers on the canvas") }
            guard let i = ws.panels.firstIndex(where: { $0.id == p.id }) else { return .object([:]) }
            let canvas = placement == .canvas, before = ws.panels[i]
            ws.panels[i].placement = placement
            ws.panels[i].paddockId = canvas ? (try canvasPaddock(str(r, "paddock"), caller: caller) ?? p.paddockId) : nil
            // docked: reachable by everyone, its leashes go; onto the canvas: the moving Shepherd keeps it in reach
            let gone = canvas ? [] : ws.connections.filter { $0.a == p.id || $0.b == p.id }
            if !canvas { ws.connections.removeAll { $0.a == p.id || $0.b == p.id } }
            var added: Connection?
            if canvas, let me = caller, !ws.connections.contains(where: { Set([$0.a, $0.b]) == Set([me.id, p.id]) }) {
                added = Connection(a: me.id, b: p.id); ws.connections.append(added!)
            }
            do { try await persist() } catch {   // put back what this move changed (re-read: other commands ran meanwhile)
                if let j = ws.panels.firstIndex(where: { $0.id == p.id }) {
                    ws.panels[j].placement = before.placement; ws.panels[j].paddockId = before.paddockId
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

    /// `panel.open` once `name` is reserved: the design file (`file`, created on `paddock` when new), the record (on `paddock`
    /// when on the canvas), the opening Shepherd's leash, persist, events. Returns the panel, any `designSystemError`, and
    /// whether the design file was created by this call.
    func openPanel(name: String, pluginId: String, placement: PanelPlacement, state: [String: JSONValue], file: String?,
                   paddock: UUID?, caller: TerminalRecord?, reservation: UUID? = nil) async throws -> (Panel, [String: JSONValue], fileCreated: Bool) {
        if let me = caller, placement == .canvas || placement == .headless { try refuseFreeLeash(me.id) }   // before any side effect
        var state = state, designWarning: [String: JSONValue] = [:], fileCreated = false
        if let file {   // a new name: created on the panel's paddock, with the active design system's library
            let deadline = design.deadline("panel.open")
            let (id, created) = try await design.fileId(named: file, paddock: paddock, deadline: deadline)
            fileCreated = created
            if created, let f = try await design.list().first(where: { $0.id == id }) {
                designWarning = await enableActiveSystem(f, deadline).filter { $0.key == "designSystemError" }
            }
            state["file"] = .string(id)
        }
        if pluginId == "diagram" {   // an agent's path is a trust boundary: the app must never be pointed outside the project
            let root = try await projectRootForPanel(paddock: paddock, caller: caller)
            let requested: String? = if case .string(let f)? = state["file"] { f } else { nil }
            _ = try DiagramFile.resolve(requested, panelName: name, projectRoot: root)
            state["root"] = .string(root.path)
        }
        if pluginId == "preview" {   // a page of the project (checked as the diagram's file), or an artifact that exists
            switch (state["file"], state["artifact"]) {
            case (.string(let f)?, nil):
                let root = try await projectRootForPanel(paddock: paddock, caller: caller)
                _ = try PreviewFile.resolve(f, projectRoot: root)
                state["root"] = .string(root.path)
            case (nil, .string(let a)?):
                guard let id = UUID(uuidString: a) else { throw ProtocolError(code: .invalidArgs, message: "'artifact' must be an artifact id") }
                _ = try await artifacts.get(id)
                state["artifact"] = .string(id.uuidString.lowercased())
                if let root = try? await projectRootForPanel(paddock: paddock, caller: caller) { state["root"] = .string(root.path) }
            default:
                throw ProtocolError(code: .invalidArgs, message: "Prévia: give --file <page.html> or --artifact <id>")
            }
        }
        let canvas = placement == .canvas
        let p = Panel(id: UUID(), name: name, pluginId: pluginId, placement: placement,
                      paddockId: canvas ? paddock : nil, state: state, createdBy: caller?.id)
        ws.panels.append(p)
        if let me = caller, let reservation { releasePreview(me, reservation) }   // now counted as open: never twice
        // the opening terminal is leashed to its canvas or headless panel; a docked one needs none
        let leash = caller.flatMap { me in canvas || placement == .headless ? Connection(a: me.id, b: p.id) : nil }
        if let leash { ws.connections.append(leash) }
        do { try await persist() } catch {
            ws.panels.removeAll { $0.id == p.id }
            ws.connections.removeAll { $0.a == p.id || $0.b == p.id }
            throw error
        }
        try ensurePanel(p)   // closed (or its Shepherd killed) during the persist: emit nothing stale
        if pluginId == "device" { await watchDevices() }
        await hub.emit(.panel(p))
        if let leash, ws.connections.contains(leash) { await hub.emit(.connected(leash)) }
        return (p, designWarning, fileCreated)
    }

    /// The project a Diagram or Prévia panel's file lives in (the app resolves and checks the file in it): the opening
    /// terminal's project; for the app, the paddock's worktree, else the project of a terminal on the pasture.
    /// ponytail: the app on the pasture takes its first terminal's project; add a folder picker when pastures mix projects.
    func projectRootForPanel(paddock: UUID?, caller: TerminalRecord?) async throws -> URL {
        if let me = caller { return try await projectRoot(of: me) }
        if let f = ws.paddocks.first(where: { $0.id == paddock }) { return URL(fileURLWithPath: f.path) }
        guard let t = ws.terminals.first(where: { $0.paddockId == nil }) else {
            throw ProtocolError(code: .invalidArgs, message: "abra antes um terminal no projeto (o arquivo do painel fica nele)")
        }
        return try await projectRoot(of: t)
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

    /// `<plugin>-<lowest free n>`: no panel, terminal or name being launched has it.
    func freePanelName(_ pluginId: String) -> String {
        func taken(_ n: String) -> Bool {
            launching.contains(n.lowercased()) || panel(named: n) != nil
                || ws.terminals.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
        var i = 1
        while taken("\(pluginId)-\(i)") { i += 1 }
        return "\(pluginId)-\(i)"
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

    /// Leashes terminal `t` to canvas panel `p` (idempotent).
    func leash(_ t: TerminalRecord, _ p: Panel) async throws {
        if p.placement == .headless { throw ProtocolError(code: .invalidArgs, message: "a headless panel is reachable only by the terminal that opened it") }
        guard p.placement == .canvas else { throw ProtocolError(code: .invalidArgs, message: "dock panels need no leash") }
        try await link(t.id, p.id)
    }
    func unleash(_ t: TerminalRecord, _ p: Panel) async throws { try await unlink(t.id, p.id) }

    /// A non-Shepherd's Prévia about to open: refused past the cap, counting those still opening; returns the slot,
    /// released by `openPanel` once the panel is registered (or by the caller on failure; releasing twice is a no-op).
    func reservePreview(_ me: TerminalRecord) throws(ProtocolError) -> UUID {
        let open = ws.panels.count(where: { $0.createdBy == me.id && $0.pluginId == "preview" })
        guard open + previewsOpening[me.id, default: []].count < Self.testerBrowserCap else {
            throw ProtocolError(code: .tooMany, message: "at most \(Self.testerBrowserCap) open Prévias per terminal; close one with `panel close`")
        }
        let slot = UUID()
        previewsOpening[me.id, default: []].insert(slot)
        return slot
    }
    func releasePreview(_ me: TerminalRecord, _ slot: UUID) {
        previewsOpening[me.id]?.remove(slot)
        if previewsOpening[me.id]?.isEmpty == true { previewsOpening[me.id] = nil }
    }

    /// Max open browser panels per non-Shepherd terminal.
    static let testerBrowserCap = 8

    /// `terminal` was removed or its process exited: its headless panels close (`.panelRemoved` lets the app drop their
    /// screenshots and data, as for any close).
    func closeHeadless(of terminal: UUID) async {
        for p in ws.panels where p.placement == .headless && p.createdBy == terminal {
            try? await remove(p)   // a failed persist: the record is gone in memory anyway (and dropped at the next start)
        }
    }

    /// `<root>/screens/<panel id>-*`: the panel's screenshots. The app deletes them too on `.panelRemoved`; the daemon
    /// does it as well so a panel closed while the app isn't running leaves none behind.
    nonisolated static func removeScreenshots(of id: UUID, root: URL) {
        let dir = root.appendingPathComponent("screens", isDirectory: true), prefix = id.uuidString + "-"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Closes `p`: drops its leashes, events and screenshots, persists, emits `.disconnected` per leash, then `.panelRemoved`.
    func remove(_ p: Panel) async throws {
        ws.panels.removeAll { $0.id == p.id }
        Self.removeScreenshots(of: p.id, root: config.paths.root)
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

    /// A canvas panel's paddock: the Shepherd's own (pasture if that paddock is gone or being deleted); for the admin (the
    /// app), the optional `paddock` argument (pasture when absent).
    func canvasPaddock(_ paddockName: String?, caller: TerminalRecord?) throws(ProtocolError) -> UUID? {
        if let caller {
            guard let fid = caller.paddockId, !paddockDeleting.contains(fid), ws.paddocks.contains(where: { $0.id == fid }) else { return nil }
            return fid
        }
        guard let paddockName else { return nil }
        return try findPaddock(paddockName).id
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
