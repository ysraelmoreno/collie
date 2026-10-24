import Foundation
import Darwin
import Security
import os

/// Decides whether a peer presenting the admin token is the app (on top of the managed-terminal session check).
public protocol AdminPeerCheck: Sendable {
    func allows(_ peer: Peer) -> Bool
}

/// The peer must be the Collie app the daemon ships with: its running code valid (`SecCodeCheckValidity`) and its
/// cdhash equal to the one of `app` (Contents/MacOS/Collie next to Contents/Helpers/collied). Fails closed on any
/// Security error, a missing audit token or an unreadable `app`.
// ponytail: same-uid residual: replacing Collie.app with a re-signed build and restarting the daemon passes. Real
// isolation needs agents under another macOS user or a sandbox.
public final class SignedAppCheck: AdminPeerCheck {
    private struct State { var expected: Data?; var passed: Set<[UInt32]> = [] }
    private let app: URL
    private let state: OSAllocatedUnfairLock<State>

    public init(app: URL) {
        self.app = app
        state = OSAllocatedUnfairLock(initialState: State(expected: Self.cdhash(ofFile: app)))
    }

    public func allows(_ peer: Peer) -> Bool {
        guard var tok = peer.audit else { return false }
        // one process instance (pid + pidversion, bumped by exec) is checked once
        let key = withUnsafeBytes(of: &tok) { Array($0.bindMemory(to: UInt32.self)) }
        if state.withLock({ $0.passed.contains(key) }) { return true }
        guard let got = Self.cdhash(ofRunning: tok) else { return false }
        var ok = state.withLock { $0.expected == got }
        if !ok, let now = Self.cdhash(ofFile: app), now == got {   // the app was updated in place under this daemon
            state.withLock { $0.expected = now; $0.passed = [] }
            ok = true
        }
        if ok { state.withLock { s in if s.passed.count > 64 { s.passed = [] }; s.passed.insert(key) } }
        return ok
    }

    static func cdhash(ofFile url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return cdhash(code)
    }

    static func cdhash(ofRunning tok: audit_token_t) -> Data? {
        var tok = tok
        let attrs = [kSecGuestAttributeAudit: Data(bytes: &tok, count: MemoryLayout<audit_token_t>.size)] as CFDictionary
        var code: SecCode?, stat: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        return cdhash(stat)
    }

    private static func cdhash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoUnique as String] as? Data
    }
}
