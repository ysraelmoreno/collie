import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Whether this process may apply a sandbox (inside an agent's sandboxed shell it may not: Seatbelt does not nest).
private let sandboxApplies: Bool = {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}()

private func sh(_ dir: URL, _ args: String...) async throws {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
}

/// A repo whose own config plants a clean/smudge filter for every file: it touches `sentinel` when git runs it.
private func plantedRepo() async throws -> (repo: URL, sentinel: URL) {
    let repo = try await makeRepo(), sentinel = repo.deletingLastPathComponent().appendingPathComponent("sentinel-\(UUID().uuidString.prefix(8))")
    try await sh(repo, "config", "filter.evil.x.clean", "touch '\(sentinel.path)'; cat")
    try await sh(repo, "config", "filter.evil.x.smudge", "touch '\(sentinel.path)'; cat")
    try "* filter=evil.x\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    try "new\n".write(to: repo.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
    return (repo, sentinel)
}

@Suite(.serialized) struct WorkLoopSandboxTests {
    /// Finding 2: the loop's git never runs a filter the repo's own config defines (an agent can write .git/config).
    @Test func loopGitRunsNoPlantedFilter() async throws {
        let control = try await plantedRepo()
        _ = try await GitRunner.run(["add", "-A"], in: control.repo)
        #expect(FileManager.default.fileExists(atPath: control.sentinel.path), "control: plain git runs the planted filter")

        let x = try await plantedRepo()
        for a in [["add", "-A"], ["status", "--porcelain"], ["diff", "--cached", "--binary", "HEAD"], ["checkout", "-q", "-f", "main"], ["reset", "-q", "--hard", "HEAD"]] {
            let r = try await RouterLoopHost.loopGit(a, in: x.repo, profile: nil)
            #expect(r.status == 0, "\(a): \(r.stderr)")
        }
        #expect(!FileManager.default.fileExists(atPath: x.sentinel.path))
    }

    /// Finding 6: a check gets only the toolchain's keys; sandboxed, the loop's shims lead PATH.
    @Test func checkEnvIsAllowListed() {
        let user = ["PATH": "/usr/bin:/bin", "HOME": "/Users/u", "LANG": "pt_BR.UTF-8", "DEVELOPER_DIR": "/x",
                    "GH_TOKEN": "ghp_x", "GITHUB_TOKEN": "y", "SSH_AUTH_SOCK": "/s", "COLLIE_TOKEN": "t", "AWS_SECRET_ACCESS_KEY": "k"]
        let plain = RouterLoopHost.checkEnv(user, sandbox: nil)
        #expect(Set(plain.keys) == ["PATH", "HOME", "LANG", "DEVELOPER_DIR"])
        let id = UUID(), root = URL(fileURLWithPath: "/tmp/r"), home = URL(fileURLWithPath: "/tmp/h")
        let boxed = RouterLoopHost.checkEnv(user, sandbox: (id, root, "/bin/zsh", home))
        #expect(boxed["PATH"]?.hasPrefix(SandboxLaunch.dir(id, root: root).appendingPathComponent("bin").path + ":") == true)
        #expect(boxed["HOME"] == home.path && !boxed.keys.contains { $0.hasPrefix("COLLIE_") })
        #expect(boxed["GH_TOKEN"] == nil && boxed["SSH_AUTH_SOCK"] == nil && boxed["AWS_SECRET_ACCESS_KEY"] == nil)
    }

    /// Findings 1–2: terminals sandboxed (`sandboxHome`) and the loop's profile gone: check and git throw, never run bare.
    @Test func missingProfileFailsClosed() async throws {
        let f = try FakeHome(git: false, socket: false)
        var c = testConfig(Paths(root: f.collie)); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        let repo = try await makeRepo()
        let host = RouterLoopHost(router: d.router, starter: UUID(), root: f.collie, work: UUID(), sandbox: (f.home, "/bin/zsh"))
        await #expect(throws: ProtocolError.self) { try await host.check("true", in: repo, timeout: .seconds(5)) }
        await #expect(throws: ProtocolError.self) { try await host.git(["status"], in: repo) }
    }

    /// Finding 11: the real loop profile applies: the check writes in the paddock, not in the home nor reads its keys.
    @Test(.enabled(if: sandboxApplies, "sandbox-exec is refused here (a nested sandbox): run outside an agent's terminal"))
    func checkRunsUnderTheLoopProfile() async throws {
        let f = try FakeHome(git: true, socket: false)
        var c = testConfig(Paths(root: f.collie)); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        let work = UUID()
        let paddock = Paddock(id: UUID(), name: "p", repoRoot: f.repo.path, path: f.paddock.path, branch: "collie/p", baseBranch: "main")
        _ = try await d.router.prepareLoopSandbox(work, paddock: paddock)
        let host = RouterLoopHost(router: d.router, starter: UUID(), root: f.collie, work: work, sandbox: (f.home, "/bin/zsh"))
        let inside = try await host.check("echo x > in.txt", in: f.paddock, timeout: .seconds(20))
        let home = try await host.check("echo x > '\(f.home.path)/Documents/loop.txt'", in: f.paddock, timeout: .seconds(20))
        let key = try await host.check("cat '\(f.home.path)/.ssh/id_ed25519'", in: f.paddock, timeout: .seconds(20))
        #expect(inside.status == 0, "\(inside.stderr)")
        #expect(home.status != 0 && !FileManager.default.fileExists(atPath: f.home.appendingPathComponent("Documents/loop.txt").path))
        #expect(key.status != 0)
    }

    /// Terminals sandboxed: a starter without a sandbox (free) is refused before anything runs.
    @Test(.enabled(if: sandboxApplies, "spawning under a FakeHome sandbox needs sandbox-exec: run outside an agent's terminal"))
    func runRefusesAFreeStarter() async throws {
        let f = try FakeHome(git: true, socket: false)
        var c = testConfig(Paths(root: f.collie)); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        try await d.start()
        defer { Task { await d.stop() } }
        let r = try await send(Paths(root: f.collie), Request(id: "s", token: d.adminToken, command: "admin.spawn",
                               args: ["name": .string("S"), "preset": .string("shell"), "cwd": .string(f.repo.path),
                                      "shepherd": .bool(true), "sandbox": .string("free")]), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
        let tok = try await tokenOf(d, id)
        _ = try await send(Paths(root: f.collie), Request(id: "w", terminalId: id, token: tok, command: "work.start", args: ["title": .string("W")]))
        let run = try await send(Paths(root: f.collie), Request(id: "r", terminalId: id, token: tok, command: "work.run", args: ["max": .number(1)]))
        #expect(run.error?.code == .invalidArgs && run.error?.message.contains("without a sandbox") == true, "\(run)")
    }
}
