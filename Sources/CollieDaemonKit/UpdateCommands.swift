import Foundation
import CollieProtocol

extension CommandRouter {
    /// `app.update.*`: the app's alone (admin token, not from a terminal; never MCP), routed before the paddock apps'
    /// `app.*` (spec 2026-11-17 §4.1). `download` replies at once; the job is followed with `status`.
    func updateCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        try await adminOnly(r, peer: peer)
        switch r.command {
        case "app.update.status": return try updateJSON(await updates.status())
        case "app.update.check": return try updateJSON(await updates.check(installed: str(r, "installed")))
        case "app.update.download": return try updateJSON(await updates.download())
        case "app.update.cancel":
            await updates.cancel()
            return try updateJSON(await updates.status())
        case "app.update.skip": return try updateJSON(await updates.skip(try need(r, "version")))
        case "app.update.settings": return try updateSettings(auto: str(r, "auto"), download: str(r, "download"))
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// nil reads; on|off saves Preferences › Atualizações (`updates` in preferences.json).
    private func updateSettings(auto: String?, download: String?) throws -> JSONValue {
        func onOff(_ k: String, _ v: String?) throws(ProtocolError) -> Bool? {
            guard let v else { return nil }
            guard let b = ["on": true, "off": false][v] else { throw ProtocolError(code: .invalidArgs, message: "\(k) must be on or off") }
            return b
        }
        let a = try onOff("auto", auto), d = try onOff("download", download)
        var s = CollieSettings.load(config.paths.root)
        if a != nil || d != nil {
            var u = s.updates ?? UpdateSettings()
            if let a { u.auto = a }
            if let d { u.download = d }
            s.updates = u
            try s.save(config.paths.root)
        }
        return .object(["auto": .bool(s.updates?.auto ?? true), "download": .bool(s.updates?.download ?? true)])
    }

    private func updateJSON(_ s: UpdateChecker.Status) throws -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: e.encode(s))
    }
}
