import CryptoKit
import Foundation
import CollieProtocol

/// Points an Android emulator at the local mitmdump and makes it trust the mitm CA, and undoes it: the Swift form of
/// `scripts/spike/network/netsetup.sh` (its README has every step with the device output it expects).
/// Every step checks before it acts, so `attach` on an attached device repairs only what is missing and `detach` on a
/// clean one changes nothing. What the device keeps across reboots (staged CA, previous proxy, our port) lives in
/// `NetShell.stage`, so a daemon that lost its state can still undo a session (`reconcile`).
/// Emulators only; needs a rootable image (google_apis / AOSP). `adb root` restarts adbd when it is not root yet, which
/// drops every `adb reverse` (and ends an open device panel's screen session; its next viewer starts a new one).
struct DeviceNetworkSetup: Sendable {
    let adb: Adb

    struct AttachResult: Sendable, Equatable {
        var sdk: Int
        var hash: String
        /// "mounted N CAs" | "present"
        var system: String
        /// Namespaces bound now, already bound, gone before they could be: all 0 below Android 14 (no APEX).
        var apexBound = 0, apexAlready = 0, apexGone = 0
        /// "added" | "replaced" | "present" | "preexisting (left alone)"
        var user: String
        /// The device's http_proxy before the first attach ("null": none).
        var previousProxy: String
        /// File names our CA got (`<hash>.<n>`: the first free suffix, as another CA with the same subject may hold `.0`).
        var systemFile = "", userFile = ""
        /// Running apps that read the user store only when they start (Chrome) and must be restarted to see a CA that
        /// was just added or replaced. Never restarted by us.
        var restartSuggested: [String] = []
    }

    enum Reconcile: Sendable, Equatable { case none, reverseRestored, reattached, detached }

    /// Steps' worst cases on a slow emulator (APEX binds in ~60 namespaces took 12 s with a software GPU).
    private static let step: Duration = .seconds(60)

    func attach(serial: String, port: Int, caCert: URL) async throws(ProtocolError) -> AttachResult {
        try Self.guardEmulator(serial)
        guard let pem = try? String(contentsOf: caCert, encoding: .utf8), let hash = SubjectHash.old(pem: pem) else {
            throw ProtocolError(code: .notFound, message: "No readable CA certificate at \(caCert.path)")
        }
        try await root(serial)
        let probe = try await self.probe(serial)
        _ = try await shell(serial, "mkdir -p \(NetShell.stage)")
        _ = try await adb.run(["push", caCert.path, "\(NetShell.stage)/\(hash).0"], serial: serial, timeout: Self.step)
        let listing = NetShell.parseListing(try await shell(serial, NetShell.listing(hash: hash)))
        guard let caMD5 = listing.ours else { throw ProtocolError(code: .internal, message: "CA not staged on \(serial)") }
        let sysFile = NetShell.slot(hash: hash, ours: caMD5, existing: listing.system).name
        let system = NetShell.value("system", in: try await shell(serial, NetShell.systemInject(hash: hash, file: sysFile)))
        guard let system, !system.hasPrefix("failed") else { throw ProtocolError(code: .internal, message: "CA tmpfs mount failed on \(serial)") }
        var r = AttachResult(sdk: probe.sdk, hash: hash, system: system, user: "", previousProxy: probe.proxy, systemFile: sysFile)
        if probe.apex {
            let c = NetShell.counts(try await shell(serial, NetShell.apexBind(pids: try await targets(serial))))
            (r.apexBound, r.apexAlready, r.apexGone) = (c["bound"] ?? 0, c["already"] ?? 0, c["gone"] ?? 0)
        }
        switch NetShell.userPlan(hash: hash, ours: caMD5, existing: listing.user, added: probe.userAdded) {
        case .present(let f): r.user = "present"; r.userFile = f
        case .preexisting(let f): r.user = "preexisting (left alone)"; r.userFile = f
        case .write(let f, let replacing):
            let out = NetShell.value("user", in: try await shell(serial, NetShell.userInject(hash: hash, file: f)))
            guard out == "added" else { throw ProtocolError(code: .internal, message: "user-store CA failed on \(serial)") }
            r.user = replacing ? "replaced" : "added"; r.userFile = f
            if try await !shell(serial, "pidof com.android.chrome || true").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                r.restartSuggested = ["com.android.chrome"]
            }
        }
        // a second attach (or one after a daemon restart, on another port) must not save our own value as "previous"
        let ours = NetShell.proxy(port), stale = probe.port.map(NetShell.proxy)
        if probe.proxy != ours, probe.proxy != stale { _ = try await shell(serial, NetShell.savePrevious(probe.proxy)) }
        r.previousProxy = probe.proxy == ours || probe.proxy == stale ? (probe.previous ?? "null") : probe.proxy
        _ = try await shell(serial, NetShell.mark(hash: hash, port: port) + "; settings put global http_proxy \(ours)")
        try await reverse(serial, port)
        return r
    }

    /// Undoes `attach`: the proxy (only when it is still ours: never another tool's), the reverse, the APEX binds, the
    /// system tmpfs, the user-store CA (only if we added it), the staging dir. `port` nil: the one the device recorded.
    /// Returns what it did, one line per step.
    @discardableResult
    func detach(serial: String, port: Int?) async throws(ProtocolError) -> [String] {
        try Self.guardEmulator(serial)
        try await root(serial)   // after a reboot adbd is not root; the user store and mounts need it
        let probe = try await self.probe(serial)
        var log: [String] = []
        if let p = port ?? probe.port, probe.proxy == NetShell.proxy(p) {
            let v = NetShell.restoreValue(probe.previous)
            _ = try await shell(serial, "settings put global http_proxy \(NetShell.shq(v))"); log.append("proxy: restored \(v)")
        } else { log.append("proxy: left \(probe.proxy)") }
        if let p = port ?? probe.port {
            let removed = (try? await adb.run(["reverse", "--remove", "tcp:\(p)"], serial: serial, timeout: .seconds(15))) != nil
            log.append(removed ? "reverse: removed" : "reverse: absent")
        }
        guard probe.hash != nil || probe.layer else { log.append("ca: absent"); return log }
        if probe.apex {
            let out = try await shell(serial, NetShell.apexUnbind(pids: try await targets(serial)))
            log.append("apex: \(NetShell.counts(out)["unbound"] ?? 0) unbound")
        }
        log += NetShell.lines(try await shell(serial, NetShell.eject))
        return log
    }

    /// Brings the device in line with the daemon after a reconnect, a reboot or a daemon restart:
    /// - a live session (`activePort`): reverse missing → re-added; CA layer or proxy gone (reboot) → full `attach`;
    /// - none: anything we left (our proxy setting, a staged CA) → `detach`, so the device gets its network back.
    func reconcile(serial: String, activePort: Int?, caCert: URL?) async throws(ProtocolError) -> Reconcile {
        try Self.guardEmulator(serial)
        let probe = try await self.probe(serial)
        guard let active = activePort else {
            let orphanProxy = probe.port.map { probe.proxy == NetShell.proxy($0) } ?? false
            guard orphanProxy || probe.hash != nil || probe.layer else { return .none }
            try await detach(serial: serial, port: probe.port)
            return .detached
        }
        if !probe.layer || probe.proxy != NetShell.proxy(active) {
            guard let caCert else { throw ProtocolError(code: .invalidArgs, message: "reconcile needs the CA to re-attach \(serial)") }
            _ = try await attach(serial: serial, port: active, caCert: caCert)
            return .reattached
        }
        guard try await !hasReverse(serial, active) else { return .none }
        try await reverse(serial, active)
        return .reverseRestored
    }

    // MARK: steps

    struct Probe: Sendable, Equatable {
        var uid: Int, sdk: Int, proxy: String
        /// What `attach` left in the staging dir (survives reboots): CA hash, our port, the proxy before us.
        var hash: String?, port: Int?, previous: String?
        /// The user-store file we wrote (`<hash>.<n>`), nil when we wrote none.
        var userAdded: String? = nil
        /// Our tmpfs is on the system store (gone after a reboot); the device has the APEX store (Android 14+).
        var layer: Bool, apex: Bool
    }

    /// One shell round trip, no root needed.
    func probe(_ serial: String) async throws(ProtocolError) -> Probe {
        NetShell.parseProbe(try await shell(serial, NetShell.probe))
    }

    /// `adb root`, then waits for adbd to answer as uid 0 (wait-for-device can return before the restart is done).
    private func root(_ serial: String) async throws(ProtocolError) {
        do { _ = try await adb.run(["root"], serial: serial, timeout: .seconds(20)) } catch {
            if error.message.contains("cannot run as root") {
                throw ProtocolError(code: .unavailable, message: "\(serial) is not rootable (Google Play images refuse adb root); use a Google APIs or AOSP image")
            }
            throw error
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            _ = try? await adb.run(["wait-for-device"], serial: serial, timeout: .seconds(10))
            if let id = try? await shell(serial, "id -u"), id.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        throw ProtocolError(code: .unavailable, message: "adbd on \(serial) did not come back as root")
    }

    private func targets(_ serial: String) async throws(ProtocolError) -> [Int] {
        NetShell.zygoteTargets(try await shell(serial, NetShell.ps))
    }

    private func reverse(_ serial: String, _ port: Int) async throws(ProtocolError) {
        _ = try await adb.run(["reverse", "tcp:\(port)", "tcp:\(port)"], serial: serial, timeout: .seconds(15))   // replaces a rule for the same port
        guard try await hasReverse(serial, port) else { throw ProtocolError(code: .internal, message: "adb reverse tcp:\(port) did not stick on \(serial)") }
    }

    private func hasReverse(_ serial: String, _ port: Int) async throws(ProtocolError) -> Bool {
        NetShell.hasReverse(try await adb.run(["reverse", "--list"], serial: serial, timeout: .seconds(15)).stdout, port: port)
    }

    private func shell(_ serial: String, _ cmd: String) async throws(ProtocolError) -> String {
        try await adb.run(["shell", cmd], serial: serial, timeout: Self.step).stdout
    }

    static func guardEmulator(_ serial: String) throws(ProtocolError) {
        guard serial.hasPrefix("emulator-") else {
            throw ProtocolError(code: .invalidArgs, message: "Network capture works on emulators only (got \(serial))")
        }
    }
}

/// The device-side shell of `DeviceNetworkSetup`, as pure strings and parsers. Our tmpfs is mounted with source name
/// `collie-ca`, so `collie-ca <dir> ` in a namespace's mounts marks our layer; every command prints `key: value` lines
/// and exits 0 (adb reports a non-zero exit as a failure).
enum NetShell {
    static let system = "/system/etc/security/cacerts"            // system store, Android ≤13 (still there on 14+)
    static let apex = "/apex/com.android.conscrypt/cacerts"       // system store conscrypt reads on Android 14+ (immutable APEX)
    static let user = "/data/misc/user/0/cacerts-added"           // user store: Chrome trusts only this one (+ its own roots)
    static let stage = "/data/local/tmp/collie-ca"                // our CA and markers; survives reboot (the tmpfs does not)

    static func proxy(_ port: Int) -> String { "127.0.0.1:\(port)" }

    /// Single-quoted for the device's sh.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static let probe = """
        echo "uid: $(id -u)"; echo "sdk: $(getprop ro.build.version.sdk)"; echo "proxy: $(settings get global http_proxy)"; \
        echo "hash: $(cat \(stage)/hash 2>/dev/null)"; echo "port: $(cat \(stage)/port 2>/dev/null)"; \
        echo "previous: $(cat \(stage)/prev-proxy 2>/dev/null)"; echo "userAdded: $(cat \(stage)/user-added 2>/dev/null)"; \
        echo "layer: $(grep -c '^collie-ca \(system) ' /proc/mounts)"; \
        if [ -d \(apex) ]; then echo 'apex: 1'; else echo 'apex: 0'; fi
        """

    static func parseProbe(_ out: String) -> DeviceNetworkSetup.Probe {
        func v(_ k: String) -> String? { value(k, in: out).flatMap { $0.isEmpty ? nil : $0 } }
        return .init(uid: v("uid").flatMap(Int.init) ?? -1, sdk: v("sdk").flatMap(Int.init) ?? 0, proxy: v("proxy") ?? "null",
                     hash: v("hash"), port: v("port").flatMap(Int.init), previous: v("previous"), userAdded: v("userAdded"),
                     layer: (v("layer").flatMap(Int.init) ?? 0) > 0, apex: v("apex") == "1")
    }

    /// tmpfs over the system store holding the live CAs (the APEX set on 14+) plus ours as `file`; a CA rotated since is
    /// added to the existing layer. `file` comes from `slot` (another CA with the same subject may hold `<hash>.0`).
    static func systemInject(hash: String, file: String) -> String {
        let ca = "\(stage)/\(hash).0", all = "\(stage)/all"
        return """
            if grep -q '^collie-ca \(system) ' /proc/mounts; then cp \(ca) \(system)/\(file) && chmod 644 \(system)/\(file) \
            && chcon u:object_r:system_file:s0 \(system)/\(file); echo 'system: present'; \
            else src=\(system); [ -d \(apex) ] && src=\(apex); \
            rm -rf \(all) && mkdir -p \(all) && cp $src/* \(all)/ && cp \(ca) \(all)/\(file) \
            && mount -t tmpfs -o mode=755 collie-ca \(system) && cp \(all)/* \(system)/ && rm -rf \(all) \
            && chown root:root \(system)/* && chmod 644 \(system)/* && chcon u:object_r:system_file:s0 \(system) \(system)/* \
            && echo "system: mounted $(ls \(system) | wc -l) CAs" || echo 'system: failed'; fi; echo \(file) > \(stage)/sys-file
            """
    }

    /// `name md5` of our staged CA and of every `<hash>.*` in the live system store (our layer if mounted, else APEX on
    /// 14+, else the stock dir) and in the user store.
    static func listing(hash: String) -> String {
        """
        echo "ours $(md5sum \(stage)/\(hash).0 | cut -d' ' -f1)"; \
        src=\(system); if ! grep -q '^collie-ca \(system) ' /proc/mounts && [ -d \(apex) ]; then src=\(apex); fi; \
        for f in $src/\(hash).*; do [ -f "$f" ] && echo "system ${f##*/} $(md5sum "$f" | cut -d' ' -f1)"; done; \
        for f in \(user)/\(hash).*; do [ -f "$f" ] && echo "user ${f##*/} $(md5sum "$f" | cut -d' ' -f1)"; done; true
        """
    }

    struct Listing: Equatable { var ours: String?; var system: [String: String] = [:], user: [String: String] = [:] }

    static func parseListing(_ out: String) -> Listing {
        var l = Listing(ours: nil)
        for line in lines(out) {
            let f = line.split(separator: " ").map(String.init)
            switch (f.first, f.count) {
            case ("ours", 2): l.ours = f[1]
            case ("system", 3): l.system[f[1]] = f[2]
            case ("user", 3): l.user[f[1]] = f[2]
            default: break
            }
        }
        return l
    }

    /// The file our CA goes to among `existing` (name → md5): the one already holding it, else the first free
    /// `<hash>.<n>`.
    static func slot(hash: String, ours: String, existing: [String: String]) -> (name: String, present: Bool) {
        if let hit = existing.filter({ $0.value == ours }).keys.min(by: { suffix($0) < suffix($1) }) { return (hit, true) }
        var n = 0
        while existing["\(hash).\(n)"] != nil { n += 1 }
        return ("\(hash).\(n)", false)
    }

    private static func suffix(_ name: String) -> Int { name.split(separator: ".").last.flatMap { Int($0) } ?? .max }

    enum UserPlan: Equatable { case present(String), preexisting(String), write(String, replacing: Bool) }

    /// The user store: ours already there (we wrote it: present; the user did: left alone), the file we wrote before now
    /// holding an older CA (replaced in place), or a new file in the first free slot.
    static func userPlan(hash: String, ours: String, existing: [String: String], added: String?) -> UserPlan {
        let s = slot(hash: hash, ours: ours, existing: existing)
        if s.present { return s.name == added ? .present(s.name) : .preexisting(s.name) }
        if let added, existing[added] != nil { return .write(added, replacing: true) }
        return .write(s.name, replacing: false)
    }

    static let ps = "ps -A -o PID,PPID,NAME"

    /// Every zygote (zygote, zygote64, webview_zygote, *_zygote) and its children: new apps fork from a zygote and
    /// inherit its mounts, running ones need their own bind.
    static func zygoteTargets(_ ps: String) -> [Int] {
        let rows = ps.split(whereSeparator: \.isNewline).dropFirst().compactMap { l -> (Int, Int, String)? in
            let f = l.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int(f[0]), let ppid = Int(f[1]) else { return nil }
            return (pid, ppid, f[2...].joined(separator: " "))
        }
        let zygotes = Set(rows.filter { $0.2.contains("zygote") }.map(\.0))
        return rows.filter { zygotes.contains($0.0) || zygotes.contains($0.1) }.map(\.0)
    }

    /// Binds the system store over the APEX one in each pid's mount namespace that lacks it, in parallel. One line per
    /// pid: `<pid> bound|already|gone` (gone: exited between `ps` and `nsenter`).
    static func apexBind(pids: [Int]) -> String {
        guard !pids.isEmpty else { return "true" }
        return """
            for p in \(pids.map(String.init).joined(separator: " ")); do ( \
            if [ ! -e /proc/$p/ns/mnt ]; then echo "$p gone"; \
            elif grep -q '^collie-ca \(apex) ' /proc/$p/mounts 2>/dev/null; then echo "$p already"; \
            elif nsenter --mount=/proc/$p/ns/mnt -- mount --bind \(system) \(apex) 2>/dev/null; then echo "$p bound"; \
            else echo "$p gone"; fi ) & done; wait
            """
    }

    /// Unmounts our APEX bind where a pid's namespace has it. One `<pid> unbound` line per unmount.
    static func apexUnbind(pids: [Int]) -> String {
        guard !pids.isEmpty else { return "true" }
        return """
            for p in \(pids.map(String.init).joined(separator: " ")); do \
            grep -q '^collie-ca \(apex) ' /proc/$p/mounts 2>/dev/null \
            && nsenter --mount=/proc/$p/ns/mnt -- umount \(apex) 2>/dev/null && echo "$p unbound"; done; true
            """
    }

    /// Our CA into the user store (Chrome) as `file`, remembering that file so eject removes only ours.
    static func userInject(hash: String, file: String) -> String {
        let f = "\(user)/\(file)"
        return """
            mkdir -p \(user) && chown system:system \(user) && chmod 755 \(user) \
            && cp \(stage)/\(hash).0 \(f) && chown system:system \(f) && chmod 644 \(f) \
            && chcon u:object_r:misc_user_data_file:s0 \(user) \(f) && echo \(file) > \(stage)/user-added \
            && echo 'user: added' || echo 'user: failed'
            """
    }

    static func savePrevious(_ current: String) -> String { "echo \(shq(current)) > \(stage)/prev-proxy" }
    static func mark(hash: String, port: Int) -> String { "echo \(hash) > \(stage)/hash; echo \(port) > \(stage)/port" }

    /// The system tmpfs, the user-store CA we added, the staging dir (APEX binds go first, `apexUnbind`).
    static let eject = """
        if grep -q '^collie-ca \(system) ' /proc/mounts; then umount \(system) && echo 'system: unmounted'; else echo 'system: absent'; fi; \
        if [ -f \(stage)/user-added ]; then rm -f \(user)/$(cat \(stage)/user-added); echo 'user: removed'; else echo 'user: untouched'; fi; \
        rm -rf \(stage); echo 'staging: removed'
        """

    /// http_proxy to put back: none before us (`null`, empty) is ":0", which clears at once ("delete" waits for a reboot).
    static func restoreValue(_ previous: String?) -> String {
        guard let p = previous?.trimmingCharacters(in: .whitespaces), !p.isEmpty, p != "null" else { return ":0" }
        return p
    }

    static func hasReverse(_ list: String, port: Int) -> Bool {
        list.split(whereSeparator: \.isNewline).contains { $0.hasSuffix("tcp:\(port) tcp:\(port)") }
    }

    static func lines(_ out: String) -> [String] {
        out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The text after `key: ` on its first line.
    static func value(_ key: String, in out: String) -> String? {
        lines(out).first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// `<pid> <word>` lines → word counts.
    static func counts(_ out: String) -> [String: Int] {
        lines(out).reduce(into: [:]) { c, l in if let w = l.split(separator: " ").last { c[String(w), default: 0] += 1 } }
    }
}

/// OpenSSL's `X509_NAME_hash_old`, which Android uses to name CA files (`<hash>.0`): MD5 of the subject Name's DER, the
/// first 4 bytes read little-endian, `%08x`. Reads the DER by hand, down to the subject only: a full X.509 parse
/// rejects real roots (swift-certificates refuses negative serial numbers), and the bytes must be the certificate's own.
enum SubjectHash {
    static func old(pem: String) -> String? {
        guard let der = der(pem: pem), let subject = subject(der: der) else { return nil }
        let d = Array(Insecure.MD5.hash(data: subject))
        return String(format: "%08x", UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24)
    }

    /// The first certificate's DER in a PEM text.
    static func der(pem: String) -> [UInt8]? {
        guard let r = pem.range(of: "-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----", options: .regularExpression) else { return nil }
        let body = pem[r].split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map(Array.init)
    }

    /// Certificate ::= SEQUENCE { TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serial, signature, issuer, validity, subject, … } … }
    static func subject(der b: [UInt8]) -> ArraySlice<UInt8>? {
        guard let cert = tlv(b, 0), cert.tag == 0x30, let tbs = tlv(b, cert.content), tbs.tag == 0x30 else { return nil }
        var i = tbs.content
        if let v = tlv(b, i), v.tag == 0xA0 { i = v.end }
        for _ in 0..<4 { guard let e = tlv(b, i) else { return nil }; i = e.end }   // serial, signature, issuer, validity
        guard let s = tlv(b, i), s.tag == 0x30, s.end <= tbs.end else { return nil }
        return b[i..<s.end]
    }

    /// The DER element at `i`: its tag, where its content starts, where it ends. nil if it runs past the buffer.
    static func tlv(_ b: [UInt8], _ i: Int) -> (tag: UInt8, content: Int, end: Int)? {
        guard i + 1 < b.count else { return nil }
        var len = Int(b[i + 1]), start = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard (1...4).contains(n), start + n <= b.count else { return nil }
            len = b[start..<start + n].reduce(0) { $0 << 8 | Int($1) }
            start += n
        }
        guard start + len <= b.count else { return nil }
        return (b[i], start, start + len)
    }
}
