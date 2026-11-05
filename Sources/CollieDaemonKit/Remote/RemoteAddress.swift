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

    /// A host a phone may use: an IPv4, a MagicDNS name, or an IPv6 in brackets (as a URL wants it).
    struct Host: Equatable, Sendable { var host: String; var via: RemoteVia }

    /// This Mac's hosts a phone may use (the QR's `h=`, the Celular page's addresses).
    static func localHosts(tailscaleOnly: Bool) -> [Host] {
        let ips = interfaceIPs()
        let onTailscale = ips.contains { via($0, tailscaleOnly: true) == .tailscale }
        return hosts(ips, magicDNS: onTailscale ? TailscaleName.current() : nil, tailscaleOnly: tailscaleOnly)
    }

    /// In order: LAN IPv4, Tailscale IPv4, the MagicDNS name (only with a Tailscale address here), Tailscale IPv6 in
    /// brackets. Never loopback, public, or LAN IPv6 (link-local needs a scope id a URL can't carry).
    static func hosts(_ ips: [String], magicDNS: String?, tailscaleOnly: Bool) -> [Host] {
        var lan: [String] = [], ts4: [String] = [], ts6: [String] = []
        for ip in ips {
            let v6 = ip.contains(":")
            switch via(ip, tailscaleOnly: tailscaleOnly) {
            case .lan? where !v6: if !lan.contains(ip) { lan.append(ip) }
            case .tailscale?: if v6 { if !ts6.contains(ip) { ts6.append(ip) } } else if !ts4.contains(ip) { ts4.append(ip) }
            default: break
            }
        }
        let name = (ts4.isEmpty && ts6.isEmpty) ? [] : magicDNS.map { [$0] } ?? []
        return lan.map { Host(host: $0, via: .lan) } + ts4.map { Host(host: $0, via: .tailscale) }
            + name.map { Host(host: $0, via: .tailscale) } + ts6.map { Host(host: "[\($0)]", via: .tailscale) }
    }

    /// Every interface's IPv4 and IPv6 address (IPv6 without its scope).
    static func interfaceIPs() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil { out.append(String(cString: buf)) }
            case AF_INET6:
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                if inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count)) != nil { out.append(String(cString: buf)) }
            default: break
            }
        }
        return out
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

/// This Mac's MagicDNS name (`tailscale status --json` → `Self.DNSName`), when Tailscale runs. Asked at most once a
/// minute (the Celular page reads `admin.remote` every 3 s) and given up after 2 s; nil when there is no CLI.
enum TailscaleName {
    static let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, name: String?)?

    static func current() -> String? {
        if let c = lock.withLock({ cached }), Date().timeIntervalSince(c.at) < 60 { return c.name }
        let name = ask()
        lock.withLock { cached = (Date(), name) }
        return name
    }

    /// The name in a `tailscale status --json` reply: Running only, the trailing dot dropped, a host name only.
    static func parse(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["BackendState"] as? String == "Running",
              let me = o["Self"] as? [String: Any], var n = me["DNSName"] as? String else { return nil }
        if n.hasSuffix(".") { n.removeLast() }
        guard !n.isEmpty, n.count <= 253, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }), n.contains(".") else { return nil }
        return n.lowercased()
    }

    private static func ask() -> String? {
        guard let exe = cli.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["status", "--json"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), done = DispatchSemaphore(value: 0), h = out.fileHandleForReading
        DispatchQueue.global().async { box.data = h.readDataToEndOfFile(); done.signal() }   // EOF when it exits
        if done.wait(timeout: .now() + 2) == .timedOut { p.terminate(); return nil }   // its read ends at the kill's EOF
        return parse(box.data)
    }
}
