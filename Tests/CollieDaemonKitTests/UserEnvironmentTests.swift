import Testing
import Foundation
import os
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct UserEnvironmentTests {
    func tmpHome() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func output(_ pairs: [String], noise: String = "") -> Data {
        Data((noise + "\n__COLLIE_ENV_BEGIN__\0" + pairs.map { $0 + "\0" }.joined()).utf8)
    }
    final class Box: @unchecked Sendable {
        let lock = NSLock(); var calls = 0; var logs: [String] = []
        func call() { lock.lock(); calls += 1; lock.unlock() }
        func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
        var n: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return logs }
    }

    @Test func parsesAfterMarker() {
        let d = Data("x\0__COLLIE_ENV_BEGIN__\0A=1\0".utf8) + Self.output(["PATH=/a:/b", "EQ=x=y", "EMPTY="])
        #expect(UserEnvironment.parse(d, marker: "__COLLIE_ENV_BEGIN__") == ["PATH": "/a:/b", "EQ": "x=y", "EMPTY": ""])
        #expect(UserEnvironment.parse(Data("PATH=/a\0".utf8), marker: "__COLLIE_ENV_BEGIN__") == nil)
        // a truncated last pair (no trailing NUL) is dropped
        #expect(UserEnvironment.parse(Data("__COLLIE_ENV_BEGIN__\0A=1\0B=tru".utf8), marker: "__COLLIE_ENV_BEGIN__") == ["A": "1"])
    }
    @Test func noisyRcParsedAfterMarker() {
        let d = Self.output(["NVM_BIN=/n/bin", "PATH=/n/bin:/usr/bin"], noise: "Welcome!\n\u{1b}]0;title\u{07}\u{1b}[1;32m$ \u{1b}[0m")
        #expect(UserEnvironment.parse(d, marker: "__COLLIE_ENV_BEGIN__") == ["NVM_BIN": "/n/bin", "PATH": "/n/bin:/usr/bin"])
    }
    @Test func hangingRcTimesOut() async throws {
        let box = Box()
        let u = UserEnvironment(shell: "/bin/zsh", home: try tmpHome(), timeout: .milliseconds(200),
                                run: { _, _, _, _ in box.call(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }; box.log("cancelled"); return nil },
                                log: { box.log($0) })
        let t0 = ContinuousClock.now
        let e = await u.current()
        #expect(e == [:])
        // the 200 ms deadline fired (named in the log), well before the 5 s default; wall time gets slack because the
        // parallel suite starves the cooperative pool (2.5 s seen; the capture adds 3 s of kill grace)
        #expect(ContinuousClock.now - t0 < .seconds(8))
        let lines = box.lines.filter { $0 != "cancelled" }
        #expect(lines == ["collied: env: capture failed (zsh timed out after 0.2 seconds)"])
        #expect(await poll { box.lines.contains("cancelled") })   // the hung runner is cancelled, not leaked
        // no retry before 60 s
        #expect(await u.current() == [:] && box.n == 1)
    }
    func poll(_ cond: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<300 { if cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return cond()
    }
    @Test func failureKeepsLastGood() async throws {
        let box = Box(), home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        try Data().write(to: rc)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: rc.path)
        let u = UserEnvironment(shell: "/bin/zsh", home: home, run: { _, _, _, _ in
            box.call(); return box.n == 1 ? Self.output(["PATH=/p", "A=1"]) : nil
        }, log: { box.log($0) })
        #expect(await u.current() == ["PATH": "/p", "A": "1"])
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rc.path)
        #expect(await u.current() == ["PATH": "/p", "A": "1"])   // the recapture failed: the last good one
        #expect(box.n == 2 && box.lines.count == 1)
    }
    @Test func staleServedWhileRefreshing() async throws {
        let box = Box(), gate = UserEnvironmentRaceTests.Gate()
        let u = UserEnvironment(shell: "/bin/zsh", home: try tmpHome(), ttl: .zero, timeout: .seconds(30), run: { _, _, _, _ in
            box.call()
            if box.n == 1 { return Self.output(["PATH=/p", "A=1"]) }
            // the refresh is held until released (10 s cap: a regression fails instead of hanging)
            for _ in 0..<1000 where !gate.isOpen { try? await Task.sleep(for: .milliseconds(10)) }
            return Self.output(["PATH=/p", "A=2"])
        })
        #expect(await u.current() == ["PATH": "/p", "A": "1"])
        #expect(await u.current() == ["PATH": "/p", "A": "1"])   // past ttl: the stale one, without waiting for the held refresh
        #expect(await poll { box.n == 2 })
        gate.set(open: true)
        var latest: [String: String] = [:]
        for _ in 0..<500 { latest = await u.current(); if latest == ["PATH": "/p", "A": "2"] { break }; try? await Task.sleep(for: .milliseconds(10)) }
        #expect(latest == ["PATH": "/p", "A": "2"])
    }
    @Test func inheritedKeysReachCaptureAndAgents() async throws {
        final class Seen: @unchecked Sendable { var env: [String: String] = [:] }
        let seen = Seen(), pi = ProcessInfo.processInfo.environment
        let u = UserEnvironment(shell: "/bin/zsh", home: try tmpHome(), run: { _, _, env, _ in seen.env = env; return Self.output(["PATH=/p"]) })
        _ = await u.current()
        #expect(seen.env["TMPDIR"] == pi["TMPDIR"] && seen.env["SSH_AUTH_SOCK"] == pi["SSH_AUTH_SOCK"])
        #expect(UserEnvironment.merge(user: [:], collie: ["SSH_AUTH_SOCK": "/d", "TMPDIR": "/t"], collieBin: "/o")["SSH_AUTH_SOCK"] == "/d")
        let m = UserEnvironment.merge(user: ["SSH_AUTH_SOCK": "/u", "TMPDIR": "/ut"], collie: ["SSH_AUTH_SOCK": "/d", "TMPDIR": "/t"], collieBin: "/o")
        #expect(m["SSH_AUTH_SOCK"] == "/u" && m["TMPDIR"] == "/ut")
    }
    @Test func sessionVarsDropped() {
        let f = UserEnvironment.filtered(["TMUX": "1", "TMUX_PANE": "1", "TERM": "x", "TERM_PROGRAM": "x", "TERM_PROGRAM_VERSION": "x",
            "TERM_SESSION_ID": "x", "COLORTERM": "x", "SHLVL": "2", "PWD": "/", "OLDPWD": "/", "_": "/bin/env",
            "COLLIE_ENV_CAPTURE": "1", "ITERM_PROFILE": "x", "COLLIE_TOKEN": "t", "__CFBundleIdentifier": "x", "XPC_FLAGS": "x",
            "SSH_AUTH_SOCK": "/s", "PATH": "/a", "NVM_DIR": "/n"])
        #expect(f == ["SSH_AUTH_SOCK": "/s", "PATH": "/a", "NVM_DIR": "/n"])
    }
    @Test func collieKeysWin() {
        let m = UserEnvironment.merge(user: ["COLLIE_TOKEN": "x", "TERM": "screen", "PATH": "/a:/b", "LANG": "pt_BR.UTF-8", "HOME": "/u"],
                                      collie: ["COLLIE_TOKEN": "real", "TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LANG": "C", "HOME": "/h"],
                                      collieBin: "/o")
        #expect(m["COLLIE_TOKEN"] == "real" && m["TERM"] == "xterm-256color" && m["HOME"] == "/h")
        #expect(m["PATH"] == "/o:/a:/b")
        #expect(m["LANG"] == "pt_BR.UTF-8")
        #expect(UserEnvironment.merge(user: ["PATH": "/o:/a"], collie: [:], collieBin: "/o")["PATH"] == "/o:/a")
        #expect(UserEnvironment.merge(user: [:], collie: ["PATH": "/d", "LANG": "C"], collieBin: "/o") == ["PATH": "/o:/d", "LANG": "C"])
    }
    /// launchd gives the daemon no LANG: without one, zsh and readline treat input as ASCII (no "ç", "ã", "é").
    @Test func utf8LocaleWhenNoneIsSet() {
        let m = UserEnvironment.merge(user: [:], collie: ["PATH": "/d"], collieBin: "/o", lang: "pt_BR.UTF-8")
        #expect(m["LANG"] == "pt_BR.UTF-8")
        #expect(UserEnvironment.merge(user: ["LC_ALL": "C"], collie: [:], collieBin: "/o", lang: "pt_BR.UTF-8")["LANG"] == nil)
        #expect(UserEnvironment.merge(user: [:], collie: ["LANG": "C"], collieBin: "/o", lang: "pt_BR.UTF-8")["LANG"] == "C")
        let exists: (String) -> Bool = { ["pt_BR.UTF-8", "en_US.UTF-8"].contains($0) }
        #expect(UserEnvironment.utf8Locale(identifier: "pt_BR", exists: exists) == "pt_BR.UTF-8")
        #expect(UserEnvironment.utf8Locale(identifier: "pt-BR@calendar=gregorian", exists: exists) == "pt_BR.UTF-8")
        #expect(UserEnvironment.utf8Locale(identifier: "xx_YY", exists: exists) == "en_US.UTF-8")
    }
    @Test func cacheReusedAndShared() async throws {
        let box = Box()
        let u = UserEnvironment(shell: "/bin/zsh", home: try tmpHome(), run: { _, _, _, _ in
            box.call(); try? await Task.sleep(for: .milliseconds(100)); return Self.output(["PATH=/u"])
        })
        async let a = u.current(), b = u.current(), c = u.current()
        let r = await [a, b, c]
        #expect(r.allSatisfy { $0 == ["PATH": "/u"] })
        #expect(await u.current() == ["PATH": "/u"])
        #expect(box.n == 1)
    }
    @Test func cacheInvalidatesOnRcChange() async throws {
        let box = Box(), home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        try Data("export A=1\n".utf8).write(to: rc)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: rc.path)
        let u = UserEnvironment(shell: "/bin/zsh", home: home, run: { _, _, _, _ in box.call(); return Self.output(["PATH=/p", "A=1"]) })
        _ = await u.current(); _ = await u.current()
        #expect(box.n == 1)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rc.path)
        _ = await u.current()
        #expect(box.n == 2)
    }
    @Test func rcSymlinkTargetChangeInvalidates() async throws {
        let box = Box(), home = try tmpHome(), store = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: store) }
        let target = store.appendingPathComponent("zshrc")
        try Data("export A=1\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".zshrc"), withDestinationURL: target)
        let u = UserEnvironment(shell: "/bin/zsh", home: home, run: { _, _, _, _ in box.call(); return Self.output(["PATH=/a"]) })
        _ = await u.current(); _ = await u.current()
        #expect(box.n == 1)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        _ = await u.current()
        #expect(box.n == 2)
    }
    @Test func envWithoutPathIsAFailure() async throws {
        let box = Box(), home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        try Data("a\n".utf8).write(to: rc)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: rc.path)
        let bad = OSAllocatedUnfairLock(initialState: false)
        let u = UserEnvironment(shell: "/bin/zsh", home: home, run: { _, _, _, _ in
            box.call(); return bad.withLock { $0 } ? Self.output(["SECRET=hunter2"]) : Self.output(["PATH=/good"])
        }, log: { box.log($0) })
        #expect(await u.current() == ["PATH": "/good"])
        bad.withLock { $0 = true }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rc.path)
        #expect(await u.current() == ["PATH": "/good"])   // last good kept
        #expect(box.lines == ["collied: env: capture failed (no PATH in zsh environment)"])
        #expect(await u.current() == ["PATH": "/good"] && box.n == 2)   // retry only after retryAfter
    }
    @Test func backgroundedChildHoldingStdoutStillCaptures() async throws {
        let dir = try tmpHome()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = dir.appendingPathComponent("fakesh")
        try Data("#!/bin/sh\nprintf 'banner\\n\\n__COLLIE_ENV_BEGIN__\\0'\nprintf 'PATH=/fake\\0A=1\\0'\nsleep 30 &\n".utf8).write(to: sh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        let box = Box()
        let u = UserEnvironment(shell: sh.path, home: dir, timeout: .seconds(1), log: { box.log($0) })
        #expect(await u.current() == ["PATH": "/fake", "A": "1"])
        #expect(box.lines == [])
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func realZshReadsZshrc() async throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("echo oi\nprintf '\\e]0;x\\a'\nexport COLLIE_TEST_FROM_ZSHRC=1\nexport ZSHRC_SAW_CAPTURE=$COLLIE_ENV_CAPTURE\n".utf8)
            .write(to: home.appendingPathComponent(".zshrc"))
        let box = Box()
        let u = UserEnvironment(shell: "/bin/zsh", home: home, timeout: .seconds(20), log: { box.log($0) })
        let e = await u.current()
        #expect(box.lines == [])
        #expect(e["ZSHRC_SAW_CAPTURE"] == "1")   // the rc ran, with the capture flag set; COLLIE_* keys are filtered out
        #expect(e["COLLIE_TEST_FROM_ZSHRC"] == nil && e["HOME"] == home.path)
        let raw = await UserEnvironment.live("/bin/zsh", ["-ilc", UserEnvironment.command], ["HOME": home.path, "PATH": "/usr/bin:/bin"], .seconds(20))
        #expect(UserEnvironment.parse(raw ?? Data(), marker: UserEnvironment.marker)?["COLLIE_TEST_FROM_ZSHRC"] == "1")
    }
}

/// Router-level: which presets get the captured environment.
@Suite struct UserEnvironmentLaunchTests {
    func daemon(_ pairs: [String]) throws -> (Daemon, Paths) {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        var c = testConfig(paths)
        c.captureUserEnv = true; c.envRunner = { _, _, _, _ in UserEnvironmentTests.output(pairs) }
        return (try Daemon(config: c), paths)
    }
    func rec(_ p: Preset, _ c: String? = nil) -> TerminalRecord {
        TerminalRecord(id: UUID(), name: "A", preset: p, command: c, cwd: "/tmp", isShepherd: false)
    }
    @Test func claudeLaunchUsesUserPath() async throws {
        let (d, p) = try daemon(["PATH=/nvm/bin:/usr/bin", "NVM_DIR=/nvm", "TERM=screen"])
        defer { try? FileManager.default.removeItem(at: p.root) }
        for r in [rec(.claude), rec(.codex), rec(.custom, "node x.js")] {
            let s = try await d.router.launchSpec(r, token: "tok", user: await d.router.agentEnv(r))
            #expect(s.environment["PATH"] == "/tmp:/nvm/bin:/usr/bin")
            #expect(s.environment["NVM_DIR"] == "/nvm" && s.environment["TERM"] == "xterm-256color")
            #expect(s.environment["COLLIE_TOKEN"] == "tok")
        }
    }
    @Test func shellPresetUnchanged() async throws {
        let (d, p) = try daemon(["PATH=/nvm/bin:/usr/bin", "NVM_DIR=/nvm"])
        defer { try? FileManager.default.removeItem(at: p.root) }
        let r = rec(.shell)
        let s = try await d.router.launchSpec(r, token: "tok", user: await d.router.agentEnv(r))
        #expect(s.arguments == ["-l"])
        #expect(s.environment["NVM_DIR"] == nil)
        #expect(s.environment["PATH"] == "/tmp:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"))
    }
}

/// A relaunch waiting on the capture must not bring back a terminal killed meanwhile.
@Suite struct UserEnvironmentRaceTests {
    final class Gate: @unchecked Sendable {
        let lock = NSLock(); var started = false, open = false
        var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
        func set(started s: Bool? = nil, open o: Bool? = nil) { lock.lock(); if let s { started = s }; if let o { open = o }; lock.unlock() }
    }
    @Test func relaunchKilledDuringCaptureStaysRemoved() async throws {
        let gate = Gate()
        try await withDaemon(configure: {
            $0.captureUserEnv = true
            $0.envRunner = { _, _, _, _ in
                gate.set(started: true)
                while !gate.isOpen && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return UserEnvironmentTests.output(["PATH=/p", "A=1"])
            }
        }) { d, p in
            // a dead record (the shell preset never captures), then relaunched in place as an agent
            let (id, r0) = try await spawn(d, p, "T", preset: "shell", command: "exit 0")
            try #require(r0.ok)
            let uid = try #require(UUID(uuidString: id))
            for _ in 0..<300 where await d.process(uid)?.isRunning == true { try await Task.sleep(for: .milliseconds(10)) }
            async let relaunch = spawn(d, p, "T", preset: "custom", command: "exec sleep 300")
            // the daemon's warm() already holds the capture at the gate; wait for the relaunch to discard the old
            // process, then a few hops more for it to reach the capture wait
            func discarded() async -> Bool { let l = await d.router.launching.contains("t"); let gone = await d.process(uid) == nil; return l && gone }
            for _ in 0..<300 where !(await discarded()) { try await Task.sleep(for: .milliseconds(10)) }
            let ready = await discarded()
            try #require(gate.isStarted && ready)
            try await Task.sleep(for: .milliseconds(200))
            let k = try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("T")]))
            #expect(k.ok)
            gate.set(open: true)
            let r = try await relaunch.resp
            #expect(!r.ok && r.error?.code == .notFound)
            #expect(await d.router.ws.terminals.isEmpty)
            #expect(await d.process(uid) == nil)
        }
    }
    @Test func relaunchWhosePaddockVanishedDuringCaptureKeepsRecord() async throws {
        try await withDaemon(configure: { $0.captureUserEnv = true; $0.envRunner = { _, _, _, _ in UserEnvironmentTests.output(["PATH=/a"]) } }) { d, p in
            let (id, r0) = try await spawn(d, p, "T", preset: "shell", command: "exit 0")
            try #require(r0.ok)
            let uid = try #require(UUID(uuidString: id))
            var rec = try #require(await d.router.ws.terminals.first { $0.id == uid })
            rec.preset = .custom; rec.paddockId = UUID()   // a paddock that is gone
            await #expect(throws: ProtocolError.self) { _ = try await d.router.launch(rec) }
            #expect(await d.router.ws.terminals.map(\.id) == [uid])
        }
    }
}
