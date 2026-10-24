import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// A fake home in a temp dir (R2): every profile here closes it, never the real one. `code/repo` (git, one commit,
/// a paddock worktree at `.collie/paddocks/p`), `code/other`, secrets, agent config/state, and a stand-in Collie root
/// with a listening daemon socket.
final class FakeHome {
    let base = URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: "/tmp/collie-sp-\(UUID().uuidString.prefix(8))")))
    var home: URL { base.appendingPathComponent("home") }
    var collie: URL { home.appendingPathComponent("Library/Application Support/Collie") }
    var socket: URL { collie.appendingPathComponent("run/collied.sock") }
    var repo: URL { home.appendingPathComponent("code/repo") }
    var paddock: URL { repo.appendingPathComponent(".collie/paddocks/p") }
    var other: URL { home.appendingPathComponent("code/other") }
    let id = UUID()
    private var sock: Int32 = -1

    init(git: Bool = true, socket listening: Bool = true) throws {
        let fm = FileManager.default
        func file(_ rel: String, _ text: String = "x\n") throws {
            let u = home.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: false, encoding: .utf8)
        }
        for f in ["Documents/x", ".ssh/id_ed25519", ".ssh/id_ed25519.pub", ".ssh/known_hosts", ".ssh/config", ".aws/credentials",
                  ".netrc", ".config/gh/hosts.yml", ".zshrc", ".gitconfig", ".nvm/nvm.sh", ".claude/settings.json",
                  ".claude/CLAUDE.md", ".claude/hooks/h.sh", ".claude.json", ".codex/config.toml", "code/repo/README",
                  "code/other/x", "Library/Application Support/Collie/admin.token",
                  "Library/Application Support/Collie/workspaces/w/workspace.json",
                  "Library/Application Support/Collie/hooks/\(id.uuidString).claude.json", "Library/Application Support/Collie/hooks/other.claude.json"] {
            try file(f, f == ".gitconfig" ? "[core]\n" : "x\n")
        }
        // what a developer's home already has (R19: the daemon makes only the agent's own dirs)
        for d in ["Library/Caches", "Library/Preferences", "Library/Keychains", "Library/Developer/Xcode", ".swiftpm",
                  ".claude/projects", ".codex/sessions",
                  "Library/Application Support/Collie/run"] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        if git {
            try Self.git(["init", "-q", "-b", "main"], in: repo)
            try Self.git(["add", "."], in: repo)
            try Self.git(["commit", "-qm", "init"], in: repo)
            try Self.git(["worktree", "add", "-q", "-b", "collie/p", paddock.path], in: repo)
        }
        if listening { try listen() }
    }
    deinit { if sock >= 0 { close(sock) }; try? FileManager.default.removeItem(at: base) }

    /// git with the fake home and no system/global config of the developer's.
    static func git(_ args: [String], in dir: URL, home: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        p.environment = ["HOME": (home ?? dir).path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ProtocolError(code: .internal, message: "git \(args) failed") }
    }

    private func listen() throws {
        sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in for (i, c) in path.enumerated() where i < b.count { b[i] = UInt8(bitPattern: c) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, Darwin.listen(sock, 8) == 0 else { throw ProtocolError(code: .internal, message: "socket: \(errno)") }
    }

    /// A pasture terminal on the repo by default.
    func input(project: URL? = nil, paddockTerminal: Bool = false, grants: [SandboxGrant] = [], agent: Preset = .claude,
               command: String? = nil) -> SandboxInput {
        let proj = project ?? (paddockTerminal ? paddock : repo)
        let g = SandboxInput.gitDirs(of: proj)
        return SandboxInput(terminal: id, project: proj, mainGitDir: g.common, worktreeGitDir: g.worktree,
                            paddockWorktrees: paddockTerminal ? [] : [repo.appendingPathComponent(".collie/paddocks")],
                            home: home, collieRoot: collie, ownFiles: [collie.appendingPathComponent("hooks/\(id.uuidString).claude.json")],
                            terminalDir: SandboxLaunch.dir(id, root: collie), socket: socket, agent: agent, command: command, grants: grants)
    }
    func profile(_ i: SandboxInput) throws -> URL {
        try SandboxLaunch.prepare(i, root: collie, collie: URL(fileURLWithPath: "/usr/bin/true"))
    }

    /// `script` under `profile` (sh -c, HOME = the fake home); exit status and output.
    @discardableResult
    func run(_ profile: URL, _ script: String, cwd: URL? = nil, env: [String: String] = [:]) throws -> (status: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-f", profile.path, "/bin/sh", "-c", script]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1"].merging(env) { $1 }
        p.currentDirectoryURL = cwd ?? repo
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func ok(_ profile: URL, _ script: String, cwd: URL? = nil) throws -> Bool { try run(profile, script, cwd: cwd).status == 0 }
    func h(_ rel: String) -> String { AgentLaunch.quote(home.appendingPathComponent(rel).path) }
}

@Suite(.serialized) struct SandboxProfileTests {
    @Test func writesProjectOnly() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.ok(p, "echo a > \(AgentLaunch.quote(f.repo.path))/new && mkdir -p \(AgentLaunch.quote(f.repo.path))/d/e"))
        #expect(try f.ok(p, "echo a > /private/tmp/collie-sp-probe-$$ && rm /private/tmp/collie-sp-probe-$$"))   // temp stays writable
        #expect(try f.ok(p, "t=$(getconf DARWIN_USER_TEMP_DIR)collie-sp-$$; echo a > $t && rm $t"))
        #expect(try f.ok(p, "script -q /dev/null /usr/bin/true </dev/null"))   // a new pty (agents' command runners)
        for bad in [".zshrc", ".gitconfig", ".ssh/config", "Documents/y", "code/other/y", "newfile", "Library/LaunchAgents/dev.collie.daemon.plist"] {
            #expect(try !f.ok(p, "mkdir -p \"$(dirname \(f.h(bad)))\" 2>/dev/null; echo a > \(f.h(bad))"), "\(bad)")
        }
        #expect(try !f.ok(p, "rm \(f.h("code/other/x"))"))   // nothing deleted outside the project
        #expect(try !f.ok(p, "echo a > /Applications/collie-sp-probe"))   // the app bundle's folder
        #expect(try !f.ok(p, "echo a > /usr/local/collie-sp-probe"))
    }

    @Test func readsDeniedOutsideProject() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.ok(p, "cat \(AgentLaunch.quote(f.repo.path))/README"))
        #expect(try !f.ok(p, "cat \(f.h("Documents/x"))"))
        #expect(try !f.ok(p, "ls \(f.h("Documents"))"))
        #expect(try !f.ok(p, "cat \(f.h("code/other/x"))"))   // another repo
        #expect(try !f.ok(p, "ls \(AgentLaunch.quote(f.home.path))"))
        #expect(try f.ok(p, "test -d \(f.h("Documents"))"))   // metadata only (stat/realpath)
    }

    @Test func secretsDenied() throws {
        let f = try FakeHome()
        // even a grant of the whole home doesn't reopen them
        let p = try f.profile(f.input(grants: [SandboxGrant(path: f.home.path, access: .read, scope: .terminal, owner: f.id)]))
        for s in [".ssh/id_ed25519", ".aws/credentials", ".netrc", ".config/gh/hosts.yml"] {
            #expect(try !f.ok(p, "cat \(f.h(s))"), "\(s)")
        }
        for r in [".ssh/known_hosts", ".ssh/config", ".ssh/id_ed25519.pub"] { #expect(try f.ok(p, "cat \(f.h(r))"), "\(r)") }
    }

    @Test func collieDataDenied() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        func c(_ rel: String) -> String { AgentLaunch.quote(f.collie.appendingPathComponent(rel).path) }
        #expect(try !f.ok(p, "cat \(c("admin.token"))"))
        #expect(try !f.ok(p, "cat \(c("workspaces/w/workspace.json"))"))
        #expect(try !f.ok(p, "echo '{}' > \(c("workspaces/w/workspace.json"))"))   // R10: an import can't be staged from inside
        #expect(try !f.ok(p, "echo x > \(c("sandbox/grants.json"))"))
        #expect(try !f.ok(p, "echo x > \(c("sandbox/\(f.id.uuidString).sb"))"))   // its own profile
        #expect(try !f.ok(p, "echo x > \(c("sandbox/\(f.id.uuidString)/bin/swift"))"))   // its shims
        #expect(try !f.ok(p, "cat \(c("hooks/other.claude.json"))"))
        #expect(try !f.ok(p, "ls \(c(""))"))
        #expect(try f.ok(p, "cat \(c("hooks/\(f.id.uuidString).claude.json"))"))   // its own generated files
        #expect(try f.ok(p, "cat \(c("sandbox/\(f.id.uuidString)/bin/swift")) >/dev/null"))
        #expect(try f.ok(p, "echo x > \(c("sandbox/\(f.id.uuidString)/state/history"))"))   // its own history
        #expect(try f.ok(p, "/usr/bin/nc -w 1 -U \(AgentLaunch.quote(f.socket.path)) </dev/null"))   // the daemon socket: connect OK
    }

    @Test func gitHooksAndConfigDenied() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        let g = AgentLaunch.quote(f.repo.appendingPathComponent(".git").path)
        #expect(try !f.ok(p, "echo x > \(g)/hooks/pre-commit"))
        #expect(try !f.ok(p, "rm -rf \(g)/hooks"))
        #expect(try !f.ok(p, "echo x >> \(g)/config"))
        #expect(try !f.ok(p, "git config core.hooksPath /tmp/evil"))   // lock file + rename
        #expect(try !f.ok(p, "mkdir -p \(g)/info; echo '* filter=x' > \(g)/info/attributes"))
        #expect(try !f.ok(p, "mv \(g) \(g)old"))
        #expect(try !f.ok(p, "echo x > \(g)/worktrees/p/commondir"))
        // C1: commondir in any git dir redirects config + hooks for the user's own git
        #expect(try !f.ok(p, "echo /private/tmp/evil.git > \(g)/commondir"))
        #expect(try !f.ok(p, "mkdir -p \(g)/modules/sub && echo x > \(g)/modules/sub/commondir"))
        // N1/R17: no nested repo (its config runs in the user's git status), no nested gitfile or link
        #expect(try !f.ok(p, "git init -q sub && git -C sub config core.fsmonitor 'touch /private/tmp/collie-sp-marker'"))
        #expect(try !f.ok(p, "mkdir -p sub2 && echo 'gitdir: /private/tmp/x' > sub2/.git"))
        #expect(try !f.ok(p, "mkdir -p sub3 && ln -s /private/tmp sub3/.git"))
        #expect(try !f.ok(p, "mkdir -p a/b && mkdir a/b/.git"))
        // R20: tool checkouts at the project root stay possible; the same names anywhere else don't
        #expect(try f.ok(p, "git init -q .build/checkouts/dep && git init -q Carthage/Checkouts/dep"))
        #expect(try !f.ok(p, "git init -q a/.build/checkouts/dep"))
        #expect(try !f.ok(p, "git init -q build/checkouts/dep"))
        let common = try f.run(p, "git rev-parse --git-common-dir").out
        #expect(common.trimmingCharacters(in: .whitespacesAndNewlines) == ".git", "\(common)")
        #expect(try f.ok(p, "echo x >> README && git add README && git commit -qm t"))   // a plain commit still works
        // a non-git project can't get a planted .git pointer either
        let plain = f.home.appendingPathComponent("code/plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let q = try f.profile(f.input(project: plain))
        #expect(try !f.ok(q, "echo 'gitdir: /tmp' > .git", cwd: plain))
        #expect(try !f.ok(q, "ln -s /private/tmp .git", cwd: plain))
        #expect(try !f.ok(q, "git init -q", cwd: plain))
        #expect(try f.ok(q, "echo x > a", cwd: plain))
    }

    @Test func pastureCantWritePaddockWorktree() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.ok(p, "cat \(AgentLaunch.quote(f.paddock.path))/README"))   // reads stay
        #expect(try !f.ok(p, "echo x > \(AgentLaunch.quote(f.paddock.path))/new"))
        #expect(try !f.ok(p, "mkdir -p \(AgentLaunch.quote(f.repo.path))/.collie/paddocks/q"))   // a future one too
        #expect(try !f.ok(p, "echo x > \(AgentLaunch.quote(f.repo.path))/.git/worktrees/p/HEAD"))   // its git dir
    }

    @Test func paddockCanCommit() throws {
        let f = try FakeHome(), p = try f.profile(f.input(paddockTerminal: true))
        #expect(try f.ok(p, "echo y > n && git add n && git commit -qm t && git log --oneline | head -1", cwd: f.paddock))
        #expect(try !f.ok(p, "echo x > \(AgentLaunch.quote(f.repo.path))/README"))   // the pasture's tree
        let g = AgentLaunch.quote(f.repo.appendingPathComponent(".git").path)
        #expect(try !f.ok(p, "echo x > \(g)/hooks/post-commit"))
        #expect(try !f.ok(p, "echo x >> \(g)/config"))
        #expect(try !f.ok(p, "echo x > \(g)/worktrees/p/commondir"))
        #expect(try !f.ok(p, "echo 'gitdir: /tmp' > .git", cwd: f.paddock))
        #expect(try !f.ok(p, "rm .git && ln -s /private/tmp .git", cwd: f.paddock))
        #expect(try !f.ok(p, "git init -q nested", cwd: f.paddock))
        #expect(try !f.ok(p, "echo x > \(g)/HEAD"))   // the pasture's HEAD
        // a sibling worktree's git dir stays closed
        try FakeHome.git(["worktree", "add", "-q", "-b", "collie/q", f.repo.appendingPathComponent(".collie/paddocks/q").path], in: f.repo)
        #expect(try !f.ok(p, "echo x > \(g)/worktrees/q/HEAD"))
    }

    @Test func globalAgentConfigReadOnlyAndAgentStateWritable() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        // R13 (user decision): ~/.claude.json is writable (Claude rewrites it atomically on every start)
        #expect(try f.ok(p, "echo '{}' > \(f.h(".claude.json.tmp.1")) && mv \(f.h(".claude.json.tmp.1")) \(f.h(".claude.json"))"))
        for r in [".claude/settings.json", ".claude/CLAUDE.md", ".codex/config.toml"] {
            #expect(try f.ok(p, "cat \(f.h(r))"), "\(r)")
            #expect(try !f.ok(p, "echo x >> \(f.h(r))"), "\(r)")
        }
        #expect(try !f.ok(p, "echo x > \(f.h(".claude/hooks/h.sh"))"))
        #expect(try !f.ok(p, "mkdir -p \(f.h(".claude/skills/x"))"))
        #expect(try !f.ok(p, "mv \(f.h(".claude")) \(f.h(".claude-old"))"))   // can't move the config aside
        #expect(try f.ok(p, "mkdir -p \(f.h(".claude/projects/x")) && echo x > \(f.h(".claude/projects/x/s.jsonl"))"))
        #expect(try f.ok(p, "mkdir -p \(f.h(".claude/todos")) && echo x > \(f.h(".claude/todos/t.json"))"))
        #expect(try f.ok(p, "echo x > \(f.h(".codex/sessions/s.jsonl"))"))
        #expect(try f.ok(p, "mkdir -p \(f.h(".npm/_cacache")) && echo x > \(f.h(".npm/_cacache/x"))"))
        #expect(try f.ok(p, "mkdir -p \(f.h("Library/Developer/Xcode/DerivedData/x"))"))
        #expect(try f.ok(p, "mkdir -p \(f.h("Library/Developer/CoreSimulator/Devices"))"))
        for no in ["Library/Developer/Toolchains/x", "Library/Developer/Xcode/UserData/x", "Library/Developer/Xcode/Templates/x",
                   "Library/org.swift.swiftpm/configuration", ".swiftpm/configuration", "Library/Caches/Google"] {
            #expect(try !f.ok(p, "mkdir -p \(f.h(no))"), "\(no)")
        }
        #expect(try f.ok(p, "mkdir -p \(f.h(".swiftpm/cache/x"))"))
    }

    /// I1 + R19: only the agent preset's own home dirs are made, as real dirs, by the daemon; never through a symlink.
    @Test func agentHomeDirsMadeForItsPresetOnly() throws {
        let f = try FakeHome(), fm = FileManager.default
        try fm.removeItem(at: f.home.appendingPathComponent(".claude/projects"))
        let before = Set(try fm.contentsOfDirectory(atPath: f.home.path))
        _ = try f.profile(f.input(agent: .shell))
        #expect(Set(try fm.contentsOfDirectory(atPath: f.home.path)) == before)   // a shell terminal makes none
        #expect(!fm.fileExists(atPath: f.home.appendingPathComponent(".claude/projects").path))
        let p = try f.profile(f.input())   // claude
        var st = stat()
        #expect(lstat(f.home.appendingPathComponent(".claude/projects").path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
        #expect(lstat(f.home.appendingPathComponent(".local/state/claude").path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)   // B2
        #expect(!fm.fileExists(atPath: f.home.appendingPathComponent(".local/bin").path))
        for none in ["go", ".cargo", ".bun", ".cursor", "Library/org.swift.swiftpm"] {
            #expect(!fm.fileExists(atPath: f.home.appendingPathComponent(none).path), "\(none)")
        }
        #expect(try !f.ok(p, "ln -s /private/tmp \(f.h(".cargo"))"))   // the agent can't make one (a symlink) itself
        _ = try f.profile(f.input(agent: .custom, command: "cursor-agent"))
        #expect(lstat(f.home.appendingPathComponent(".cursor").path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
        // a symlink already there is never followed by the daemon's mkdir
        let g = try FakeHome()
        let out = g.base.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.removeItem(at: g.home.appendingPathComponent(".codex"))
        try fm.createSymbolicLink(at: g.home.appendingPathComponent(".codex"), withDestinationURL: out)
        _ = try g.profile(g.input(agent: .codex))
        #expect((try? fm.contentsOfDirectory(atPath: out.path))?.isEmpty == true)
    }

    /// B2/B3: the agent is found by the executable's basename, past a leading `env VAR=val…`; Claude's state dir included.
    @Test func agentHomeDetection() {
        #expect(EssentialPaths.agentHome(.claude, command: nil).contains(".local/state/claude"))
        #expect(EssentialPaths.agentHome(.custom, command: "/opt/bin/claude --x").first == ".claude")
        #expect(EssentialPaths.agentHome(.custom, command: "env FOO=1 BAR=2 codex exec hi").first == ".codex")
        #expect(EssentialPaths.agentHome(.custom, command: "/usr/bin/env cursor-agent").first == ".cursor")
        #expect(EssentialPaths.agentHome(.custom, command: "npm test").isEmpty)
        #expect(EssentialPaths.agentHome(.shell, command: nil).isEmpty)
    }

    /// R19: the router hands the custom command over, so a custom cursor-agent terminal gets ~/.cursor.
    @Test func routerPassesCustomCommand() async throws {
        let f = try FakeHome(git: false, socket: false)
        var c = testConfig(Paths(root: f.collie)); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        var rec = TerminalRecord(id: UUID(), name: "C", preset: .custom, command: "/x/cursor-agent --model m", cwd: f.base.path, isShepherd: false)
        rec.projectRoot = f.base.appendingPathComponent("proj").path
        _ = try await d.router.prepareSandbox(rec)
        var st = stat()
        #expect(lstat(f.home.appendingPathComponent(".cursor/chats").path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// R18: agent-state dirs take writes to their children only; Claude's sourced shell state stays read-only.
    @Test func agentStateDirsCantBeSwapped() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        let todos = f.h(".claude/todos")
        #expect(try f.ok(p, "echo x > \(todos)/t.json && rm \(todos)/t.json"))
        #expect(try !f.ok(p, "mv \(todos) /private/tmp/collie-sp-todos-$$"))
        #expect(try !f.ok(p, "rmdir \(todos)"))
        #expect(try !f.ok(p, "rm -rf \(todos) && ln -s \(f.h(".claude/hooks")) \(todos)"))
        var st = stat()
        #expect(lstat(f.home.appendingPathComponent(".claude/todos").path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
        for ro in [".claude/shell-snapshots/snapshot-zsh.sh", ".claude/session-env/x/env"] {
            #expect(try !f.ok(p, "mkdir -p \"$(dirname \(f.h(ro)))\"; echo 'echo pwned' >> \(f.h(ro))"), "\(ro)")
        }
    }

    @Test func projectAgentConfigWritable() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.ok(p, "mkdir -p .claude .codex .cursor .vscode && echo '{}' > .claude/settings.json && echo '{}' > .mcp.json && echo x > .envrc && echo x > .vscode/settings.json"))
    }

    @Test func launchctlAndOpenExecDenied() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        let text = try String(contentsOf: p, encoding: .utf8)
        #expect(text.contains(#"(literal "/bin/launchctl")"#) && text.contains(#"(literal "/usr/bin/open")"#))
        // the kernel refuses the exec itself: neither runs (exit 126). R14: by path only, defence in depth
        #expect(try f.run(p, "/bin/launchctl help").status == 126)
        #expect(try f.run(p, "/usr/bin/open -h").status == 126)
        #expect(try f.ok(p, "/usr/bin/osascript -e 'return 1' >/dev/null"))   // accepted, stays open
        #expect(try f.ok(p, "/bin/ps -p $$ >/dev/null"))   // setuid ps runs (no-sandbox)
    }

    /// R12 (user decision): Claude keeps its Keychain login: the security CLI runs, the keychain files are writable.
    @Test func securityExecAllowed() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.run(p, "/usr/bin/security help >/dev/null 2>&1").status != 126)
        #expect(!(try String(contentsOf: p, encoding: .utf8)).contains(#"(literal "/usr/bin/security")"#))
        #expect(try f.ok(p, "mkdir -p \(f.h("Library/Keychains")) && echo x > \(f.h("Library/Keychains/probe-db"))"))
    }

    @Test func signalOthersDenied() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep"); outside.arguments = ["30"]
        try outside.run(); defer { outside.terminate() }
        #expect(try !f.ok(p, "kill -0 \(outside.processIdentifier)"))
        #expect(try !f.ok(p, "kill \(outside.processIdentifier)"))
        #expect(outside.isRunning)
        #expect(try f.ok(p, "sleep 5 & kill $!"))   // its own children
    }

    @Test func grantReadOpensPath() throws {
        let f = try FakeHome()
        let p = try f.profile(f.input(grants: [SandboxGrant(path: f.home.appendingPathComponent("Documents").path, access: .read, scope: .terminal, owner: f.id)]))
        #expect(try f.ok(p, "cat \(f.h("Documents/x"))"))
        #expect(try !f.ok(p, "echo y > \(f.h("Documents/x"))"))
        #expect(try !f.ok(p, "cat \(f.h("code/other/x"))"))
    }

    @Test func grantWriteOpensPath() throws {
        let f = try FakeHome()
        let p = try f.profile(f.input(grants: [SandboxGrant(path: f.other.path, access: .write, scope: .lot, owner: f.id)]))
        #expect(try f.ok(p, "cat \(f.h("code/other/x")) && echo y > \(f.h("code/other/y"))"))
        #expect(try !f.ok(p, "echo y > \(f.h("Documents/y"))"))
        // a grant never reopens Collie's data or git internals
        let q = try f.profile(f.input(grants: [SandboxGrant(path: f.home.path, access: .write, scope: .terminal, owner: f.id)]))
        #expect(try f.ok(q, "echo y > \(f.h("Documents/y"))"))
        #expect(try !f.ok(q, "echo x > \(AgentLaunch.quote(f.collie.appendingPathComponent("admin.token").path))"))
        #expect(try !f.ok(q, "echo x > \(AgentLaunch.quote(f.repo.path))/.git/hooks/pre-commit"))
        #expect(try !f.ok(q, "cat \(f.h(".ssh/id_ed25519"))"))
        // R23: nor writes to secrets, launchd agents, or a granted repo's git files (its objects stay writable)
        for d in ["code/other/.git/hooks", "code/other/.git/objects", ".ssh"] {
            try FileManager.default.createDirectory(at: f.home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for bad in [".ssh/authorized_keys", ".aws/credentials", "Library/LaunchAgents/x.plist", "code/other/.git/hooks/pre-commit",
                    "code/other/.git/config", "code/other/.git/info/attributes"] {
            #expect(try !f.ok(q, "mkdir -p \"$(dirname \(f.h(bad)))\" 2>/dev/null; echo x > \(f.h(bad))"), "\(bad)")
        }
        #expect(try !f.ok(q, "mv \(f.h("code/other/.git")) \(f.h("code/other/.gitold"))"))
        #expect(try f.ok(q, "echo x > \(f.h("code/other/.git/objects/o"))"))
    }

    @Test func pathsWithSpacesAndUnicode() throws {
        let f = try FakeHome()
        let proj = f.home.appendingPathComponent("code/proj \"é\" ünï ✓ (1)")
        try FakeHome.git(["init", "-q"], in: proj)
        let p = try f.profile(f.input(project: proj))
        #expect(try f.ok(p, "echo x > 'new file é' && git add . && git commit -qm t", cwd: proj))
        #expect(try !f.ok(p, "echo x > .git/hooks/pre-commit", cwd: proj))
        #expect(try !f.ok(p, "cat \(f.h("Documents/x"))", cwd: proj))
        let sib = f.home.appendingPathComponent("code/proj \"é\" ünï ✓ (2)")
        try FileManager.default.createDirectory(at: sib, withIntermediateDirectories: true)
        #expect(try !f.ok(p, "echo x > \(AgentLaunch.quote(sib.path))/y", cwd: proj))   // regex-escaped, not a prefix match
    }

    @Test func symlinkOutOfProjectDenied() throws {
        let f = try FakeHome()
        let fm = FileManager.default
        try fm.createSymbolicLink(at: f.repo.appendingPathComponent("docs"), withDestinationURL: f.home.appendingPathComponent("Documents"))
        try fm.createSymbolicLink(at: f.repo.appendingPathComponent("key"), withDestinationURL: f.home.appendingPathComponent(".ssh/id_ed25519"))
        let p = try f.profile(f.input())
        #expect(try !f.ok(p, "cat docs/x"))
        #expect(try !f.ok(p, "echo y > docs/y"))
        #expect(try !f.ok(p, "cat key"))
        #expect(try !f.ok(p, "ln \(f.h("Documents/x")) hard"))   // a hard link to a closed file
        // a project reached through a symlink (and /tmp -> /private/tmp) still confines to the resolved path
        let link = URL(fileURLWithPath: "/tmp/\(f.base.lastPathComponent)-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: f.repo); defer { try? fm.removeItem(at: link) }
        let q = try f.profile(f.input(project: link))
        #expect(try f.ok(q, "echo x > \(link.path)/viaLink", cwd: link))
        #expect(try !f.ok(q, "cat \(f.h("Documents/x"))", cwd: link))
    }

    @Test func toolEssentialsReadable() throws {
        let f = try FakeHome(), p = try f.profile(f.input())
        #expect(try f.ok(p, "/usr/bin/true && ls /usr/bin >/dev/null && cat \(f.h(".nvm/nvm.sh")) \(f.h(".zshrc")) \(f.h(".gitconfig"))"))
        for d in ["/opt/homebrew", "/Applications/Xcode.app"] where FileManager.default.fileExists(atPath: d) {
            #expect(try f.ok(p, "ls \(d) >/dev/null"), "\(d)")
        }
    }

    @Test func renderEscapes() {
        #expect(SandboxProfile.q(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(SandboxProfile.re("/a.b+(c)") == #"/a\.b\+\(c\)"#)
        let f = try? FakeHome(git: false)
        let text = f.map { SandboxProfile.render($0.input()) } ?? ""
        #expect(text.hasPrefix("(version 1)\n(allow default)") && text.contains("collie-term:\(f?.id.uuidString ?? "")"))
    }
}

/// The per-terminal PATH shims (R3, R4) with fake tools that print their argv: never the real swift/xcodebuild here.
@Suite struct SandboxShimTests {
    func setup() throws -> (FakeHome, URL, URL) {
        let f = try FakeHome(git: false)
        let fake = f.base.appendingPathComponent("fakebin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        for t in SandboxLaunch.toolShims + ["collie"] {
            let u = fake.appendingPathComponent(t)
            try "#!/bin/sh\necho \"\(t) $*\"\n".write(to: u, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        _ = try SandboxLaunch.prepare(f.input(project: f.base), root: f.collie, collie: fake.appendingPathComponent("collie"))
        return (f, fake, SandboxLaunch.dir(f.id, root: f.collie).appendingPathComponent("bin"))
    }
    func run(_ s: (FakeHome, URL, URL), _ cmd: String) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        p.environment = ["PATH": "\(s.2.path):\(s.1.path):/usr/bin:/bin", "HOME": s.0.home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func swiftShimsDisableTheirSandbox() throws {
        let s = try setup()
        #expect(try run(s, "swift build -c release") == "swift build --disable-sandbox -c release")
        #expect(try run(s, "swift test --filter 'a b'") == "swift test --disable-sandbox --filter a b")
        #expect(try run(s, "swift package resolve") == "swift package --disable-sandbox resolve")
        #expect(try run(s, "swift build --disable-sandbox") == "swift build --disable-sandbox")   // not twice
        #expect(try run(s, "swift --version") == "swift --version")
        #expect(try run(s, "swift-build -v") == "swift-build --disable-sandbox -v")
        #expect(try run(s, "swift-test") == "swift-test --disable-sandbox")
        #expect(try run(s, "xcodebuild -scheme X build") ==
                "xcodebuild -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES -scheme X build")
        #expect(try run(s, "xcrun swift build") == "xcrun swift build --disable-sandbox")
        #expect(try run(s, "xcrun --sdk macosx swift-build") == "xcrun --sdk macosx swift-build --disable-sandbox")
        #expect(try run(s, "xcrun xcodebuild -version").hasPrefix("xcrun xcodebuild -IDEPackageSupportDisableManifestSandbox=YES"))
        #expect(try run(s, "xcrun simctl list") == "xcrun simctl list")
    }

    @Test func openShimAsksCollie() throws {
        let s = try setup()
        #expect(try run(s, "open https://example.com") == "collie open https://example.com")
        #expect(try run(s, "open -a Simulator") == "collie open --app Simulator")
        #expect(try run(s, "command -v open") == s.2.appendingPathComponent("open").path)
    }

    /// M4: the user's own .zlogout still runs at logout.
    @Test func userZlogoutRuns() throws {
        let f = try FakeHome(git: false)
        _ = try SandboxLaunch.prepare(f.input(project: f.base), root: f.collie, collie: URL(fileURLWithPath: "/usr/bin/true"))
        try "echo ZLOGOUT-RAN\n".write(to: f.home.appendingPathComponent(".zlogout"), atomically: false, encoding: .utf8)
        var e = SandboxLaunch.environment(["PATH": "/usr/bin:/bin"], id: f.id, root: f.collie, shell: "/bin/zsh", home: f.home)
        e["COLLIE_SHIMS"] = "/nonexistent"
        let p = Process(), pipe = Pipe()
        // an interactive login shell whose ZDOTDIR is still Collie's at exit (zsh reads .zlogout from the current one)
        let input = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-il"]
        p.environment = e.merging(["COLLIE_ZD_PROBE": e["ZDOTDIR"]!]) { $1 }
        p.standardInput = input; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data("ZDOTDIR=$COLLIE_ZD_PROBE; exit\n".utf8)); try input.fileHandleForWriting.close()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(String(decoding: d, as: UTF8.self).contains("ZLOGOUT-RAN"))
    }

    @Test func shimDirIsReadOnlyAndFirstOnPath() throws {
        let f = try FakeHome(git: false)
        let e = SandboxLaunch.environment(["PATH": "/usr/bin:/bin", "ZDOTDIR": "/z"], id: f.id, root: f.collie, shell: "/bin/zsh", home: f.home)
        let bin = SandboxLaunch.dir(f.id, root: f.collie).appendingPathComponent("bin").path
        #expect(e["PATH"] == bin + ":/usr/bin:/bin" && e["HOME"] == f.home.path)
        #expect(e["HISTFILE"] == SandboxLaunch.dir(f.id, root: f.collie).appendingPathComponent("state/history").path)
        #expect(e["ZDOTDIR"]?.hasSuffix("/zsh") == true && e["COLLIE_USER_ZDOTDIR"] == "/z")
        #expect(SandboxLaunch.environment([:], id: f.id, root: f.collie, shell: "/bin/bash", home: f.home)["ZDOTDIR"] == nil)
    }
}

@Suite struct SandboxUsageTests {
    /// The statusline hook of a sandboxed Claude writes into its terminal's `state/usage`; the daemon copies the newest.
    @Test func newestSandboxedRateLimitsCollected() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-su-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let svc = UsageService(dir: root.appendingPathComponent("usage/providers"))
        func put(_ id: String, _ text: String) throws -> URL {
            let d = root.appendingPathComponent("sandbox/\(id)/state/usage")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            let f = d.appendingPathComponent(ClaudeRateLimits.fileName)
            try text.write(to: f, atomically: false, encoding: .utf8)
            return f
        }
        let old = try put("a", #"{"five_hour":{"used_percentage":1}}"#)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        _ = try put("b", #"{"five_hour":{"used_percentage":2}}"#)
        let secret = root.appendingPathComponent("secret.json"); try #"{"auth":"x"}"#.write(to: secret, atomically: false, encoding: .utf8)
        let c = root.appendingPathComponent("sandbox/c/state/usage"); try fm.createDirectory(at: c, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: c.appendingPathComponent(ClaudeRateLimits.fileName), withDestinationURL: secret)   // never followed
        // M1: a FIFO (newer than all) is skipped without blocking the actor
        let fifo = root.appendingPathComponent("sandbox/d/state/usage"); try fm.createDirectory(at: fifo, withIntermediateDirectories: true)
        #expect(mkfifo(fifo.appendingPathComponent(ClaudeRateLimits.fileName).path, 0o600) == 0)
        await svc.collectSandboxed()
        let got = try String(contentsOf: root.appendingPathComponent("usage/\(ClaudeRateLimits.fileName)"), encoding: .utf8)
        #expect(got.contains("\"used_percentage\":2"))
        #expect(UsageService.readSmallRegular(fifo.appendingPathComponent(ClaudeRateLimits.fileName).path) == nil)   // never blocks
        #expect(UsageService.readSmallRegular(c.appendingPathComponent(ClaudeRateLimits.fileName).path) == nil)   // never a link
    }
}

@Suite struct OpenCommandTests {
    let home = URL(fileURLWithPath: "/nonexistent-home")
    func args(_ t: String?, app: String? = nil, cwd: String = "/tmp") throws -> [String] {
        try OpenCommand.arguments(target: t, app: app, cwd: cwd, home: home)
    }

    @Test func urlsAndInstalledAppsOnly() throws {
        #expect(try args("https://example.com/a?b=c") == ["https://example.com/a?b=c"])
        #expect(try args("http://localhost:3000") == ["http://localhost:3000"])
        #expect(try args("mailto:a@b.c") == ["mailto:a@b.c"])
        let sys = "/System/Applications/Calculator.app"
        if FileManager.default.fileExists(atPath: sys) {
            #expect(try args(sys) == [sys])
            #expect(try args(nil, app: "Calculator") == ["-a", sys])
            #expect(try args("https://x.y", app: "Calculator") == ["-a", sys, "https://x.y"])
        }
    }

    @Test func scriptsExecutablesAndDocumentsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Evil.app/Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for n in ["x.command", "x.sh", "x.tool", "doc.html"] { try "echo hi".write(to: dir.appendingPathComponent(n), atomically: false, encoding: .utf8) }
        for t in ["x.command", "x.sh", "x.tool", "./bin", "doc.html", "Evil.app", dir.path, "file:///etc/passwd", "ssh://h",
                  "vscode://x", "x-apple.systempreferences:", "/System/Applications/Calculator.app/Contents/MacOS/Calculator"] {
            #expect(throws: ProtocolError.self, "\(t)") { try args(t, cwd: dir.path) }
        }
        #expect(throws: ProtocolError.self) { try args(nil, app: "Evil", cwd: dir.path) }
        #expect(throws: ProtocolError.self) { try args(nil, app: dir.appendingPathComponent("Evil.app").path) }
        #expect(throws: ProtocolError.self) { try args("x.sh", app: "Calculator", cwd: dir.path) }   // a document in an app
        #expect(throws: ProtocolError.self) { try args(nil) }
    }

    @Test func routerOpensOnlyThroughTheOpener() async throws {
        let seen = OSAllocatedUnfairLockBox()
        try await withDaemon(configure: { c in c.opener = { a throws(ProtocolError) in seen.append(a) } }) { d, p in
            let (id, _) = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, id)
            func open(_ a: [String: JSONValue]) async throws -> Response {
                try await send(p, Request(id: "o", terminalId: id, token: tok, command: "open", args: a, cwd: "/tmp"))
            }
            #expect(try await open(["target": .string("https://example.com")]).ok)
            let bad = try await open(["target": .string("x.command")])
            #expect(!bad.ok && bad.error?.code == .invalidArgs)
            let noAuth = try await send(p, Request(id: "o", terminalId: id, token: "bad", command: "open", args: ["target": .string("https://a.b")]))
            #expect(noAuth.error?.code == .unauthorized)
            #expect(seen.all == [["https://example.com"]])
        }
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [[String]] = []
    func append(_ a: [String]) { lock.lock(); items.append(a); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A sandboxed terminal launched by the daemon, with a fake home (R2): profile on disk, the shell confined, the
/// zsh startup putting the shims first and the history in its own file; a free terminal runs unsandboxed.
@Suite(.serialized) struct SandboxLaunchTests {
    @Test func daemonLaunchesSandboxed() async throws {
        let f = try FakeHome(git: false, socket: false)
        // the root through /tmp (a symlink): the socket rule must still match the resolved path
        let rootPath = "/tmp" + f.collie.path.dropFirst("/private/tmp".count)
        let paths = Paths(root: URL(fileURLWithPath: String(rootPath)))
        var c = testConfig(paths)
        c.sandboxHome = f.home; c.shell = "/bin/zsh"
        try "export FROM_USER_ZSHRC=1\nHISTFILE=$HOME/.zsh_history\n".write(to: f.home.appendingPathComponent(".zshrc"), atomically: false, encoding: .utf8)
        let proj = f.home.appendingPathComponent("code/proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let d = try Daemon(config: c)
        try await d.start()
        do {
            let r = try await send(paths, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                                 args: ["name": .string("S"), "preset": .string("shell"), "cwd": .string(proj.path)]))
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
            let u = UUID(uuidString: id)!
            let profile = SandboxLaunch.profileFile(u, root: paths.root)
            #expect(try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? Int == 0o600)
            let tok = try await tokenOf(d, id)   // the shell started (through sandbox-exec)
            let pty = try #require(await d.process(u))
            try pty.write(Data("echo W=$(echo x > \(AgentLaunch.quote(f.home.appendingPathComponent("Documents/y").path)) 2>/dev/null && echo yes || echo no) P=${path[1]:t2} H=$HISTFILE U=$FROM_USER_ZSHRC Z=${ZDOTDIR:-unset}; echo hi > in-project && echo PW=ok\n".utf8))
            let started = await waitFor(20) { await d.scrollbackText(u).contains("PW=ok") }
            #expect(started)
            let out = await d.scrollbackText(u)
            #expect(out.contains("W=no"), "\(out)")   // confined
            #expect(out.contains("P=\(u.uuidString)/bin"), "\(out)")   // shims first, after path_helper
            #expect(out.contains("H=\(SandboxLaunch.dir(u, root: paths.root).path)/state/history"), "\(out)")
            #expect(out.contains("U=1 Z=unset"), "\(out)")   // the user's .zshrc ran; ZDOTDIR given back
            #expect(FileManager.default.fileExists(atPath: proj.appendingPathComponent("in-project").path))
            // its token reaches the daemon over the socket from inside
            try pty.write(Data("/usr/bin/nc -w 1 -U \"$COLLIE_SOCKET\" </dev/null && echo SOCK=ok\n".utf8))
            let sockOK = await waitFor(20) { await d.scrollbackText(u).contains("SOCK=ok") }
            let after = await d.scrollbackText(u)
            #expect(sockOK, "\(after)")
            _ = tok
            // removing the terminal removes its sandbox files
            _ = try await send(paths, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("S")]))
            #expect(await waitFor(20) { !FileManager.default.fileExists(atPath: profile.path) })
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    @Test func freeTerminalIsNotSandboxed() async throws {
        let f = try FakeHome(git: false, socket: false)
        let paths = Paths(root: f.collie)
        var c = testConfig(paths); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        try await d.start()
        do {
            let r = try await send(paths, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                                 args: ["name": .string("F"), "preset": .string("shell"), "cwd": .string(f.base.path), "sandbox": .string("free")]))
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
            _ = try await tokenOf(d, id)
            #expect(!FileManager.default.fileExists(atPath: SandboxLaunch.profileFile(UUID(uuidString: id)!, root: paths.root).path))
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    @Test func cttyHelperAppliesTheProfile() async throws {
        let f = try FakeHome(git: false)
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/collie-ctty").path
        let proj = f.base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let profile = try f.profile(f.input(project: proj))
        let reg = TerminalRegistry(spillDir: f.base, memoryCapBytes: 1 << 16, runDir: f.base, cttyHelper: helper)
        let rec = TerminalRecord(id: UUID(), name: "A", preset: .shell, command: nil, cwd: f.base.path, isShepherd: false)
        let doc = AgentLaunch.quote(f.home.appendingPathComponent("Documents/x").path)
        let p = try await reg.spawn(rec, launch: LaunchSpec(executable: "/bin/zsh", arguments: ["-fc", "echo tty=$(ps -o tty= -p $$); cat \(doc) || echo DENIED; sleep 5"],
                                                            cwd: f.base.path), sandbox: profile)
        defer { p.terminate() }
        let sb = try #require(await reg.scrollback(rec.id))
        #expect(await waitFor(20) { sb.text(since: 0).text.contains("DENIED") }, "\(sb.text(since: 0).text)")
        #expect(sb.text(since: 0).text.contains("tty=ttys"))
        await reg.remove(rec.id)
    }
}

/// Inner sandboxes off when Collie's applies (Task 1: Seatbelt doesn't nest). Args and settings only: never the real agents.
@Suite struct InnerSandboxTests {
    let collie = URL(fileURLWithPath: "/opt/collie")
    func rec(_ p: Preset, _ c: String? = nil) -> TerminalRecord { TerminalRecord(id: UUID(), name: "A", preset: p, command: c, cwd: "/tmp", isShepherd: false) }

    @Test func claudeSettingsTurnItsSandboxOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("is-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let r = rec(.claude)
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true)
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: AgentLaunch.settingsFile(r.id, in: dir))) as! [String: Any]
        #expect((o["sandbox"] as? [String: Any])?["enabled"] as? Bool == false)
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")   // a free terminal: untouched
        let free = try JSONSerialization.jsonObject(with: Data(contentsOf: AgentLaunch.settingsFile(r.id, in: dir))) as! [String: Any]
        #expect(free["sandbox"] == nil)
    }

    @Test func codexAndCursorFlags() throws {
        let dir = FileManager.default.temporaryDirectory
        let codex = try AgentLaunch.launchSpec(for: rec(.codex), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true)
        #expect(codex.arguments[1].hasPrefix("codex --sandbox danger-full-access -c "))
        let plain = try AgentLaunch.launchSpec(for: rec(.codex), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")
        #expect(!plain.arguments[1].contains("--sandbox"))
        let cursor = try AgentLaunch.launchSpec(for: rec(.custom, "cursor-agent --model x"), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true)
        #expect(cursor.arguments == ["-lc", "cursor-agent --sandbox disabled --model x"])
        let cx = try AgentLaunch.launchSpec(for: rec(.custom, "codex exec hi"), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true)
        #expect(cx.arguments == ["-lc", #"codex -c 'sandbox_mode="danger-full-access"' exec hi"#])
        let own = try AgentLaunch.launchSpec(for: rec(.custom, "cursor-agent --sandbox enabled"), env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true)
        #expect(own.arguments == ["-lc", "cursor-agent --sandbox enabled"])   // the user's own choice
    }
}

/// Review Focus 1, gated (real toolchains, minutes): Task 1's tool matrix under the real profile, through the shims,
/// with a fake home (R2) and no network. Run:
///   COLLIE_SANDBOX_TOOLCHAIN_TESTS=1 swift test --filter SandboxToolchainTests
/// The iOS Simulator destination build needs the real home (Xcode reads platform state there): user checklist.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COLLIE_SANDBOX_TOOLCHAIN_TESTS"] == "1"))
struct SandboxToolchainTests {
    func setup() throws -> (FakeHome, URL, URL, [String: String]) {
        let f = try FakeHome()
        let proj = f.home.appendingPathComponent("code/tool proj")
        try FakeHome.git(["init", "-q"], in: proj)
        let p = try f.profile(f.input(project: proj))
        let bin = SandboxLaunch.dir(f.id, root: f.collie).appendingPathComponent("bin").path
        let env = ["PATH": bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                   "TMPDIR": SandboxInput.darwinDir(_CS_DARWIN_USER_TEMP_DIR).path,
                   "CFFIXED_USER_HOME": f.home.path]   // Foundation's home (getpwuid otherwise: the real one)
        return (f, proj, p, env)
    }
    func check(_ s: (FakeHome, URL, URL, [String: String]), _ script: String) throws {
        let r = try s.0.run(s.2, script, cwd: s.1, env: s.3)
        #expect(r.status == 0, "\(script):\n\(r.out.suffix(3000))")
    }
    func swiftPackage(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sources/Hello"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Hello", platforms: [.macOS(.v13)], targets: [.executableTarget(name: "Hello")])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        try #"print("hello from the sandbox")"#.write(to: dir.appendingPathComponent("Sources/Hello/main.swift"), atomically: false, encoding: .utf8)
    }

    @Test func swiftBuildAndRun() throws {
        let s = try setup(); try swiftPackage(s.1)
        try check(s, "swift build && swift run Hello | grep -q 'hello from the sandbox'")
    }
    /// SwiftPM checks a git dependency out under `.build/checkouts/<dep>` (a nested `.git`): exempt from R17 (R20).
    @Test func swiftGitDependency() throws {
        let s = try setup()
        let dep = s.0.base.appendingPathComponent("dep")
        try FileManager.default.createDirectory(at: dep.appendingPathComponent("Sources/Dep"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Dep\", products: [.library(name: \"Dep\", targets: [\"Dep\"])], targets: [.target(name: \"Dep\")])\n"
            .write(to: dep.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        try "public let dep = 1\n".write(to: dep.appendingPathComponent("Sources/Dep/Dep.swift"), atomically: false, encoding: .utf8)
        try FakeHome.git(["init", "-q"], in: dep); try FakeHome.git(["add", "."], in: dep)
        try FakeHome.git(["commit", "-qm", "d"], in: dep); try FakeHome.git(["tag", "1.0.0"], in: dep)
        try FileManager.default.createDirectory(at: s.1.appendingPathComponent("Sources/Hello"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Hello", platforms: [.macOS(.v13)],
            dependencies: [.package(url: "file://\(dep.path)", from: "1.0.0")],
            targets: [.executableTarget(name: "Hello", dependencies: [.product(name: "Dep", package: "dep")])])
        """.write(to: s.1.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        try "import Dep\nprint(dep)\n".write(to: s.1.appendingPathComponent("Sources/Hello/main.swift"), atomically: false, encoding: .utf8)
        try check(s, "swift build")
    }

    @Test func xcodebuildPackage() throws {
        let s = try setup(); try swiftPackage(s.1)
        try check(s, "xcodebuild -scheme Hello -destination 'platform=macOS' build -quiet")
        try check(s, "xcrun simctl list devices >/dev/null")
    }
    @Test func npmInstallOffline() throws {
        let s = try setup()
        try check(s, "command -v npm >/dev/null || exit 0; mkdir dep && echo '{\"name\":\"dep\",\"version\":\"1.0.0\"}' > dep/package.json && npm init -y >/dev/null && npm install ./dep --offline --no-audit --no-fund >/dev/null && test -e node_modules/dep")
    }
    @Test func pythonVenv() throws {
        let s = try setup()
        try check(s, "python3 -m venv .venv && .venv/bin/python -c 'print(1)' >/dev/null")
    }
    @Test func gitInRepoAndWorktree() throws {
        let s = try setup()
        try check(s, "echo a > a && git add a && git -c user.name=t -c user.email=t@t commit -qm a && git branch b && git tag t && git gc -q")
        let w = try s.0.profile(s.0.input(paddockTerminal: true))
        let r = try s.0.run(w, "echo b > b && git add b && git -c user.name=t -c user.email=t@t commit -qm b && git -c user.name=t -c user.email=t@t rebase -q main", cwd: s.0.paddock, env: s.3)
        #expect(r.status == 0, "\(r.out)")
    }
}
