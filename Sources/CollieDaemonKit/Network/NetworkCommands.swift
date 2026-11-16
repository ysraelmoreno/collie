import Foundation
import CollieCore
import CollieProtocol
import CollieNetwork

extension CommandRouter {
    /// A `network.*` command, run by the daemon. The leash is the permission, as for `device.*`: a terminal must reach a
    /// network panel (captured traffic carries tokens and cookies); the app (admin) needs none. The commands are
    /// panel-free otherwise (panels are not bound to a serial): `--serial`, else the only emulator online (attach) or the
    /// only one being captured (the rest).
    func networkCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        if let me = caller, !ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.pluginId == "network" }) {
            throw ProtocolError(code: .notFound, message: "No network panel reachable. Open one with `panel open network`.")
        }
        if r.command.hasPrefix("network.rule-") { return try await networkRuleCommand(r, caller: caller) }
        if r.command == "network.status", str(r, "serial") == nil, await network.attached.isEmpty {
            return .object(["attached": .bool(false)])
        }
        let serial = try await networkSerial(r)
        switch r.command {
        case "network.attach": return try await network.attach(serial)
        case "network.detach": return try await network.detach(serial)
        case "network.status": return await network.status(serial)
        case "network.list":
            return try await network.list(serial, limit: try DeviceService.int(r.args, "limit", 1...10_000) ?? 100, host: str(r, "host"))
        case "network.get": return try await network.get(serial, id: try flowId(r))
        case "network.curl": return try await network.curl(serial, id: try flowId(r))
        case "network.clear": return try await network.clear(serial)
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// `network.rule-*`: the map rules, global (no serial, except `rule-add --from`, whose flow is on one).
    private func networkRuleCommand(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        let rules = network.rules
        switch r.command {
        case "network.rule-add":
            var body: Data?
            if let path = str(r, "body-file") { body = try await ruleBodyFile(path, r, caller: caller) }
            let serial = str(r, "from") != nil ? try await networkSerial(r) : nil
            let rule = try await rules.add(try await network.makeRule(r.args, bodyFile: body, serial: serial))
            return NetworkService.ruleJSON(rule)
        case "network.rule-list": return await network.ruleList()
        case "network.rule-remove": try await rules.remove(try need(r, "id")); return .object([:])
        case "network.rule-enable", "network.rule-disable":
            let id = try need(r, "id")
            try await rules.setEnabled(id, r.command == "network.rule-enable")
            return NetworkService.ruleJSON(try await rules.rule(id))
        case "network.rule-clear": await rules.clear(); return .object([:])
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// `--body-file`, read by the daemon at creation (the addon never reads a path). A terminal reads only inside its
    /// project and never what the sandbox never opens (Collie's data, secrets); the app anywhere. Both: at most 5 MiB.
    private func ruleBodyFile(_ path: String, _ r: Request, caller: TerminalRecord?) async throws -> Data {
        let base = URL(fileURLWithPath: r.cwd ?? caller?.cwd ?? NSHomeDirectory(), isDirectory: true)
        let real = SignedAppCheck.realPath(URL(fileURLWithPath: path, relativeTo: base).absoluteURL)
        if let me = caller {
            let root = try await projectRoot(of: me)
            guard ProjectRoot.contains(real, root: root),
                  SandboxGrantStore.readRefusal(real, home: sandboxHomeDir, collie: config.paths.root) == nil else {
                throw ProtocolError(code: .unauthorized, message: "--body-file must be inside your project (\(root.path)): copy it there first")
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: real)[.size] as? Int) ?? nil
        guard let size else { throw ProtocolError(code: .notFound, message: "No such file: \(real)") }
        guard size <= MapRule.maxBody else { throw ProtocolError(code: .invalidArgs, message: MapRuleError.bodyTooLarge(size).message) }
        do { return try Data(contentsOf: URL(fileURLWithPath: real)) }
        catch { throw ProtocolError(code: .notFound, message: "Cannot read \(real): \(error.localizedDescription)") }
    }

    private func flowId(_ r: Request) throws(ProtocolError) -> String {
        guard let id = str(r, "id"), !id.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'id'") }
        return id
    }

    private func networkSerial(_ r: Request) async throws(ProtocolError) -> String {
        if let s = str(r, "serial"), !s.isEmpty { return s }
        let candidates = r.command == "network.attach"
            ? try await devices.devices().filter { $0.state == "device" && $0.serial.hasPrefix("emulator-") }.map(\.serial)
            : await network.attached
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw ProtocolError(code: .invalidArgs, message: r.command == "network.attach" ? "No emulator online" : "No emulator is being captured")
        default: throw ProtocolError(code: .ambiguous, message: "Several emulators (\(candidates.joined(separator: ", "))); pass --serial")
        }
    }

    /// A network event for `serial`, to every network panel (panels are not bound to a serial: the payload names it).
    func networkEmitted(serial: String, name: String, payload: JSONValue) async {
        for p in ws.panels where p.pluginId == "network" {
            await pluginEmitted(panel: p.id, name: name, payload: payload)
        }
    }

    /// The last network panel closed: every capture stops and its device is restored (in the background: closing a
    /// panel must not wait on adb). Captures the app started with no panel open are left alone.
    func networkPanelClosed(_ p: Panel) async {
        guard !ws.panels.contains(where: { $0.pluginId == "network" }) else { return }
        let network = network, serials = await network.attached   // these, not whatever is attached when the task runs
        Task { for s in serials { _ = try? await network.detach(s) } }
    }
}
