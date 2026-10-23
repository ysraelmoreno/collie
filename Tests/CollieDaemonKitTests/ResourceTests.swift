import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let collieBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie").path
private let cttyBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie-ctty").path

/// Open fds of this process whose path lies under `root` (spill logs). Immune to other tests running in parallel.
private func fdsUnder(_ root: URL) -> Int {
    var n = 0, buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for fd in 0..<getdtablesize() where fcntl(fd, F_GETPATH, &buf) == 0 {
        if String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains(root.lastPathComponent) { n += 1 }
    }
    return n
}
private func logs(_ root: URL) -> [String] {
    FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".log") } ?? []
}
private func kill(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Response {
    try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string(name)]))
}

@Suite struct ResourceTests {
    /// Start lifts the fd soft limit (launchd's 256) to the hard limit, capped at OPEN_MAX; it never lowers it.
    /// Lowered to 4096 first, not 256: other suites share this process and must not run out of fds meanwhile.
    @Test func startRaisesFileLimit() {
        var orig = rlimit(); getrlimit(RLIMIT_NOFILE, &orig)
        // restore, but never below the raised target: parallel suites may already hold more fds than the original
        defer { var r = orig; r.rlim_cur = max(orig.rlim_cur, min(orig.rlim_max, rlim_t(OPEN_MAX))); setrlimit(RLIMIT_NOFILE, &r) }
        let want = min(orig.rlim_max, rlim_t(OPEN_MAX))
        var low = orig; low.rlim_cur = min(4096, want)
        setrlimit(RLIMIT_NOFILE, &low)
        Daemon.raiseFileLimit()
        var rl = rlimit(); getrlimit(RLIMIT_NOFILE, &rl)
        #expect(rl.rlim_cur == want, "\(rl.rlim_cur), want \(want) (max \(orig.rlim_max))")
        var high = orig; setrlimit(RLIMIT_NOFILE, &high)   // already above the target (a shell's ulimit): kept
        Daemon.raiseFileLimit()
        getrlimit(RLIMIT_NOFILE, &rl)
        #expect(rl.rlim_cur == max(orig.rlim_cur, want))
    }

    /// I2/I3: spawn+kill cycles release spill fds, registry/asks entries and spill files.
    /// (Whole-process fd growth is measured on a real collied in ColliedProcessTests: other suites share this process.)
    @Test func spawnKillCyclesDoNotLeak() async throws {
        try await withDaemon { d, p in
            let base = await d.counts()
            for _ in 0..<30 {
                let s = try await spawn(d, p, "T", preset: "custom", command: "exec sleep 300"), k = try await kill(d, p, "T")
                #expect(s.resp.ok && k.ok)
            }
            let c = await d.counts()
            #expect(c.procs == base.procs && c.buffers == base.buffers && c.targets == base.targets, "\(base) -> \(c)")
            #expect(await waitFor(10) { fdsUnder(p.root) == 0 }, "spill fds open: \(fdsUnder(p.root))")
            #expect(logs(p.root).isEmpty, "\(logs(p.root))")
        }
    }

    /// I2: the spill fd closes when the process exits; `check` still reads the memory tail.
    @Test func exitClosesSpillButKeepsTail() async throws {
        try await withDaemon { d, p in
            let t = try await spawn(d, p, "E", preset: "custom", command: "echo hello-tail")
            let id = UUID(uuidString: t.id)!
            #expect(await waitFor(5) { await d.process(id)?.isRunning == false })
            #expect(await waitFor(5) { fdsUnder(p.root) == 0 })
            #expect(await d.scrollbackText(id).contains("hello-tail"))
            #expect(logs(p.root).count == 1)   // file stays until the terminal is removed
            #expect(try await kill(d, p, "E").ok)
            #expect(logs(p.root).isEmpty)
        }
    }

    /// I3 + M2: start sweeps orphaned spill logs and hook files, and locks the root down to 0700.
    @Test func startSweepsStaleFilesAndLocksRoot() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), ws = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let log = paths.workspaceDir(ws).appendingPathComponent("terminals/\(UUID().uuidString)-1.log")
        let hook = paths.root.appendingPathComponent("hooks/\(UUID().uuidString).claude.json")
        for f in [log, hook] {
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: f)
        }
        chmod(paths.root.path, 0o755)
        let d = try Daemon(config: testConfig(paths, ws))
        try await d.start()
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(!FileManager.default.fileExists(atPath: hook.path))
        var st = stat(); stat(paths.root.path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        await d.stop()
    }

    /// Final-review I1: daemon-spawned bounded processes (usage providers, git hooks) are agent-writable code;
    /// presenting the admin token from one is refused like from a managed terminal.
    @Test func adminFromUsageProviderIsRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "A"); _ = try await spawn(d, p, "B")
            let dir = p.root.appendingPathComponent("usage/providers"), out = p.root.appendingPathComponent("provider.out")
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) { try FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            let script = "COLLIE_SOCKET='\(p.socket.path)' COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(collieBin)' admin leash A B "
                + "> '\(out.path)' 2>&1; echo RC=$? >> '\(out.path)'; printf '{\"p\":1}'"
            let prov = UsageProvider(id: "evil", label: "Evil", enabled: true, command: ["/bin/sh", "-c", script], timeoutSeconds: 30,
                                     parse: .json, windows: [.init(label: "5h", usedPercent: "/p", resetsAt: nil)])
            try JSONEncoder().encode(prov).write(to: dir.appendingPathComponent("evil.json"))
            let r = try await UnixSocketClient.send(Request(id: "u", token: d.adminToken, command: "ui.usage"), to: p.socket, timeoutSeconds: 40)
            #expect(r.ok, "\(r)")
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            #expect(text.contains("the admin token can't be used from inside a Collie terminal") && text.contains("RC=1"), "\(text)")
            let snap = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snap.result)).connections.isEmpty)
        }
    }

    /// I4: an agent that reads admin.token still can't run admin commands from inside its terminal.
    @Test func adminFromManagedTerminalIsRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "B")
            let cmd = "COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(collieBin)' admin leash A B; echo RC=$?; exec sleep 300"
            let a = try await spawn(d, p, "A", preset: "custom", command: cmd)
            let id = UUID(uuidString: a.id)!
            #expect(await waitFor(10) { await d.scrollbackText(id).contains("RC=") })
            let text = await d.scrollbackText(id)
            #expect(text.contains("the admin token can't be used from inside a Collie terminal") && text.contains("RC=1"), "\(text)")
            // the test process is not a terminal descendant: still allowed
            let ok = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")]))
            #expect(ok.ok, "\(ok)")
        }
    }

    /// Terminals start through collie-ctty in their own session: a grandchild, and a child that double-forked away
    /// (reparented to launchd, same session), are refused the admin token; the terminal's own token still works.
    @Test func adminFromTerminalSessionIsRefused() async throws {
        try await withDaemon(configure: { $0.cttyHelper = URL(fileURLWithPath: cttyBin) }) { d, p in
            _ = try await spawn(d, p, "B")
            let script = p.root.appendingPathComponent("agent.sh")
            try """
            A='\(collieBin)'; export COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)'
            /bin/sh -c '"$0" admin leash A B; echo RC1=$?' "$A"
            ( ( sleep 1; "$A" admin leash A B; echo RC2=$? ) & )
            sleep 4; "$A" list; echo RC3=$?
            """.write(to: script, atomically: true, encoding: .utf8)
            let a = try await spawn(d, p, "A", preset: "custom", command: "/bin/sh '\(script.path)'; exec sleep 300")
            let id = UUID(uuidString: a.id)!
            #expect(await waitFor(15) { await d.scrollbackText(id).contains("RC3=") })
            let text = await d.scrollbackText(id)
            #expect(text.contains("RC1=1") && text.contains("RC2=1") && text.contains("RC3=0"), "\(text)")
            let snap = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snap.result)).connections.isEmpty)
        }
    }

    /// A peer the daemon can't identify (pid unknown, or gone before the check) is refused: fail closed.
    @Test func adminFromUnidentifiedPeerIsRefused() async throws {
        try await withDaemon { d, _ in
            let req = Request(id: "x", token: d.adminToken, command: "admin.list")
            try await d.router.adminOnly(req, peer: getpid())
            let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try gone.run(); gone.waitUntilExit()
            for pid: pid_t in [0, gone.processIdentifier] {
                do { try await d.router.adminOnly(req, peer: pid); Issue.record("admin allowed from peer \(pid)") }
                catch { #expect((error as? ProtocolError)?.code == .unauthorized, "\(pid)") }
            }
        }
    }

    /// The CLI inside a Collie terminal without its own token never falls back to the admin token file.
    @Test func cliInsideTerminalDoesNotReadAdminFile() throws {
        let tok = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        try "x".write(to: tok, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tok) }
        let pr = Process(), err = Pipe()
        pr.executableURL = URL(fileURLWithPath: collieBin); pr.arguments = ["admin", "leash", "A", "B"]
        pr.environment = ["COLLIE_TERMINAL_ID": UUID().uuidString, "COLLIE_SOCKET": "/nonexistent/collie.sock",
                          "COLLIE_ADMIN_TOKEN_FILE": tok.path]
        pr.standardError = err; pr.standardOutput = Pipe()
        try pr.run(); pr.waitUntilExit()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(pr.terminationStatus != 0 && text.contains("the admin token can't be used from inside a Collie terminal"), "\(text)")
    }
}
