import Foundation
import CollieProtocol

/// `admin.remote` (app only, like every `admin.*`): read or change the remote listener (remote API spec §1).
extension CommandRouter {
    var remoteDir: URL { config.paths.root.appendingPathComponent("remote") }

    func remoteCommand(_ r: Request) async throws -> JSONValue {
        let root = config.paths.root
        var settings = CollieSettings.load(root)
        var s = settings.remote ?? RemoteSettings(enabled: false, port: RemoteSettings.defaultPort, tailscaleOnly: false)
        let action = str(r, "action") ?? "status"
        guard ["on", "off", "status"].contains(action) else {
            throw ProtocolError(code: .invalidArgs, message: "action must be on, off or status")
        }
        if let v = r.args["port"], v != .null {
            let p: Int? = switch v { case .number(let n): n == n.rounded() ? Int(exactly: n) : nil; case .string(let t): Int(t); default: nil }
            // 0: any free port (tests and dev daemons); the real one is `listeningPort`
            guard let p, p == 0 || (1024...65535).contains(p) else {
                throw ProtocolError(code: .invalidArgs, message: "port must be between 1024 and 65535")
            }
            s.port = p
        }
        if let t = str(r, "tailscale-only") {
            guard let on = ["on": true, "off": false][t] else { throw ProtocolError(code: .invalidArgs, message: "tailscale-only must be on or off") }
            s.tailscaleOnly = on
        }
        if action != "status" { s.enabled = action == "on" }
        let changed = s != settings.remote ?? RemoteSettings(enabled: false, port: RemoteSettings.defaultPort, tailscaleOnly: false)
        if changed || (action != "status" && settings.remote == nil) {
            settings.remote = s
            try settings.save(root)
        }
        if s.enabled, remoteIdentity == nil { remoteIdentity = try RemoteIdentity.loadOrCreate(dir: remoteDir) }
        if remoteIdentity == nil { remoteIdentity = try? RemoteIdentity.load(dir: remoteDir) }   // status: never makes one
        let st = action == "status" && !changed ? await remote.status : await remote.apply(s, identity: remoteIdentity)
        return remoteJSON(s, st)
    }

    /// At daemon start: listen when the user left it on. A failure is only reported (in `admin.remote`).
    func startRemote() async {
        guard let s = CollieSettings.load(config.paths.root).remote, s.enabled else { return }
        do { remoteIdentity = try RemoteIdentity.loadOrCreate(dir: remoteDir) } catch { return }
        _ = await remote.apply(s, identity: remoteIdentity)
    }

    private func remoteJSON(_ s: RemoteSettings, _ st: RemoteGateway.Status) -> JSONValue {
        var o: [String: JSONValue] = ["enabled": .bool(s.enabled), "port": .number(Double(s.port)),
                                      "tailscaleOnly": .bool(s.tailscaleOnly), "listening": .bool(st.listening)]
        if let p = st.port { o["listeningPort"] = .number(Double(p)) }
        if let f = remoteIdentity?.fingerprint { o["fingerprint"] = .string(f) }
        if let e = st.error { o["error"] = .string(e) }
        return .object(o)
    }
}
