import Testing
import Foundation
@testable import CollieDaemonKit

private let home = URL(fileURLWithPath: "/Users/u")
private let cwd = URL(fileURLWithPath: "/private/var/folders/xx/T/collie-curator-1")
private let claudeExe = URL(fileURLWithPath: "/Users/u/.local/share/claude/versions/2.1.310")
private let claude = CuratorSandboxProfile.render(CuratorSandboxProfile.claude(executable: claudeExe, cwd: cwd, home: home))
private let cursorHome = "/Users/u/Library/Application Support/Collie/curator/cursor-home"
private let cursor = CuratorSandboxProfile.render(CuratorSandboxInput(
    executables: ["/Users/u/.local/bin/cursor-agent", "/usr/bin/env", "/bin/bash"].map { URL(fileURLWithPath: $0) },
    cwd: cwd, home: home, reads: [cursorHome], writes: [cursorHome], keychain: false, resolver: true))

/// Whether an allow (one per line) of an op starting with `op` covers `path`: its subpath, literal or regex filter.
private func allows(_ profile: String, _ op: String, _ path: String) -> Bool {
    profile.split(separator: "\n").contains { line in
        guard line.hasPrefix("(allow " + op) else { return false }
        func arg(_ kind: String) -> String? {
            guard let r = line.range(of: "(\(kind) \"") else { return nil }
            var s = "", esc = false
            for c in line[r.upperBound...] {
                if esc { s.append(c); esc = false } else if c == "\\" { esc = true } else if c == "\"" { break } else { s.append(c) }
            }
            return s
        }
        if let p = arg("subpath") { return path == p || path.hasPrefix(p + "/") }
        if let p = arg("literal") { return path == p }
        if let p = arg("regex") { return path.range(of: p, options: .regularExpression) != nil }
        return false
    }
}
private func reads(_ p: String, _ path: String) -> Bool { allows(p, "file-read", path) }
private func writes(_ p: String, _ path: String) -> Bool { allows(p, "file-write", path) }

@Suite struct CuratorSandboxProfileTests {
    @Test func startsDenyDefault() {
        for p in [claude, cursor] {
            #expect(p.split(separator: "\n").prefix(2) == ["(version 1)", "(deny default)"])
            #expect(!p.contains("(allow default)"))
        }
    }

    @Test func deniesUserSecrets() {
        let closed = [".ssh", ".ssh/id_ed25519", ".config/gh/hosts.yml", ".cursor/cli-config.json", ".codex/auth.json",
                      ".claude.json", ".claude.json.backup", ".zshrc", "Documents/x", "code/repo/README", ".aws/credentials"]
        for p in [claude, cursor] {
            for rel in closed {
                #expect(!reads(p, "/Users/u/" + rel) && !writes(p, "/Users/u/" + rel), "\(rel)")
            }
            #expect(!reads(p, "/Users/u/code/repo") && !writes(p, "/Users/u/code/repo"))
        }
        #expect(reads(claude, "/Users/u/Library/Keychains/login.keychain-db"))   // Claude's Keychain login
        #expect(!reads(cursor, "/Users/u/Library/Keychains/login.keychain-db") && !writes(cursor, "/Users/u/Library/Keychains/x"))
        #expect(!cursor.contains("securityd") && !cursor.contains("SecurityServer"))
    }

    @Test func writesOnlyCwdAndClaudeState() {
        #expect(writes(claude, cwd.path + "/x") && writes(claude, "/dev/null"))
        #expect(writes(claude, "/Users/u/.claude/.credentials.json") && writes(claude, "/Users/u/.claude/projects/p/s.jsonl"))
        #expect(writes(claude, "/Users/u/.local/state/claude/x"))
        #expect(!writes(claude, "/Users/u/.claude/projects"))   // the dir itself: no rename or swap
        #expect(reads(claude, "/Users/u/.claude/settings.json") && !writes(claude, "/Users/u/.claude/settings.json"))
        for p in ["/private/tmp/x", "/private/var/folders/xx/T/x", "/Users/u/x", claudeExe.path, "/usr/local/bin/x"] {
            #expect(!writes(claude, p), "\(p)")
        }
    }

    @Test func cursorInputDeniesClaudeFiles() {
        for rel in [".claude.json", ".claude/settings.json", ".claude/.credentials.json", ".claude/projects/x"] {
            #expect(!reads(cursor, "/Users/u/" + rel) && !writes(cursor, "/Users/u/" + rel), "\(rel)")
        }
        #expect(reads(cursor, cursorHome + "/.cursor/cli-config.json") && writes(cursor, cursorHome + "/.cursor/x"))
    }

    @Test func execOnlyListed() {
        func execs(_ p: String) -> Set<String> {
            Set(p.split(separator: "\n").filter { $0.contains("process-exec") }.map { line -> String in
                #expect(line.hasPrefix("(allow process-exec (literal \"") && !line.contains("no-sandbox"), "\(line)")
                return String(line.split(separator: "\"")[1])
            })
        }
        #expect(execs(claude) == [claudeExe.path, "/bin/sh", "/usr/bin/security"])   // `security`: claude's Keychain login
        #expect(execs(cursor) == ["/Users/u/.local/bin/cursor-agent", "/usr/bin/env", "/bin/bash", "/bin/sh"])
        #expect(!allows(claude, "process-exec", "/usr/bin/curl") && !allows(claude, "process-exec", "/bin/ps"))
    }

    @Test func noHomeWrites() {
        let mine = CuratorSandboxProfile.claude(executable: claudeExe, cwd: cwd, home: home).writes
        // the terminals' home writes: none but Claude's own state (and the Keychain, its login)
        for e in EssentialPaths.homeWrites where !mine.contains(e) && e != "Library/Keychains" {
            let path = "/Users/u/" + e.trimmingCharacters(in: CharacterSet(charactersIn: "*/")) + (e.hasSuffix("/") ? "/x" : "")
            #expect(!writes(claude, path), "\(e)")
        }
        #expect(!writes(claude, "/Users/u") && writes(claude, "/Users/u/Library/Keychains/x"))
        #expect(!writes(claude, "/Users/u/.claude.json") && !writes(claude, "/Users/u/.claude/history.jsonl"))
    }

    @Test func noUnsandboxedPs() {
        for p in [claude, cursor] { #expect(!p.contains("no-sandbox") && !p.contains("/bin/ps")) }
    }

    /// The only Unix socket is the system resolver's, for both CLIs (without it a call never resolves a host: claude never
    /// answers, cursor fails `getaddrinfo ENOTFOUND api2.cursor.sh`).
    @Test func onlyTheResolversUnixSocket() {
        for p in [claude, cursor] {
            let unix = p.split(separator: "\n").filter { $0.contains("unix-socket") }
            #expect(unix == ["(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))"])
            #expect(p.contains("(allow system-socket (socket-domain AF_UNIX))"))
            #expect(p.contains("(allow network-outbound (remote ip))"))   // Claude: any port, as before (cursor: 443 only)
        }
    }

    /// The real Cursor input opens the resolver (the fixture above only mirrors it).
    @Test func realCursorInputOpensTheResolver() {
        let i = CuratorSandboxProfile.cursor(script: URL(fileURLWithPath: "/Users/u/.local/bin/cursor-agent"), cwd: cwd, cursorHome: URL(fileURLWithPath: cursorHome))
        #expect(i.resolver)
    }

    /// What a real run on the owner's Mac showed claude needs to log in and answer (2026-11-19, claude 2.1.329): each
    /// one is narrow, and none of it reaches the Cursor profile.
    @Test func measuredClaudeNeeds() {
        #expect(reads(claude, "/private/var/db/mds/system/mdsObject.db") && reads(claude, "/var"))
        #expect(!reads(claude, "/private/var/root/x") && !reads(claude, "/private/var/folders/x"))
        for s in ["com.apple.bsd.dirhelper", "com.apple.FSEvents", "com.apple.fseventsd"] {
            #expect(claude.contains("(allow mach-lookup (global-name \"\(s)\"))") && !cursor.contains(s))
        }
        #expect(!reads(cursor, "/private/var/db/mds") && !cursor.contains("/usr/bin/security"))
    }

    /// claude is installed as a link (`~/.local/bin/claude` → `…/versions/<n>`), and the CLI reads the path it was
    /// started by: the link itself is readable (its folder can be stat'ed, its other files stay closed).
    @Test func launcherLinkIsReadable() throws {
        let base = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("collie-launcher-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent(".local/bin"), versions = base.appendingPathComponent(".local/share/claude/versions")
        for d in [bin, versions] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let target = versions.appendingPathComponent("2.1.329"), link = bin.appendingPathComponent("claude")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let p = CuratorSandboxProfile.render(CuratorSandboxProfile.claude(executable: link, cwd: cwd, home: base))
        #expect(reads(p, link.path) && reads(p, target.path))
        #expect(allows(p, "file-read-metadata", bin.path))
        #expect(!reads(p, bin.appendingPathComponent("other").path))
        #expect(allows(p, "process-exec", link.path) && allows(p, "process-exec", target.path))
    }

    /// dyld's libignition opens "/" (the system's dyld-support.sb): without it the process aborts before the CLI runs.
    /// Only the root itself: nothing under it opens with it.
    @Test func rootItselfIsReadable() {
        for p in [claude, cursor] {
            #expect(p.contains("(allow file-read* (literal \"/\"))"))
            #expect(!reads(p, "/Users/u/.ssh/id_ed25519") && !reads(p, "/private/etc/passwd") && !reads(p, "/Applications"))
        }
    }

    @Test func blockedNamesThePath() {
        #expect(CuratorSandboxProfile.blocked("EPERM: operation not permitted, open '/Users/u/.claude.json'") == "/Users/u/.claude.json")
        #expect(CuratorSandboxProfile.blocked("x\nsh: /Users/u/outside: Operation not permitted\n") == "/Users/u/outside")
        #expect(CuratorSandboxProfile.blocked("sandbox-exec: sandbox_apply: Operation not permitted") == nil)
        #expect(CuratorSandboxProfile.blocked("boom /x") == nil)
    }
}
