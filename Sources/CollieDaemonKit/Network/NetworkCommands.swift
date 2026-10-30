import Foundation
import CollieCore
import CollieProtocol

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
