import Foundation
import CollieProtocol

extension CommandRouter {
    /// `design.engine.*`: the app's alone (admin token, not from a terminal; never MCP), routed before the design
    /// plug-in's commands. `install` replies `{job}` at once; the rest of the job is read with `status`.
    func designEngineCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        try await adminOnly(r, peer: peer)
        switch r.command {
        case "design.engine.status": return try await engineStatus()
        case "design.engine.install": return .object(["job": try engineJSON(await engineInstaller.install())])
        case "design.engine.cancel":
            await engineInstaller.cancel()
            return .object([:])
        case "design.engine.remove":
            try await engineInstaller.remove()
            return .object([:])
        default:
            throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    private func engineStatus() async throws -> JSONValue {
        var o: [String: JSONValue] = [:]
        switch engineState() {
        case .absent: o["state"] = .string("absent")
        case .installed(let e):
            o["state"] = .string("installed")
            var i: [String: JSONValue] = ["source": .string(e.source.rawValue)]
            if let v = e.version { i["version"] = .string(v) }
            o["installed"] = .object(i)
        case .needsUpdate(let installed, _, let reinstall):
            o["state"] = .string("needsUpdate")
            o["reinstall"] = .bool(reinstall)
            var i: [String: JSONValue] = ["source": .string(FigcraftEngine.Source.appSupport.rawValue)]
            if let installed { i["version"] = .string(installed) }
            o["installed"] = .object(i)
        }
        if let pin = figcraftPin { o["pinned"] = .object(["version": .string(pin.version), "size": .number(Double(pin.size))]) }
        if let job = await engineInstaller.job { o["job"] = try engineJSON(job) }
        return .object(o)
    }

    private func engineJSON<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }
}
