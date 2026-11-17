import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }

/// The daemon config: the release manifest and dmg served by a fake fetch, the dmg check always good.
private func configure(_ c: inout DaemonConfig, fetch: FakeUpdateFetch) {
    fetch.serve(UpdateCheckerTests.manifestURL, UpdateCheckerTests.manifest())
    fetch.serve(UpdateCheckerTests.dmgURL(), UpdateCheckerTests.dmg)
    c.updateFetch = fetch.fetch
    c.updateDmgCheck = { _ in true }
    c.version = "0.1.1"
}

@Suite struct UpdateCommandTests {
    static let names = ["app.update.status", "app.update.check", "app.update.download", "app.update.cancel",
                        "app.update.skip", "app.update.settings"]

    @Test func terminalPeerRefused() async throws {
        let f = FakeUpdateFetch()
        try await withDaemon(configure: { configure(&$0, fetch: f) }) { d, p in
            let t = try await spawn(d, p, "W")
            let tok = try await tokenOf(d, t.id)
            for c in Self.names {
                let args: [String: JSONValue] = c == "app.update.skip" ? ["version": .string("0.2.0")] : [:]
                let asTerminal = try await send(p, Request(id: "t", terminalId: t.id, token: tok, command: c, args: args))
                #expect(asTerminal.error?.code == .unauthorized, "\(c): \(asTerminal)")
                let noToken = try await send(p, Request(id: "n", command: c, args: args))
                #expect(noToken.error?.code == .unauthorized, "\(c)")
            }
            #expect(f.calls.isEmpty)   // nothing fetched for a refused caller
        }
    }

    @Test func notListedInMCPNorAPlugin() {
        for c in Self.names {
            #expect(Commands.spec(c)?.exposedToMCP == false, "\(c)")
            #expect(PluginRegistry.command(c) == nil, "\(c)")
        }
    }

    @Test func statusRoundTrip() async throws {
        let f = FakeUpdateFetch()
        try await withDaemon(configure: { configure(&$0, fetch: f) }) { d, p in
            #expect(obj(try await admin(d, p, "app.update.status"))["state"] == .string("none"))
            let checked = obj(try await admin(d, p, "app.update.check"))
            #expect(checked["state"] == .string("available"), "\(checked)")
            guard case .object(let a)? = checked["available"] else { Issue.record("no available: \(checked)"); return }
            #expect(a["version"] == .string("0.2.0") && a["figcraftEngine"] == .string("0.7.0-c1"))
            guard case .string(let when)? = checked["lastCheck"] else { Issue.record("no lastCheck"); return }
            #expect(ISO8601DateFormatter().date(from: when) != nil, "\(when)")
            _ = try await admin(d, p, "app.update.download")
            var st: [String: JSONValue] = [:]
            for _ in 0..<200 {
                st = obj(try await admin(d, p, "app.update.status"))
                if st["state"] == .string("ready") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(st["state"] == .string("ready"), "\(st)")
            #expect(st["staged"] == .string(p.root.appendingPathComponent(".update-staging/Collie-0.2.0.dmg").path), "\(st)")
        }
    }

    @Test func checkTakesTheAppVersion() async throws {
        let f = FakeUpdateFetch()
        try await withDaemon(configure: { configure(&$0, fetch: f) }) { d, p in
            let st = obj(try await admin(d, p, "app.update.check", ["installed": .string("0.2.0")]))
            #expect(st["state"] == .string("none"), "\(st)")
        }
    }

    @Test func skipNeedsVersion() async throws {
        let f = FakeUpdateFetch()
        try await withDaemon(configure: { configure(&$0, fetch: f) }) { d, p in
            let r = try await admin(d, p, "app.update.skip")
            #expect(r.error?.code == .invalidArgs, "\(r)")
            _ = try await admin(d, p, "app.update.check")
            let st = obj(try await admin(d, p, "app.update.skip", ["version": .string("0.2.0")]))
            #expect(st["state"] == .string("none"), "\(st)")
        }
    }

    @Test func settingsSavedAndReported() async throws {
        let f = FakeUpdateFetch()
        try await withDaemon(configure: { configure(&$0, fetch: f) }) { d, p in
            var st = obj(try await admin(d, p, "app.update.settings"))
            #expect(st["auto"] == .bool(true) && st["download"] == .bool(true), "\(st)")
            st = obj(try await admin(d, p, "app.update.settings", ["auto": .string("off"), "download": .string("off")]))
            #expect(st["auto"] == .bool(false) && st["download"] == .bool(false), "\(st)")
            #expect(CollieSettings.load(p.root).updates == UpdateSettings(auto: false, download: false))
            #expect(obj(try await admin(d, p, "app.update.status"))["state"] == .string("disabled"))
            let bad = try await admin(d, p, "app.update.settings", ["auto": .string("maybe")])
            #expect(bad.error?.code == .invalidArgs)
        }
    }

    @Test func cliParsesUpdateCommands() throws {
        #expect(try ArgvParser.parse(["app", "update", "status"]).command == "app.update.status")
        #expect(try ArgvParser.parse(["app", "update", "skip", "--version", "0.2.0"]).command == "app.update.skip")
    }
}
