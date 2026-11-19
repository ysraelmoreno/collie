import Foundation

/// What one curator call may touch. `reads`/`writes`: home-relative (`EssentialPaths` syntax: `x*` any name with that
/// prefix, `x/` the children only) or absolute.
struct CuratorSandboxInput: Sendable {
    var executables: [URL]
    var cwd: URL
    var home: URL
    var reads: [String]
    var writes: [String]
    var keychain: Bool
    /// Absolute dirs whose files may be mapped executable (native `.node` modules); none by default.
    var mapExecutable: [String] = []
    /// nil: any outbound IP port (Claude, as before); else only this one (Cursor: 443).
    var port: Int? = nil
}

/// The curator's own Seatbelt profile (spec 2026-11-17 §4, E5): `(deny default)`, then only what a headless CLI needs.
/// No home writes, no unsandboxed `ps`, no Unix sockets, no tag (its denials raise no card). One allow per line.
enum CuratorSandboxProfile {
    static func render(_ i: CuratorSandboxInput) -> String {
        func real(_ u: URL) -> String { SignedAppCheck.realPath(u) }
        let home = real(i.home), cwd = real(i.cwd)
        let q = SandboxProfile.q
        func path(_ e: String) -> String { e.hasPrefix("/") ? e : home + "/" + e }
        func filter(_ e: String) -> String {
            let p = path(e)
            if p.hasSuffix("*") { return "(regex \(q("^" + SandboxProfile.re(p.dropLast()) + "[^/]*(/|$)")))" }
            if p.hasSuffix("/") { return "(regex \(q("^" + SandboxProfile.re(p) + ".+")))" }
            return "(subpath \(q(p)))"
        }
        let exes = i.executables.flatMap { [$0.path, real($0)] } + ["/bin/sh"]
        let exeDirs = i.executables.map { URL(fileURLWithPath: real($0)).deletingLastPathComponent().path }
        // a CLI installed as a link (`~/.local/bin/claude` → `…/versions/<n>`) reads the path it was started by: the link
        // itself, never its folder's other files
        let launchers = i.executables.map(\.path).filter { $0 != real(URL(fileURLWithPath: $0)) }
        let launcherReads: [String] = launchers.map { "(literal \(q($0)))" }
        let keychain = i.keychain ? [home + "/Library/Keychains"] : []
        let reads = ["/System", "/usr/lib", "/usr/share", "/usr/bin", "/bin", "/private/var/db/dyld", "/private/etc/ssl",
                     "/private/var/db/timezone", "/dev"].map(filter)
            // "/" itself (not what is under it): dyld's libignition opens it as its openat root, and aborts the process
            // (SIGABRT, exit 134, before any of the CLI's code) when it can't (the system's dyld-support.sb)
            + ["/", "/private/etc/hosts", "/private/etc/resolv.conf", "/private/etc/localtime"].map { "(literal \(q($0)))" }
            + launcherReads
            + (exeDirs + [cwd] + keychain).map(filter) + i.reads.map(filter)
        var writes = ([cwd] + keychain).map(filter) + i.writes.map(filter) + ["(literal \"/dev/null\")"]
        // the Security framework's lock (`EssentialPaths.userCacheWrites`' `mds`)
        if i.keychain { writes.append(filter(real(SandboxInput.darwinDir(_CS_DARWIN_USER_CACHE_DIR)) + "/mds")) }
        // path lookup: the ancestors of what is readable can be stat'ed, never listed or read
        var ancestors: Set<String> = []
        for p in exeDirs + launchers + [cwd] + keychain + i.reads.map(path) + i.writes.map(path) {
            var u = URL(fileURLWithPath: p).deletingLastPathComponent()
            while u.pathComponents.count > 1 { ancestors.insert(u.path); u = u.deletingLastPathComponent() }
        }
        ancestors.insert("/")
        let services = ["com.apple.trustd", "com.apple.trustd.agent", "com.apple.dnssd.service", "com.apple.mDNSResponder",
                        "com.apple.system.opendirectoryd.libinfo", "com.apple.system.notification_center",
                        "com.apple.system.logger", "com.apple.logd", "com.apple.diagnosticd", "com.apple.SystemConfiguration.configd",
                        "com.apple.SystemConfiguration.DNSConfiguration", "com.apple.networkd", "com.apple.nsurlsessiond"]
            + (i.keychain ? ["com.apple.SecurityServer"] : [])
        var out = ["(version 1)", "(deny default)",
                   "(allow process-fork)", "(allow signal (target same-sandbox))", "(allow sysctl-read)",
                   "(allow ipc-posix-shm-read-data (ipc-posix-name \"apple.shm.notification_center\"))",
                   "(allow system-socket (socket-domain AF_INET))", "(allow system-socket (socket-domain AF_INET6))",
                   i.port.map { "(allow network-outbound (remote ip \"*:\($0)\"))" } ?? "(allow network-outbound (remote ip))"]
        out += Set(exes).sorted().map { "(allow process-exec (literal \(q($0))))" }
        out += reads.map { "(allow file-read* \($0))" }
        out += ancestors.sorted().map { "(allow file-read-metadata (literal \(q($0))))" }
        out += writes.map { "(allow file-write* \($0))" }
        out += i.mapExecutable.map { "(allow file-map-executable (subpath \(q(real(URL(fileURLWithPath: $0))))))" }
        out += services.map { "(allow mach-lookup (global-name \(q($0))))" }
        if i.keychain { out.append("(allow mach-lookup (global-name-regex \"^com\\\\.apple\\\\.securityd\"))") }
        return out.joined(separator: "\n") + "\n"
    }

    /// The path a denial names in the CLI's stderr (`EPERM: operation not permitted, open '/x'`, `sh: /x: Operation not
    /// permitted`), shown as "curador bloqueado pelo sandbox: <caminho>"; nil when none is named.
    static func blocked(_ stderr: String) -> String? {
        for line in stderr.split(separator: "\n") where line.range(of: "not permitted", options: .caseInsensitive) != nil {
            if let r = line.range(of: #"/[^'"\s,:]+"#, options: .regularExpression) { return String(line[r]) }
        }
        return nil
    }

    /// Cursor (R3, cursor-agent 2026.11.17): the `cursor-agent` script (`#!/usr/bin/env bash`, `realpath`, `dirname`,
    /// `basename`: where this macOS has them, `/bin` and/or `/usr/bin`; 15 has `/bin/realpath` only) execs the version
    /// dir's `node`, which maps its native `.node` modules; the SEA binaries are listed too. Reads and writes all of its
    /// own `cursor-home` (config, login, state, `.npm`, compile cache) and nothing of the user's home; no Keychain (file
    /// login); outbound to `CursorCuratorRunner.port` only. `<version>/.running` stays unwritable.
    /// ponytail: npm/npx the agent may call aren't allowed to exec; a real run says ("curador bloqueado pelo sandbox: …")
    static func cursor(script: URL, cwd: URL, cursorHome: URL) -> CuratorSandboxInput {
        let version = URL(fileURLWithPath: SignedAppCheck.realPath(script)).deletingLastPathComponent()
        let tools = ["env", "bash", "realpath", "dirname", "basename"].flatMap { ["/bin/" + $0, "/usr/bin/" + $0] }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        let exes = [script] + ["node", "cursor-agent-sea", "cursor-agent-worker-sea"].map { version.appendingPathComponent($0) }
            + tools.map { URL(fileURLWithPath: $0) }
        let h = SignedAppCheck.realPath(cursorHome)
        return CuratorSandboxInput(executables: exes, cwd: cwd, home: cursorHome, reads: [h], writes: [h], keychain: false,
                                   mapExecutable: [version.path], port: CursorCuratorRunner.port)
    }

    /// Claude: reads its `.claude/` and state, writes its credentials file and state dirs (their children), Keychain login.
    /// `~/.claude.json` stays closed until R2 shows Claude needs it.
    static func claude(executable: URL, cwd: URL, home: URL) -> CuratorSandboxInput {
        let state = EssentialPaths.agentStateDirs[".claude"] ?? []
        return CuratorSandboxInput(executables: [executable], cwd: cwd, home: home, reads: [".claude"] + state,
                                   writes: [".claude/.credentials.json*"] + state.map { $0 + "/" }, keychain: true)
    }
}
