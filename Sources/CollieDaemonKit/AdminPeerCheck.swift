import Foundation
import Darwin
import Security
import os

/// Decides whether a peer presenting the admin token is the app (on top of the managed-terminal session check).
public protocol AdminPeerCheck: Sendable {
    func allows(_ peer: Peer) async -> Bool
}

/// The peer must be the Collie app the daemon ships with: its running code valid (`SecCodeCheckValidity`) and its
/// cdhash equal to the one of `app` (Contents/MacOS/Collie next to Contents/Helpers/collied). Fails closed on any
/// Security error, a missing audit token or an unreadable `app`.
/// Every Security call runs on one serial queue, never on the cooperative pool; a verdict is kept per process
/// instance (the whole audit token: pid + pidversion), so a flood of refused requests costs one check per process
/// and can't starve the other requests. The app's cdhash is read once and again only when the file's
/// (dev, inode, mtime, size) changes (an in-place update under a running daemon).
// ponytail: same-uid residual: an agent that can stop and restart the daemon (or run another daemon on the same data)
// gets admin. The terminals' sandbox (plan 4S) closes it. An app forced under Rosetta runs its x86_64 slice, whose
// cdhash is not the native one read here: refused (fails closed). An old app instance still running after an in-place
// update no longer matches its file on disk: refused until relaunched.
public final class SignedAppCheck: AdminPeerCheck {
    private struct FileID: Equatable { var dev: dev_t, ino: ino_t, mtime: timespec, size: off_t
        static func == (a: Self, b: Self) -> Bool {
            a.dev == b.dev && a.ino == b.ino && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec && a.size == b.size
        }
    }
    private struct State { var file: FileID?; var expected: Data?; var verdicts: [[UInt32]: Bool] = [:] }
    private static let verdictCap = 1024
    private let app: URL
    private let queue = DispatchQueue(label: "collie.admin-peer-check")
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(app: URL) {
        self.app = app
        queue.async { [self] in refreshExpected() }   // off the caller: the first check waits behind it on the queue
    }

    public func allows(_ peer: Peer) async -> Bool {
        guard let tok = peer.audit else { return false }
        let key = Self.key(tok)
        if let v = state.withLock({ $0.verdicts[key] }) { return v }
        return await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: check(tok, key)) } }
    }

    /// On `queue`.
    private func check(_ tok: audit_token_t, _ key: [UInt32]) -> Bool {
        if let v = state.withLock({ $0.verdicts[key] }) { return v }   // a concurrent miss for the same process ran first
        refreshExpected()
        let expected = state.withLock { $0.expected }
        let ok = expected != nil && Self.cdhash(ofRunning: tok) == expected
        state.withLock { s in
            if s.verdicts.count >= Self.verdictCap { s.verdicts = [:] }
            s.verdicts[key] = ok
        }
        return ok
    }

    /// On `queue`: re-reads the app's cdhash when its file changed since the last read (or was never read).
    private func refreshExpected() {
        var st = stat()
        let id = stat(app.path, &st) == 0 ? FileID(dev: st.st_dev, ino: st.st_ino, mtime: st.st_mtimespec, size: st.st_size) : nil
        guard id == nil || id != state.withLock({ $0.file }) else { return }
        let h = id == nil ? nil : Self.cdhash(ofFile: app)
        state.withLock { s in
            if s.expected != h { s.verdicts = [:] }   // a new app: earlier verdicts were against the old one
            s.file = id; s.expected = h
        }
    }

    private static func key(_ tok: audit_token_t) -> [UInt32] {
        var t = tok
        return withUnsafeBytes(of: &t) { Array($0.bindMemory(to: UInt32.self)) }
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

    /// The check a daemon at `executable` (collied) on `root` runs with. Inside a bundle — collied in
    /// `<X>.app/Contents/Helpers/`, `<X>.app/Contents/MacOS/Collie` present, collied's own signature valid — the app is
    /// checked. Otherwise: on the default root (compared as real paths: the legacy Orq link, /tmp vs /private/tmp)
    /// every admin request is refused; on another root (dev, tests) the check is off (nil).
    public static func forDaemon(executable: URL, root: URL, defaultRoot: URL) -> (check: (any AdminPeerCheck)?, note: String) {
        let helpers = executable.deletingLastPathComponent(), contents = helpers.deletingLastPathComponent()
        let app = contents.appendingPathComponent("MacOS/Collie")
        let bundled = helpers.lastPathComponent == "Helpers" && contents.lastPathComponent == "Contents"
            && contents.deletingLastPathComponent().pathExtension == "app"
            && FileManager.default.isExecutableFile(atPath: app.path) && cdhash(ofFile: executable) != nil
        if bundled { return (SignedAppCheck(app: app), "admin only from \(app.path)") }
        if realPath(root) == realPath(defaultRoot) {
            return (SignedAppCheck(app: URL(fileURLWithPath: "/nonexistent/Collie")),
                    "not inside a signed Collie.app on the default root: admin requests are refused")
        }
        return (nil, "not inside Collie.app: the app signature check for admin is off")
    }

    /// `url` with symlinks resolved; a missing tail is resolved through its deepest existing ancestor.
    static func realPath(_ url: URL) -> String {
        var tail: [String] = [], u = url.standardizedFileURL
        while u.path != "/" {
            if let r = realpath(u.path, nil) {
                defer { free(r) }
                return tail.reversed().reduce(URL(fileURLWithPath: String(cString: r))) { $0.appendingPathComponent($1) }.path
            }
            tail.append(u.lastPathComponent); u = u.deletingLastPathComponent()
        }
        return url.standardizedFileURL.path
    }
}
