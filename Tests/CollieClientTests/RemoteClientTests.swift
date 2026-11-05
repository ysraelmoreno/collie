import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieClient

/// Remote API slice 10: what the Mac app reads from admin.remote* and the remote events it handles.
@MainActor struct RemoteClientTests {
    @Test func statusFromTheReply() {
        let lan: [String: JSONValue] = ["host": .string("192.168.1.10"), "via": .string("lan")], ts: [String: JSONValue] = ["host": .string("100.101.22.7"), "via": .string("tailscale")]
        let reply: [String: JSONValue] = ["enabled": .bool(true), "port": .number(47820), "tailscaleOnly": .bool(false), "listening": .bool(true), "listeningPort": .number(47820),
                                          "fingerprint": .string("kJ3vAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA9Qe2"), "connected": .number(2),
                                          "addresses": .array([.object(lan), .object(ts)])]
        let s = RemoteStatus.from(.object(reply))
        #expect(s?.enabled == true && s?.listening == true && s?.port == 47820 && s?.connected == 2 && s?.error == nil)
        #expect(s?.addresses.map { RemoteCopy.address($0) } == ["Wi-Fi 192.168.1.10", "Tailscale 100.101.22.7"])
        #expect(RemoteCopy.fingerprint(s?.fingerprint) == "kJ3v…9Qe2")
        let off = RemoteStatus.from(.object(["enabled": .bool(false), "port": .number(47820), "tailscaleOnly": .bool(true), "listening": .bool(false), "error": .string("port in use")]))
        #expect(off?.tailscaleOnly == true && off?.error == "port in use" && off?.addresses == [] && off?.connected == 0)
        #expect(RemoteStatus.from(.string("x")) == nil)
    }

    @Test func deviceRows() {
        let a: [String: JSONValue] = ["id": .string("a"), "name": .string("iPhone de Ana"), "model": .string("iPhone 16"), "scope": .string("full"), "pairedAt": .string("2026-11-04T10:00:00Z"),
                                      "lastSeenAt": .string("2026-11-05T12:00:00Z"), "lastAddress": .string("100.88.1.4"), "lastVia": .string("tailscale"), "live": .number(1)]
        let b: [String: JSONValue] = ["id": .string("b"), "name": .string("iPad"), "model": .string("iPad Air"), "scope": .string("read"), "pairedAt": .string("2026-11-02T10:00:00Z"), "live": .number(0)]
        let rows = RemoteDeviceRow.rows(.array([.object(a), .object(b)]))
        #expect(rows.map(\.id) == ["a", "b"] && rows[0].live && !rows[1].live && rows[1].readOnly && !rows[0].readOnly)
        let now = ISO8601DateFormatter().date(from: "2026-11-05T15:00:00Z")!
        #expect(RemoteCopy.seen(rows[0], now: now) == "agora, Tailscale 100.88.1.4")
        #expect(RemoteCopy.seen(rows[1], now: now) == "nunca conectou")
        var away = rows[0]; away.live = false
        #expect(RemoteCopy.seen(away, now: now).hasPrefix("visto há 3 h"), "\(RemoteCopy.seen(away, now: now))")
    }

    @Test func pairingCodeAndVia() {
        #expect(RemoteCopy.code("482913") == "482 913")
        #expect(RemoteCopy.via("tailscale") == "Tailscale" && RemoteCopy.via("lan") == "Wi-Fi")
    }

    @Test func pairingAndRevealEvents() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/collie-none")))
        let r = RemotePairingRequest(pairingId: UUID(), name: "iPhone", model: "iPhone 16", address: "192.168.1.23", via: "lan",
                                     code: "482913", deadline: Date() + 60)
        c.apply(.remotePairing(r))
        #expect(c.remotePairing == r)
        c.clearRemotePairing(r.pairingId)
        #expect(c.remotePairing == nil)
        var shown: (UUID?, UUID?)?
        c.onRemoteReveal = { shown = ($0, $1) }
        let t = UUID()
        c.apply(.remoteReveal(terminal: t, artifact: nil, device: "d"))
        #expect(shown?.0 == t && shown?.1 == nil)
    }
}
