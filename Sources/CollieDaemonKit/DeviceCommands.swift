import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// A `device.*` command, run by the daemon. Leashes are the only permission: a canvas panel needs one, a docked one
    /// is open to all. `device.list` has no panel and answers any authenticated caller: Android devices, then simulators
    /// (adb or simctl failing hides only its own part; both failing and no AVD that is off: adb's error).
    func deviceCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        if r.command == "device.list" {
            let visible = caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels
            func names(_ serial: String) -> JSONValue {
                .array(visible.filter { $0.pluginId == "device" && $0.state["serial"] == .string(serial) }.map(\.name).sorted().map { .string($0) })
            }
            var adbError: ProtocolError?, rows: [JSONValue] = []
            async let adbR = DeviceService.attempt { () async throws(ProtocolError) in try await self.devices.devices() }   // concurrent: a cold CoreSimulator must not slow adb
            async let avdR = self.devices.avds()
            async let simR = DeviceService.attempt { () async throws(ProtocolError) in try await self.devices.simulators() }
            switch await adbR {
            case .success(let list):
                rows = list.map { dev in
                    .object(["serial": .string(dev.serial), "state": .string(dev.state),
                             "model": dev.model.map { .string($0) } ?? .null, "product": dev.product.map { .string($0) } ?? .null,
                             "platform": .string("android"), "panels": names(dev.serial)])
                }
            case .failure(let e): adbError = e
            }
            let off = await avdR.filter { $0.serial == nil }
            rows += off.map { a in
                .object(["serial": .string("avd:\(a.name)"), "state": .string("off"), "model": .string(a.name.replacingOccurrences(of: "_", with: " ")),
                         "product": .null, "platform": .string("android"), "panels": .array([])])
            }
            guard case .success(let sims) = await simR else { if let adbError, off.isEmpty { throw adbError }; return .array(rows) }
            return .array(rows + sims.map { s in
                .object(["serial": .string(s.udid), "state": .string(s.state), "model": .string(s.name), "product": .string(s.runtime),
                         "platform": .string("ios"), "panels": names(s.udid)])
            })
        }
        if r.command == "device.lite.create" || r.command == "device.lite.remove" {
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "\(r.command) is admin only") }
            if r.command == "device.lite.remove" { try await devices.removeLiteAvd(); return .object([:]) }
            return .object(try await devices.createLiteAvd().mapValues { .string($0) })
        }
        if r.command == "device.helper" {
            let action = str(r, "action") ?? "status"
            guard action == "status" || caller == nil else { throw ProtocolError(code: .unauthorized, message: "device helper \(action) is admin only") }
            return try await devices.helperCommand(action, serial: str(r, "serial"))
        }
        let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "device", from: caller?.id, in: ws)
        var args = r.args; args["panel"] = nil
        // d5: an agent's action goes to its paddock's flow log (the panel's when the agent is on the pasture); the user's
        // own CLI calls are neither agent nor panel and are not recorded
        let flow = caller.flatMap { me in flowLog(me.paddockId ?? panel.paddockId).map { FlowRecorder(origin: "agent:\(me.name)", log: $0) } }
        return try await devices.run(r.command, panel: panel, args: args, cwd: r.cwd, flow: flow)
    }

    /// `device.run --plan <file>` (d6): the plan file read as `--body-file` (a terminal: inside its project, regular,
    /// one link; at most `FlowPlan.maxBytes`), checked whole, then run by `FlowRunner` through `devices.run`, so each
    /// step obeys the same reach and lands in the flow log as the agent's own call would. `--serial` without `--panel`:
    /// the reachable device panel showing that serial.
    func deviceRunCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        // d7: confirming a destructive step is the user's alone (principal: admin token, not from inside a terminal)
        let confirmed = flag(r, "confirm-destructive")
        if confirmed, caller != nil {
            throw ProtocolError(code: .unauthorized, message: "--confirm-destructive is the user's: an agent's plan stops at a destructive step")
        }
        let data = try await ruleBodyFile(try need(r, "plan"), r, caller: caller, flag: "--plan", limit: FlowPlan.maxBytes)
        let plan = try FlowPlan.parse(data)
        let target: Panel
        if let serial = str(r, "serial"), str(r, "panel") == nil {
            let reach = caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels
            guard let p = reach.first(where: { $0.pluginId == "device" && $0.state["serial"] == .string(serial) }) else {
                throw ProtocolError(code: .notFound, message: "No device panel showing \(serial) reachable. Open one with `panel open device`.")
            }
            target = p
        } else {
            target = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "device", from: caller?.id, in: ws)
        }
        let flow = caller.flatMap { me in flowLog(me.paddockId ?? target.paddockId).map { FlowRecorder(origin: "agent:\(me.name)", log: $0) } }
        let devices = devices, cwd = r.cwd
        var runner = FlowRunner(confirmed: confirmed, resolve: { s async throws(ProtocolError) in
            try await devices.flowDestructive(s, panel: target, cwd: cwd)
        }) { c, a async throws(ProtocolError) in
            try await devices.run(c, panel: target, args: a, cwd: cwd, flow: flow)
        }
        if let gone = ClientHangup.current { runner.hungUp = { gone.isSet } }   // c2: the socket's hangup, read between steps
        return try await runner.run(plan)
    }

    /// The flow log of paddock `id` (d5); nil without one. On or off is read when writing.
    func flowLog(_ id: UUID?) -> FlowActionLog? {
        guard let id, let p = ws.paddocks.first(where: { $0.id == id }) else { return nil }
        return FlowActionLog(paddock: URL(fileURLWithPath: p.path), flag: flowFlag(p.id))
    }

    /// The opt-in of paddock `id` (b2): `<daemon root>/flows/<id>/enabled`, out of the worktree an agent writes to.
    func flowFlag(_ id: UUID) -> URL {
        config.paths.root.appendingPathComponent("flows").appendingPathComponent(id.uuidString).appendingPathComponent("enabled")
    }

    /// `device.flow on|off|status` (d4): a terminal acts on its own paddock, the user names one with --paddock. Only the
    /// user turns the log on (opt-in); off and status are open to the paddock's terminals.
    func deviceFlowCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        let action = str(r, "action") ?? "status"
        guard ["on", "off", "status"].contains(action) else {
            throw ProtocolError(code: .invalidArgs, message: "device flow \(action): use on, off or status")
        }
        let paddock: Paddock
        if let me = caller {
            guard action != "on" else { throw ProtocolError(code: .unauthorized, message: "only the user turns the action log on (collie device flow on --paddock <name>, outside a terminal)") }
            guard r.args["paddock"] == nil else { throw ProtocolError(code: .unauthorized, message: "--paddock is the user's: a terminal acts on its own paddock") }
            guard let pid = me.paddockId, let p = ws.paddocks.first(where: { $0.id == pid }) else {
                throw ProtocolError(code: .invalidArgs, message: "the action log lives in a paddock; '\(me.name)' is on the pasture")
            }
            paddock = p
        } else {
            paddock = try findPaddock(try need(r, "paddock"))
        }
        let log = FlowActionLog(paddock: URL(fileURLWithPath: paddock.path), flag: flowFlag(paddock.id))
        if action != "status" { try log.setEnabled(action == "on") }
        guard case .object(var o) = log.status(paddock: paddock.name) else { return log.status() }
        o["paddock"] = .string(paddock.name)
        return .object(o)
    }

    /// Hands the device panels to the watchers: after a device panel opens or closes, and once at daemon start.
    func watchDevices() async { await devices.watch(panels: ws.panels) }
}
