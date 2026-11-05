import Foundation
import CollieCore
import CollieProtocol

/// Acesso pelo iPhone (remote API slice 10): the Celular page's reads of `admin.remote` and `admin.remote.devices`.
public struct RemoteStatus: Equatable, Sendable {
    public struct Address: Equatable, Sendable { public var host: String; public var via: String }
    public var enabled: Bool, port: Int, tailscaleOnly: Bool, listening: Bool
    public var fingerprint: String?, error: String?
    public var addresses: [Address]
    /// Phones connected now (sessions past hello).
    public var connected: Int

    public static func from(_ v: JSONValue) -> RemoteStatus? {
        guard case .object(let o) = v, case .bool(let enabled)? = o["enabled"], case .number(let port)? = o["port"] else { return nil }
        func s(_ k: String) -> String? { if case .string(let x)? = o[k] { x } else { nil } }
        let addresses: [Address] = if case .array(let a)? = o["addresses"] {
            a.compactMap { if case .object(let x) = $0, case .string(let h)? = x["host"], case .string(let v)? = x["via"] { Address(host: h, via: v) } else { nil } }
        } else { [] }
        let connected = if case .number(let n)? = o["connected"] { Int(n) } else { 0 }
        return RemoteStatus(enabled: enabled, port: Int(port), tailscaleOnly: o["tailscaleOnly"] == .bool(true), listening: o["listening"] == .bool(true),
                            fingerprint: s("fingerprint"), error: s("error"), addresses: addresses, connected: connected)
    }
}

/// A paired phone, as `admin.remote.devices` lists it.
public struct RemoteDeviceRow: Equatable, Identifiable, Sendable {
    public var id: String, name: String, model: String
    public var readOnly: Bool
    public var pairedAt: Date?, lastSeenAt: Date?
    public var lastAddress: String?, lastVia: String?
    /// Connected now.
    public var live: Bool

    public static func rows(_ v: JSONValue) -> [RemoteDeviceRow] {
        guard case .array(let a) = v else { return [] }
        let iso = ISO8601DateFormatter()
        return a.compactMap { v in
            guard case .object(let o) = v, case .string(let id)? = o["id"], case .string(let name)? = o["name"] else { return nil }
            func s(_ k: String) -> String? { if case .string(let x)? = o[k] { x } else { nil } }
            let live = if case .number(let n)? = o["live"] { n > 0 } else { false }
            return RemoteDeviceRow(id: id, name: name, model: s("model") ?? "", readOnly: s("scope") == "read",
                                   pairedAt: s("pairedAt").flatMap(iso.date(from:)), lastSeenAt: s("lastSeenAt").flatMap(iso.date(from:)),
                                   lastAddress: s("lastAddress"), lastVia: s("lastVia"), live: live)
        }
    }
}

/// The Celular page's words.
public enum RemoteCopy {
    /// "Wi-Fi" for the local network, "Tailscale".
    public static func via(_ v: String?) -> String { v == "tailscale" ? "Tailscale" : "Wi-Fi" }
    public static func address(_ a: RemoteStatus.Address) -> String { via(a.via) + " " + a.host }
    /// "482913" → "482 913", as the phone shows it.
    public static func code(_ c: String) -> String { c.count == 6 ? c.prefix(3) + " " + c.suffix(3) : c }
    /// The fingerprint's ends, "kJ3v…9Qe2".
    public static func fingerprint(_ f: String?) -> String { guard let f, f.count > 8 else { return f ?? "—" }; return f.prefix(4) + "…" + f.suffix(4) }
    /// "agora, Tailscale 100.88.1.4" / "visto há 3 h, Wi-Fi 192.168.1.40" / "nunca conectou".
    public static func seen(_ d: RemoteDeviceRow, now: Date = Date()) -> String {
        let where_ = d.lastAddress.map { ", " + via(d.lastVia) + " " + $0 } ?? ""
        if d.live { return "agora" + where_ }
        guard let at = d.lastSeenAt else { return "nunca conectou" }
        let m = max(0, Int(now.timeIntervalSince(at) / 60))
        let ago = m < 1 ? "agora há pouco" : m < 60 ? "visto há \(m) min" : m < 48 * 60 ? "visto há \(m / 60) h" : "visto há \(m / 1440) dias"
        return ago + where_
    }
}
