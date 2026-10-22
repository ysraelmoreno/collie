import Testing
import Foundation
import Darwin
import OrqCore
import OrqProtocol
import OrqDaemonKit

// <pkg>/Tests/OrqIntegrationTests/this.swift -> <pkg>/.build/debug/orqd (swift test builds all products)
private let orqdURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/orqd")

private func tmpRoot() -> URL { URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))") }
private func mode(_ u: URL) -> mode_t { var st = stat(); stat(u.path, &st); return st.st_mode & 0o777 }
private func launch(_ root: URL) throws -> Process {
    let p = Process()
    p.executableURL = orqdURL
    p.arguments = ["--root", root.path]
    p.environment = ProcessInfo.processInfo.environment.merging(["ORQ_USER_ENV": "off"]) { $1 }
    try p.run()
    return p
}

@Suite struct OrqdProcessTests {
    @Test func orqdStartsAndStopsOnSigterm() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = root.appendingPathComponent("run/orqd.sock"), tokenFile = root.appendingPathComponent("admin.token")
        let proc = try launch(root)
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        #expect(await waitFor(3) { FileManager.default.fileExists(atPath: tokenFile.path) && FileManager.default.fileExists(atPath: paths.path) })
        #expect(mode(paths) == 0o600 && mode(tokenFile) == 0o600)
        let token = try String(contentsOf: tokenFile, encoding: .utf8)
        let r = try await UnixSocketClient.send(Request(id: "s", token: token, command: "admin.spawn", args: [
            "name": .string("S"), "preset": .string("custom"), "cwd": .string("/tmp"),
            "command": .string("echo $$ > \(root.path)/child.pid; trap '' HUP; exec sleep 300")]), to: paths, timeoutSeconds: 5)
        #expect(r.ok)
        #expect(await waitFor(3) { FileManager.default.fileExists(atPath: root.appendingPathComponent("child.pid").path) })
        try await Task.sleep(for: .milliseconds(300)) // let the trap/exec take effect
        let pid = pid_t(try String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(kill(pid, 0) == 0)
        kill(proc.processIdentifier, SIGTERM)
        #expect(await waitFor(3) { !proc.isRunning })
        #expect(proc.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.path))
        #expect(await waitFor(1) { kill(pid, 0) == -1 && errno == ESRCH })
    }

    @Test func secondOrqdFailsAndKeepsToken() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tokenFile = root.appendingPathComponent("admin.token")
        let first = try launch(root)
        defer { if first.isRunning { kill(first.processIdentifier, SIGKILL) } }
        #expect(await waitFor(3) { FileManager.default.fileExists(atPath: tokenFile.path) })
        let before = try String(contentsOf: tokenFile, encoding: .utf8)
        let second = try launch(root)
        #expect(await waitFor(3) { !second.isRunning })
        #expect(second.terminationStatus != 0)
        let after = try String(contentsOf: tokenFile, encoding: .utf8)
        #expect(after == before)
        #expect(first.isRunning)
        kill(first.processIdentifier, SIGTERM)
        #expect(await waitFor(3) { !first.isRunning })
    }

    /// I1 + I5 (Review Focus #4): SIGKILLed orqd leaves a stale socket, `orq` reports it (exit 3),
    /// a restarted orqd serves again and same-name respawns replace the reloaded records.
    @Test func crashRestartServesAgain() async throws {
        let root = tmpRoot()
        let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
        let pids = root.appendingPathComponent("pids")
        var procs: [Process] = []
        defer {
            for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            for l in ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n") { if let n = pid_t(l) { kill(n, SIGKILL) } }
            try? FileManager.default.removeItem(at: root)
        }
        func start() async throws -> String {
            let old = try? String(contentsOf: tf, encoding: .utf8)
            procs.append(try launch(root))
            try #require(await waitFor(5) { (try? String(contentsOf: tf, encoding: .utf8)).map { $0 != old } ?? false })
            return try String(contentsOf: tf, encoding: .utf8)
        }
        func spawn(_ admin: String, _ name: String) async throws -> (id: String, token: String) {
            let tok = root.appendingPathComponent("\(name).tok"); try? FileManager.default.removeItem(at: tok)
            let r = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
                "name": .string(name), "preset": .string("custom"), "cwd": .string("/tmp"),
                "command": .string("echo $$ >> '\(pids.path)'; echo $ORQ_TOKEN > '\(tok.path)'; exec sleep 300")]), to: sock, timeoutSeconds: 5)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "spawn \(r)") }
            try #require(await waitFor(5) { ((try? String(contentsOf: tok, encoding: .utf8)) ?? "").count > 60 })
            return (id, try String(contentsOf: tok, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func connect(_ admin: String) async throws -> Response {
            try await UnixSocketClient.send(Request(id: "c", token: admin, command: "admin.connect", args: ["a": .string("A"), "b": .string("B")]), to: sock, timeoutSeconds: 5)
        }

        var admin = try await start()
        let a = try await spawn(admin, "A"); _ = try await spawn(admin, "B")
        #expect(try await connect(admin).ok)
        kill(procs[0].processIdentifier, SIGKILL); procs[0].waitUntilExit()

        #expect(FileManager.default.fileExists(atPath: sock.path))
        let env = ["ORQ_SOCKET": sock.path, "ORQ_TERMINAL_ID": a.id, "ORQ_TOKEN": a.token]
        let down = try await runOrq(["list"], env: env)
        #expect(down.status == 3 && down.err.contains("orqd"), "\(down)")

        admin = try await start()
        let a2 = try await spawn(admin, "A"); _ = try await spawn(admin, "B")
        #expect(a2.id == a.id)
        let c = try await connect(admin)
        #expect(c.ok, "\(c)")
        let l = try await runOrq(["list"], env: ["ORQ_SOCKET": sock.path, "ORQ_TERMINAL_ID": a2.id, "ORQ_TOKEN": a2.token])
        #expect(l.status == 0 && l.out == "B\tcustom\trunning\n", "\(l)")
    }

    /// A SIGKILLed orqd leaves its terminal groups running; the next orqd kills them and shows the record stopped.
    @Test func restartKillsOrphanGroups() async throws {
        let root = tmpRoot()
        let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
        let pidFile = root.appendingPathComponent("child.pid")
        var procs: [Process] = []
        defer {
            for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            if let n = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { kill(-n, SIGKILL); kill(n, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        func start() async throws -> String {
            let old = try? String(contentsOf: tf, encoding: .utf8)
            procs.append(try launch(root))
            try #require(await waitFor(5) { (try? String(contentsOf: tf, encoding: .utf8)).map { $0 != old } ?? false })
            try #require(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) })
            return try String(contentsOf: tf, encoding: .utf8)
        }
        func send(_ admin: String, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
            try await UnixSocketClient.send(Request(id: "x", token: admin, command: cmd, args: args), to: sock, timeoutSeconds: 5)
        }
        var admin = try await start()
        let r = try await send(admin, "admin.spawn", ["name": .string("O"), "preset": .string("custom"), "cwd": .string("/tmp"),
            "command": .string("echo $$ > '\(pidFile.path)'; trap '' HUP; while :; do sleep 1; done")])
        #expect(r.ok)
        try #require(await waitFor(5) { FileManager.default.fileExists(atPath: pidFile.path) })
        try await Task.sleep(for: .milliseconds(300))
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        kill(procs[0].processIdentifier, SIGKILL); procs[0].waitUntilExit()
        #expect(kill(pid, 0) == 0)

        admin = try await start()
        #expect(await waitFor(3) { kill(pid, 0) == -1 && errno == ESRCH })
        // the record survived as stopped: restart relaunches it (a running one would be refused)
        let again = try await send(admin, "admin.restart", ["name": .string("O")])
        #expect(again.ok, "\(again)")
        let live = try await send(admin, "admin.restart", ["name": .string("O")])
        #expect(live.error?.code == .invalidArgs)
    }

    /// The common orphan shape: the shell leader is gone (daemon dead, so no exit handler ran) while a HUP-ignoring child lives on in its pgid.
    @Test func reaperKillsGroupWhoseLeaderDied() async throws {
        let root = tmpRoot()
        let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
        let childFile = root.appendingPathComponent("child.pid")
        let pidDir = root.appendingPathComponent("run/terminals"), flag = root.appendingPathComponent("alive")
        var procs: [Process] = []
        var child: pid_t = 0
        defer {
            for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            if child > 0 { kill(child, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        func start() async throws -> String {
            let old = try? String(contentsOf: tf, encoding: .utf8)
            procs.append(try launch(root))
            try #require(await waitFor(5) { (try? String(contentsOf: tf, encoding: .utf8)).map { $0 != old } ?? false })
            try #require(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) })
            return try String(contentsOf: tf, encoding: .utf8)
        }
        func send(_ admin: String, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
            try await UnixSocketClient.send(Request(id: "x", token: admin, command: cmd, args: args), to: sock, timeoutSeconds: 5)
        }
        var admin = try await start()
        try "".write(to: flag, atomically: true, encoding: .utf8)
        let r = try await send(admin, "admin.spawn", ["name": .string("L"), "preset": .string("custom"), "cwd": .string("/tmp"),
            "command": .string("(trap '' HUP; exec sleep 300) & echo $! > '\(childFile.path)'; while [ -e '\(flag.path)' ]; do sleep 0.2; done")])
        #expect(r.ok)
        try #require(await waitFor(5) { FileManager.default.fileExists(atPath: childFile.path) })
        try await Task.sleep(for: .milliseconds(300))
        child = pid_t(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let pf = try #require(try FileManager.default.contentsOfDirectory(at: pidDir, includingPropertiesForKeys: nil).first)
        let leader = pid_t(try String(contentsOf: pf, encoding: .utf8))!
        kill(procs[0].processIdentifier, SIGKILL); procs[0].waitUntilExit()
        try FileManager.default.removeItem(at: flag)   // the leader (not the daemon) now exits; the child ignores HUP
        try #require(await waitFor(5) { kill(leader, 0) == -1 && errno == ESRCH })
        #expect(kill(child, 0) == 0)

        admin = try await start()
        #expect(await waitFor(3) { kill(child, 0) == -1 && errno == ESRCH })
    }

    /// I2: 30 spawn+kill cycles must not grow orqd's open fds (was 9 -> 40).
    @Test func spawnKillCyclesKeepDaemonFdsFlat() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let proc = try launch(root)
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGTERM); proc.waitUntilExit() } }
        let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
        try #require(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) && FileManager.default.fileExists(atPath: tf.path) })
        let admin = try String(contentsOf: tf, encoding: .utf8)
        func send(_ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
            try await UnixSocketClient.send(Request(id: "x", token: admin, command: cmd, args: args), to: sock, timeoutSeconds: 5)
        }
        // warm-up cycle so lazily created runtime fds are in the baseline
        _ = try await send("admin.spawn", ["name": .string("W"), "preset": .string("custom"), "cwd": .string("/tmp"), "command": .string("exec sleep 300")])
        _ = try await send("admin.kill", ["target": .string("W")])
        try await Task.sleep(for: .milliseconds(500))
        let fd0 = fdCount(proc.processIdentifier)
        for _ in 0..<30 {
            let s = try await send("admin.spawn", ["name": .string("T"), "preset": .string("custom"), "cwd": .string("/tmp"), "command": .string("exec sleep 300")])
            let k = try await send("admin.kill", ["target": .string("T")])
            #expect(s.ok && k.ok)
        }
        #expect(await waitFor(10) { fdCount(proc.processIdentifier) <= fd0 + 3 }, "orqd fds \(fd0) -> \(fdCount(proc.processIdentifier))")
    }

    /// C1: orqd started by bare name via PATH from an unrelated cwd must still point hooks/PATH at the real `orq`.
    @Test func orqPathIsAbsoluteWhenLaunchedViaPATH() async throws {
        let root = tmpRoot(), cwd = tmpRoot(), stub = tmpRoot()
        defer { for u in [root, cwd, stub] { try? FileManager.default.removeItem(at: u) } }
        for u in [cwd, stub] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        // SHELL stub: records the PATH the daemon injected, never runs a real claude
        let out = stub.appendingPathComponent("path.out"), shell = stub.appendingPathComponent("fakeshell")
        try "#!/bin/sh\nprintf '%s' \"$PATH\" > '\(out.path)'\nexec sleep 300\n".write(to: shell, atomically: true, encoding: .utf8)
        chmod(shell.path, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["orqd", "--root", root.path]
        p.environment = ["PATH": orqdURL.deletingLastPathComponent().path + ":/usr/bin:/bin", "SHELL": shell.path, "HOME": NSHomeDirectory(),
                         "ORQ_USER_ENV": "off"]
        p.currentDirectoryURL = cwd
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGTERM); p.waitUntilExit() } }
        let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
        try #require(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) && FileManager.default.fileExists(atPath: tf.path) })
        let admin = try String(contentsOf: tf, encoding: .utf8)
        let r = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
            "name": .string("C"), "preset": .string("claude"), "cwd": .string("/tmp"), "command": .string("claude")]), to: sock, timeoutSeconds: 5)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("spawn \(r)"); return }
        let hook = root.appendingPathComponent("hooks/\(id).claude.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hook)) as! [String: Any]
        let cmd = ((((json["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
        let realOrq = realPath(orqURL.path)
        #expect(cmd == "'\(realOrq)' hook claude-stop")
        try #require(await waitFor(5) { ((try? String(contentsOf: out, encoding: .utf8)) ?? "").count > 0 })
        let entries = try String(contentsOf: out, encoding: .utf8).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect(entries.first == realPath(orqURL.deletingLastPathComponent().path))
        #expect(entries.allSatisfy { $0.hasPrefix("/") }, "relative PATH entry: \(entries)")
        #expect(!entries.contains(cwd.path) && !entries.contains(realPath(cwd.path)), "cwd in PATH: \(entries)")
        let spills = { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("workspaces").path))
            .map { $0.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("workspaces/\($0)/terminals").path)) ?? [] } } ?? [] }
        #expect(spills().count == 1)
        let k = try await UnixSocketClient.send(Request(id: "k", token: admin, command: "admin.kill", args: ["target": .string("C")]), to: sock, timeoutSeconds: 5)
        #expect(k.ok)
        // I3: kill removes the hook settings file and the spill log
        #expect(!FileManager.default.fileExists(atPath: hook.path))
        #expect(spills().isEmpty, "spill left: \(spills())")
    }

    /// C1: orqd without a sibling `orq` refuses to start.
    @Test func orqdFailsFastWithoutOrq() async throws {
        let dir = tmpRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lone = dir.appendingPathComponent("orqd")
        try FileManager.default.copyItem(at: orqdURL, to: lone)
        let p = Process(); p.executableURL = lone; p.arguments = ["--root", dir.appendingPathComponent("root").path]
        let err = Pipe(); p.standardError = err
        try p.run()
        let done = await waitFor(5) { !p.isRunning }
        if !done { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        #expect(done && p.terminationStatus == 1)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("orq"))
    }
}

func fdCount(_ pid: pid_t) -> Int {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    return used > 0 ? Int(used) / MemoryLayout<proc_fdinfo>.stride : -1
}

func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}
