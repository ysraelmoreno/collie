import Foundation
import Darwin
import SystemConfiguration
import CollieProtocol

/// `admin.remote*` (app only, like every `admin.*`): the remote listener, pairing and the device sheet (remote API spec
/// §1, §2).
extension CommandRouter {
    var remoteDir: URL { config.paths.root.appendingPathComponent("remote") }

    func remoteCommand(_ r: Request) async throws -> JSONValue {
        switch r.command {
        case "admin.remote": return try await remoteSettingsCommand(r)
        case "admin.remote.pair.begin":
            let st = await remote.status
            guard st.listening, let port = st.port, let fp = remoteIdentity?.fingerprint else {
                throw ProtocolError(code: .unavailable, message: "Ligue o acesso pelo iPhone antes de parear.")
            }
            let settings = CollieSettings.load(config.paths.root).remote
            let o = remotePairing.begin()
            var q = URLComponents()
            q.scheme = "collie"; q.host = "pair"
            q.queryItems = [.init(name: "v", value: "1"), .init(name: "id", value: try remoteInstallId()),
                            .init(name: "n", value: Self.computerName()),
                            .init(name: "h", value: RemoteAddress.localHosts(tailscaleOnly: settings?.tailscaleOnly ?? false).joined(separator: ",")),
                            .init(name: "p", value: "\(port)"), .init(name: "fp", value: fp), .init(name: "s", value: o.secret)]
            return .object(["pairingId": .string(o.pairingId.uuidString.lowercased()), "qr": .string(q.string ?? ""),
                            "expiresAt": .string(o.expiresAt.ISO8601Format())])
        case "admin.remote.pair.confirm":
            guard let id = UUID(uuidString: try need(r, "pairingId")) else { throw ProtocolError(code: .invalidArgs, message: "pairingId must be an id") }
            guard let accept = ["accept": true, "refuse": false][try need(r, "decision")] else {
                throw ProtocolError(code: .invalidArgs, message: "decision must be accept or refuse")
            }
            return .object(["accepted": .bool(try remotePairing.decide(id, accept: accept) != nil)])
        case "admin.remote.devices":
            let sessions = remote.sessions
            return .array(remoteDevices.all.map { d in
                var o = d.publicJSON; o["live"] = .number(Double(sessions.count(d.id))); return .object(o)
            })
        case "admin.remote.devices.revoke":
            let id = try remoteDeviceId(r)
            guard try remoteDevices.revoke(id) else { throw ProtocolError(code: .notFound, message: "Aparelho não encontrado.") }
            remote.sessions.close(device: id, .revoked)
            return .object([:])
        case "admin.remote.devices.scope":
            let id = try remoteDeviceId(r)
            guard let scope = RemoteDevice.Scope(rawValue: try need(r, "scope")) else {
                throw ProtocolError(code: .invalidArgs, message: "scope must be full or read")
            }
            guard try remoteDevices.setScope(id, scope) else { throw ProtocolError(code: .notFound, message: "Aparelho não encontrado.") }
            return .object([:])   // ponytail: a live session keeps its scope until its next hello (enforced from slice 4)
        case "admin.remote.identity.rotate":
            remoteIdentity = try RemoteIdentity.rotate(dir: remoteDir, devices: remoteDevices)
            let s = CollieSettings.load(config.paths.root).remote ?? Self.remoteDefault
            let st = await remote.apply(s, identity: remoteIdentity, installId: try remoteInstallId())   // restarts: sessions get 4003
            return remoteJSON(s, st)
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    private static var remoteDefault: RemoteSettings { RemoteSettings(enabled: false, port: RemoteSettings.defaultPort, tailscaleOnly: false) }

    private func remoteDeviceId(_ r: Request) throws -> UUID {
        guard let id = UUID(uuidString: try need(r, "id")) else { throw ProtocolError(code: .invalidArgs, message: "id must be a device id") }
        return id
    }

    private func remoteSettingsCommand(_ r: Request) async throws -> JSONValue {
        let root = config.paths.root
        var settings = CollieSettings.load(root)
        var s = settings.remote ?? Self.remoteDefault
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
        let changed = s != settings.remote ?? Self.remoteDefault
        if changed || (action != "status" && settings.remote == nil) {
            settings.remote = s
            try settings.save(root)
        }
        // on: an identity that can't be made is the answer; status only reports (the start's failure is in `error`)
        if s.enabled, remoteIdentity == nil, action != "status" { remoteIdentity = try RemoteIdentity.loadOrCreate(dir: remoteDir) }
        if remoteIdentity == nil { remoteIdentity = try? RemoteIdentity.load(dir: remoteDir) }   // status: never makes one
        let st = action == "status" && !changed ? await remote.status
            : await remote.apply(s, identity: remoteIdentity, installId: (try? remoteInstallId()) ?? "")
        return remoteJSON(s, st)
    }

    /// At daemon start: listen when the user left it on. A failure is only reported (in `admin.remote`).
    func startRemote() async {
        guard let s = CollieSettings.load(config.paths.root).remote, s.enabled else { return }
        do { remoteIdentity = try RemoteIdentity.loadOrCreate(dir: remoteDir) } catch {
            await remote.failed("remote identity: \((error as? ProtocolError)?.message ?? "\(error)")")
            return
        }
        _ = await remote.apply(s, identity: remoteIdentity, installId: (try? remoteInstallId()) ?? "")
    }

    /// This install's id (QR `id`, Bonjour TXT later): random, kept in `remote/` (a restore retires it with the identity).
    func remoteInstallId() throws -> String {
        let f = remoteDir.appendingPathComponent("install-id")
        if let s = try? String(contentsOf: f, encoding: .utf8), UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased()
        try DesignService.writePrivate(Data(id.utf8), to: f)
        return id
    }

    /// The Mac's name as Sharing shows it.
    nonisolated static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
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
