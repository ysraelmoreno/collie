import Foundation
import CollieProtocol

/// Pairing a phone (remote API spec §2), as a state machine with an injected clock: one live pairing at a time; its
/// secret is single use, lives 5 min and dies after 5 wrong tries; a claimed pairing shows a 6-digit code on both
/// sides and waits ≤ 60 s for the Mac's click. Timeouts are read off the clock when asked (no timers here; the
/// gateway polls or wakes `outcome`). Under `lock`.
final class RemotePairing: @unchecked Sendable {
    static let secretLife: TimeInterval = 300, confirmLife: TimeInterval = 60, maxFailures = 5

    /// What the phone says it is, plus where it connected from (for the Mac's dialog).
    struct Device: Equatable, Sendable { var name: String; var model: String; var address: String; var via: RemoteVia }
    struct Offer: Sendable { var pairingId: UUID; var secret: String; var expiresAt: Date }
    struct Claim: Sendable { var pairingId: UUID; var code: String }
    enum Outcome: Equatable, Sendable { case pending, accepted(Device), refused, timedOut, delivered }

    private enum State {
        case open(secret: String, expires: Date, failures: Int)
        case awaiting(Device, code: String, deadline: Date)
        case done(Outcome)
    }
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var id: UUID?
    private var state: State = .done(.refused)
    /// `wait` callers, resumed by every change (begin, decide) and by their deadline.
    private var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]
    /// One message for every refused secret: wrong, expired, used, none begun.
    private static let refused = ProtocolError(code: .unauthorized, message: "Código de pareamento inválido ou expirado. Gere um novo QR no Mac.")

    init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// A new pairing; any other one (open or waiting for its click) ends refused.
    func begin() -> Offer {
        let secret = (try? RemoteDevices.randomToken()) ?? UUID().uuidString + UUID().uuidString
        let o = Offer(pairingId: UUID(), secret: secret, expiresAt: now() + Self.secretLife)
        lock.withLock { id = o.pairingId; state = .open(secret: secret, expires: o.expiresAt, failures: 0) }
        wake()
        return o
    }

    /// The phone presents the QR's secret. Consumes it; the pairing then waits for the Mac's click.
    func claim(secret: String, device: Device) throws(ProtocolError) -> Claim {
        var d = device
        d.name = String(d.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        d.model = String(d.model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !d.name.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "O aparelho precisa de um nome.") }
        let t = now()
        lock.lock(); defer { lock.unlock() }
        guard let id, case .open(let s, let expires, let failures) = state, t <= expires else { throw Self.refused }
        guard constantTimeEqual(secret, s) else {
            if failures + 1 >= Self.maxFailures {
                state = .done(.refused)
                throw ProtocolError(code: .tooMany, message: "Tentativas demais: gere um novo QR no Mac.")
            }
            state = .open(secret: s, expires: expires, failures: failures + 1)
            throw Self.refused
        }
        let code = String(format: "%06d", UInt32.random(in: 0..<1_000_000))   // SystemRandomNumberGenerator: CSPRNG on Apple
        state = .awaiting(d, code: code, deadline: t + Self.confirmLife)
        return Claim(pairingId: id, code: code)
    }

    /// The pairing waiting for the Mac's click, if any (for the app's dialog).
    var awaiting: (pairingId: UUID, device: Device, code: String)? {
        let t = now()
        return lock.withLock {
            expire(t)
            guard let id, case .awaiting(let d, let code, _) = state else { return nil }
            return (id, d, code)
        }
    }

    /// The Mac's click: the device to create when accepted, nil when refused.
    func decide(_ pairingId: UUID, accept: Bool) throws(ProtocolError) -> Device? {
        defer { wake() }
        let t = now()
        lock.lock(); defer { lock.unlock() }
        expire(t)
        guard pairingId == id else { throw ProtocolError(code: .notFound, message: "Pareamento não encontrado.") }
        switch state {
        case .awaiting(let d, _, _):
            state = .done(accept ? .accepted(d) : .refused)
            return accept ? d : nil
        case .done(.timedOut): throw ProtocolError(code: .timeout, message: "O iPhone esperou demais: pareie de novo.")
        default: throw ProtocolError(code: .notFound, message: "Pareamento não está esperando confirmação.")
        }
    }

    /// `pair.wait`: blocks until the pairing `pairingId` (claimed) is decided or times out. An accepted pairing is handed
    /// out once (`.accepted`, then `.delivered`), so its device is created once.
    func wait(_ pairingId: UUID) async -> Outcome {
        while true {
            let key = UUID()
            // checked and registered under one lock: a decide in between can't be missed
            let o: Outcome? = await withCheckedContinuation { (k: CheckedContinuation<Outcome?, Never>) in
                let t = now()
                let r = lock.withLock { () -> (Outcome?, Date?) in
                    let o = outcomeLocked(pairingId, t)
                    if case .accepted = o { state = .done(.delivered); return (o, nil) }
                    guard o == .pending else { return (o, nil) }
                    waiters[key] = k
                    switch state {
                    case .awaiting(_, _, let d): return (nil, d)
                    case .open(_, let e, _): return (nil, e)
                    case .done: return (nil, t)
                    }
                }
                if let o = r.0 { return k.resume(returning: o) }
                // ponytail: the deadline is the injected clock's, waited for in real time (the daemon's clock is real)
                let after = max(0, (r.1 ?? t).timeIntervalSince(t)) + 0.05
                DispatchQueue.global().asyncAfter(deadline: .now() + after) { [weak self] in self?.wake(key) }
            }
            if let o { return o }
        }
    }

    private func wake(_ only: UUID? = nil) {
        let ks = lock.withLock { () -> [CheckedContinuation<Outcome?, Never>] in
            if let only { return waiters.removeValue(forKey: only).map { [$0] } ?? [] }
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        ks.forEach { $0.resume(returning: nil) }
    }

    func outcome(_ pairingId: UUID) -> Outcome {
        let t = now()
        return lock.withLock { outcomeLocked(pairingId, t) }
    }

    /// Under `lock`.
    private func outcomeLocked(_ pairingId: UUID, _ t: Date) -> Outcome {
        expire(t)
        guard pairingId == id else { return .refused }   // replaced by a newer pairing (or never this one)
        switch state {
        case .open, .awaiting: return .pending
        case .done(let o): return o
        }
    }

    /// Under `lock`.
    private func expire(_ t: Date) {
        switch state {
        case .awaiting(_, _, let deadline) where t > deadline: state = .done(.timedOut)
        case .open(_, let expires, _) where t > expires: state = .done(.refused)
        default: break
        }
    }
}
