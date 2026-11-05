import Foundation
import Darwin

/// How a remote peer reached the Mac: its source range (shown in the device sheet and the audit log).
enum RemoteVia: String, Sendable, Codable { case lan, tailscale }

/// The source filter of the remote listener (remote API spec §1), run on every connection before TLS: private LAN
/// ranges and Tailscale only. Loopback is refused (agents on this Mac have the socket); `allowLoopback` is for tests.
enum RemoteAddress {
    static func via(_ host: String, tailscaleOnly: Bool, allowLoopback: Bool = false) -> RemoteVia? {
        let ip = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host   // fe80::1%en0
        var v4 = in_addr(), v6 = in6_addr()
        let bytes: [UInt8]
        if inet_pton(AF_INET, ip, &v4) == 1 { bytes = withUnsafeBytes(of: &v4) { Array($0) } }
        else if inet_pton(AF_INET6, ip, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { bytes = Array(b[12...]) }   // ::ffff:a.b.c.d
            else { return v6Via(b, tailscaleOnly: tailscaleOnly, allowLoopback: allowLoopback) }
        } else { return nil }
        return v4Via(bytes, tailscaleOnly: tailscaleOnly, allowLoopback: allowLoopback)
    }

    /// This Mac's IPv4 addresses a phone may use (the QR's hosts): LAN first, then Tailscale, as the filter allows.
    // ponytail: IPv4 only (Tailscale gives every node a 100.x too); MagicDNS name and Bonjour come in slice 11
    static func localHosts(tailscaleOnly: Bool) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var lan: [String] = [], ts: [String] = []
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil else { continue }
            let ip = String(cString: buf)
            switch via(ip, tailscaleOnly: tailscaleOnly) {
            case .lan?: if !lan.contains(ip) { lan.append(ip) }
            case .tailscale?: if !ts.contains(ip) { ts.append(ip) }
            case nil: break
            }
        }
        return lan + ts
    }

    private static func v4Via(_ b: [UInt8], tailscaleOnly: Bool, allowLoopback: Bool) -> RemoteVia? {
        if b[0] == 100 && b[1] & 0xC0 == 64 { return .tailscale }   // 100.64.0.0/10 (Tailscale CGNAT)
        if tailscaleOnly { return nil }
        if b[0] == 127 { return allowLoopback ? .lan : nil }
        let lan = b[0] == 10 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        return lan ? .lan : nil
    }

    private static func v6Via(_ b: [UInt8], tailscaleOnly: Bool, allowLoopback: Bool) -> RemoteVia? {
        if b[0..<6] == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] { return .tailscale }   // fd7a:115c:a1e0::/48
        if tailscaleOnly { return nil }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return allowLoopback ? .lan : nil }   // ::1
        let lan = (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC   // fe80::/10, fc00::/7
        return lan ? .lan : nil
    }
}
