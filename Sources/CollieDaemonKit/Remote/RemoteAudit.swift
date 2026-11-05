import Foundation
import CollieProtocol

/// `<root>/remote/audit.jsonl` (remote API spec §4.3): one line per mutating command and per pair / hello / revoke,
/// `{at, device, deviceName, address, via, command, target, result}`. Never a token, never chat text. 0600, rotated
/// at 5 MiB keeping 2 (`audit.jsonl.1`, `.2`).
final class RemoteAudit: @unchecked Sendable {   // under `lock`
    static let maxBytes = 5 << 20, keep = 2
    let file: URL
    private let lock = NSLock()

    init(dir: URL) { file = dir.appendingPathComponent("audit.jsonl") }

    struct Who: Sendable { var device: UUID?, deviceName: String?, address: String?, via: RemoteVia? }

    /// `result`: "ok" or the error code.
    func log(_ who: Who, _ command: String, target: String? = nil, result: String) {
        var o: [String: JSONValue] = ["at": .string(Date().ISO8601Format()), "command": .string(command), "result": .string(result)]
        if let d = who.device { o["device"] = .string(d.uuidString.lowercased()) }
        if let n = who.deviceName { o["deviceName"] = .string(n) }
        if let a = who.address { o["address"] = .string(a) }
        if let v = who.via { o["via"] = .string(v.rawValue) }
        if let target { o["target"] = .string(target) }
        guard var line = try? JSONEncoder().encode(JSONValue.object(o)) else { return }
        line.append(0x0A)
        lock.withLock {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.count > Self.maxBytes {
                for i in stride(from: Self.keep, to: 1, by: -1) {
                    let from = URL(fileURLWithPath: file.path + ".\(i - 1)"), to = URL(fileURLWithPath: file.path + ".\(i)")
                    try? fm.removeItem(at: to); try? fm.moveItem(at: from, to: to)
                }
                let one = URL(fileURLWithPath: file.path + ".1")
                try? fm.removeItem(at: one); try? fm.moveItem(at: file, to: one)
            }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        }
    }

    func log(_ s: Who, _ command: String, target: String? = nil, _ r: Response) {
        log(s, command, target: target, result: r.ok ? "ok" : (r.error?.code.rawValue ?? "error"))
    }
}

/// Rate limits (spec §4.2), token buckets on a monotonic clock: per device 30 requests/s (burst 60) and 30 mutating
/// per minute; per source address, 10 failed `pair`/`session.hello` within a minute refuse its new connections for
/// 60 s. Shared by every session of a listener.
final class RemoteLimits: @unchecked Sendable {   // under `lock`
    struct Bucket { var tokens: Double; var at: ContinuousClock.Instant }
    private let lock = NSLock()
    private var requests: [UUID: Bucket] = [:], mutating: [UUID: Bucket] = [:]
    private var failures: [String: [ContinuousClock.Instant]] = [:]
    private var blocked: [String: ContinuousClock.Instant] = [:]

    static let rate = 30.0, burst = 60.0, mutPerMinute = 30.0, failLimit = 10, failWindow: Duration = .seconds(60), blockFor: Duration = .seconds(60)

    /// nil: taken. Else seconds until it would be.
    func take(_ device: UUID, mutating m: Bool) -> Double? {
        let now = ContinuousClock.now
        return lock.withLock {
            func refill(_ b: inout Bucket, rate: Double, cap: Double) {
                let dt = Double((now - b.at).components.attoseconds) / 1e18 + Double((now - b.at).components.seconds)
                b.tokens = min(cap, b.tokens + dt * rate); b.at = now
            }
            var r = requests[device] ?? Bucket(tokens: Self.burst, at: now)
            refill(&r, rate: Self.rate, cap: Self.burst)
            var mb = mutating[device] ?? Bucket(tokens: Self.mutPerMinute, at: now)
            refill(&mb, rate: Self.mutPerMinute / 60, cap: Self.mutPerMinute)
            defer { requests[device] = r; mutating[device] = mb }
            if r.tokens < 1 { return (1 - r.tokens) / Self.rate }
            if m, mb.tokens < 1 { return (1 - mb.tokens) / (Self.mutPerMinute / 60) }
            r.tokens -= 1
            if m { mb.tokens -= 1 }
            return nil
        }
    }

    func failed(_ address: String) {
        let now = ContinuousClock.now
        lock.withLock {
            var f = (failures[address] ?? []).filter { now - $0 < Self.failWindow }
            f.append(now)
            failures[address] = f
            if f.count >= Self.failLimit { blocked[address] = now + Self.blockFor; failures[address] = nil }
        }
    }

    func isBlocked(_ address: String) -> Bool {
        let now = ContinuousClock.now
        return lock.withLock {
            guard let until = blocked[address] else { return false }
            if now >= until { blocked[address] = nil; return false }
            return true
        }
    }
}
