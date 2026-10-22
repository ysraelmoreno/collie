import Foundation
import OrqCore
import OrqProtocol

extension CommandRouter {
    /// A `device.*` command, run by the daemon. Cords are the only permission: a canvas panel needs one, a docked one
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
        let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: "device", from: caller?.id, in: ws)
        var args = r.args; args["panel"] = nil
        return try await devices.run(r.command, panel: panel, args: args, cwd: r.cwd)
    }

    /// Hands the device panels to the watchers: after a device panel opens or closes, and once at daemon start.
    func watchDevices() async { await devices.watch(panels: ws.panels) }
}
