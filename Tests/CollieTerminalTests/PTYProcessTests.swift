import Foundation
import Testing
@testable import CollieTerminal

/// Positive conditions only: 20 s is free when it passes and absorbs a loaded machine running all suites at once.
private func waitUntil(seconds: Int = 20, _ cond: () -> Bool) async -> Bool {
    for _ in 0..<seconds * 20 { if cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return cond()
}

private func spec(_ exe: String, _ args: [String] = [], env: [String: String] = [:], cwd: String = "/tmp") -> LaunchSpec {
    LaunchSpec(executable: exe, arguments: args, environment: env, cwd: cwd)
}

@Suite struct PTYProcessTests {
    @Test func echoesThroughPTY() async throws {
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: spec("/bin/cat"), scrollback: sb)
        defer { p.terminate() }
        try p.write(Data("ping\n".utf8))
        #expect(await waitUntil { sb.text(since: 0).text.contains("ping") })
    }

    @Test func terminateDeliversSighup() async throws {
        let box = Box()
        let p = try PTYProcess(spec: spec("/bin/sleep", ["30"]), scrollback: ScrollbackBuffer(spillURL: nil))
        p.onExit = { box.set($0) }
        p.terminate()
        _ = await waitUntil { box.value != nil }; #expect(box.value == 129)
    }

    @Test func terminateReapsAfterRelease() async throws {
        var pid: pid_t = 0
        weak var weakP: PTYProcess?
        do {
            let p = try PTYProcess(spec: spec("/bin/sleep", ["30"]), scrollback: ScrollbackBuffer(spillURL: nil))
            pid = p.pid; weakP = p
            p.terminate()
        }
        #expect(await waitUntil { kill(pid, 0) == -1 && errno == ESRCH })
        #expect(await waitUntil { weakP == nil || !weakP!.isRunning })
    }

    @Test func onExitSetAfterExitStillFires() async throws {
        let box = Box()
        let p = try PTYProcess(spec: spec("/usr/bin/true"), scrollback: ScrollbackBuffer(spillURL: nil))
        #expect(await waitUntil { !p.isRunning })
        p.onExit = { box.set($0) }
        #expect(box.value == 0)
    }

    /// 16 concurrent spawns; each exit is awaited (the reap drains output before `onExit`), no polling deadlines.
    /// (A process source registered on an already-zombie child still fires: checked, so no missed-exit hang.)
    /// Each child prints its own marker, which must land in its own terminal only: concurrent spawns once shared
    /// `ptsname`'s static buffer and a child could open another spawn's replica.
    @Test(.timeLimit(.minutes(1))) func concurrentSpawnsAllExec() async throws {
        let results = await withTaskGroup(of: (Int, Int32, String).self) { g in
            for i in 0..<16 {
                g.addTask {
                    let sb = ScrollbackBuffer(spillURL: nil)
                    guard let p = try? PTYProcess(spec: spec("/bin/sh", ["-c", "echo END-\(i)."]), scrollback: sb) else { return (i, -1, "") }
                    let code: Int32 = await withCheckedContinuation { c in p.onExit = { c.resume(returning: $0) } }
                    return (i, code, sb.text(since: 0).text)
                }
            }
            return await g.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 16)
        let bad = results.filter { i, code, out in code != 0 || out.components(separatedBy: "END-").count != 2 || !out.contains("END-\(i).") }
        #expect(bad.isEmpty, "\(bad)")
    }

    /// A child that writes and exits at once must never lose its output. The replica the parent opened (to set the
    /// size) used to be closed right after spawn; when that close landed while the child was already in exit (draining
    /// its terminal), macOS flushed the child's output and the master read EOF: exit 0, empty scrollback.
    /// Background-QoS spawners make the parent slow to reach that close; the old code lost about 1 in 4,000 here, so
    /// these 3,200 spawns caught it in about half the runs. `COLLIE_STRESS=<seconds>` turns this into the long soak run.
    @Test(.timeLimit(.minutes(5))) func immediateExitNeverLosesOutput() async throws {
        let soak = ProcessInfo.processInfo.environment["COLLIE_STRESS"].flatMap(Double.init)
        let start = Date()
        let fds = { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }, fdsBefore = fds()
        let tally = Tally()
        let done = DispatchGroup()
        for t in 0..<16 {
            done.enter()
            let th = Thread {
                var n = 0
                repeat {
                    n += 1
                    let sb = ScrollbackBuffer(spillURL: nil), exited = DispatchSemaphore(value: 0), box = Box()
                    let marker = "END-\(t)-\(n)."
                    guard let p = try? PTYProcess(spec: spec("/bin/echo", [marker]), scrollback: sb) else { tally.add("spawn failed"); continue }
                    p.onExit = { box.set($0); exited.signal() }
                    // bounded: a child stuck in exit must fail the test, not hang the suite
                    if exited.wait(timeout: .now() + 20) == .timedOut { tally.add("hang pid \(p.pid)"); continue }
                    let out = sb.text(since: 0).text
                    tally.add(box.value == 0 && out.contains(marker) ? nil : "\(box.value ?? -1):\(out)")
                } while soak.map { Date().timeIntervalSince(start) < $0 } ?? (n < 200)
                done.leave()
            }
            th.qualityOfService = .background
            th.start()
        }
        await withCheckedContinuation { c in done.notify(queue: .global()) { c.resume() } }
        let (total, lost) = tally.result
        let fdsAfter = fds()
        if soak != nil { print("PTY soak: lost \(lost.count) of \(total) in \(Int(Date().timeIntervalSince(start))) s, open fds \(fdsBefore) -> \(fdsAfter)") }
        #expect(lost.isEmpty, "lost \(lost.count) of \(total): \(lost.prefix(5))")
        // loose: other suites open fds concurrently; a per-spawn leak would be thousands
        #expect(fdsAfter - fdsBefore < 64, "open fds \(fdsBefore) -> \(fdsAfter)")
    }

    /// The leader exits while a background job still holds the replica: exit is seen via the process source (not
    /// master EOF), so onExit must not wait for the job, and the leader's output must still land.
    @Test(.timeLimit(.minutes(1))) func leaderExitWithBackgroundJobHoldingPty() async throws {
        let sb = ScrollbackBuffer(spillURL: nil), box = Box()
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "sleep 30 & echo X-$!-END"]), scrollback: sb)
        p.onExit = { box.set($0) }
        let start = Date()
        #expect(await waitUntil { box.value != nil })
        #expect(Date().timeIntervalSince(start) < 10, "onExit waited for the background job")
        let out = sb.text(since: 0).text
        #expect(out.contains("X-"), "\(out)")
        if let r = out.range(of: #"X-(\d+)-END"#, options: .regularExpression),
           let bg = pid_t(out[r].dropFirst(2).dropLast(4)) { kill(bg, SIGKILL) }
    }

    /// Hold-until-reap path, deterministically: the output queue is blocked right after spawn, so the child writes and
    /// enters exit with its output still unread by the master. The output must survive and onExit must fire.
    @Test(.timeLimit(.minutes(1))) func outputUnreadAtExitSurvives() async throws {
        let sb = ScrollbackBuffer(spillURL: nil), box = Box()
        let p = try PTYProcess(spec: spec("/bin/echo", ["HELD-END"]), scrollback: sb)
        p.serialized { usleep(300_000) }
        p.onExit = { box.set($0) }
        let start = Date()
        #expect(await waitUntil { box.value != nil })
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(box.value == 0)
        #expect(sb.text(since: 0).text.contains("HELD-END"), "\(sb.text(since: 0).text)")
    }

    /// The exit source registers after the child entered exit with unread output (the child waits in exit for the
    /// drain): kevent says ESRCH and libdispatch fires the exit handler at once, ahead of the read source. A blocking
    /// waitpid there deadlocked the output queue (full-suite hang: 3 terminals stuck in reap → wait4).
    @Test(.timeLimit(.minutes(1))) func exitSeenBeforeOutputReadDoesNotDeadlock() async throws {
        let sb = ScrollbackBuffer(spillURL: nil), box = Box()
        let q = DispatchQueue(label: "collie.pty.test")
        q.suspend() // sources can't register until the child is exiting
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "echo LATE-END"]), scrollback: sb,
                               writeStall: .seconds(2), queue: q)
        p.onExit = { box.set($0) }
        usleep(300_000)
        q.resume()
        #expect(await waitUntil { box.value != nil }, "reap deadlocked")
        #expect(box.value == 0)
        #expect(sb.text(since: 0).text.contains("LATE-END"), "\(sb.text(since: 0).text)")
    }

    @Test func childDoesNotInheritSiblingMaster() async throws {
        let a = try PTYProcess(spec: spec("/bin/cat"), scrollback: ScrollbackBuffer(spillURL: nil))
        defer { a.terminate() }
        let sb = ScrollbackBuffer(spillURL: nil)
        let b = try PTYProcess(spec: spec("/bin/sh", ["-c", "for i in 3 4 5 6 7 8 9; do [ -e /dev/fd/$i ] && echo LEAK$i; done; echo END"]), scrollback: sb)
        defer { b.terminate() }
        #expect(await waitUntil { sb.text(since: 0).text.contains("END") })
        #expect(!sb.text(since: 0).text.contains("LEAK"), "\(sb.text(since: 0).text)")
    }

    @Test func childHasControllingTty() async throws {
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "/usr/bin/tty; /bin/stty size; echo END"]), scrollback: sb)
        defer { p.terminate() }
        #expect(await waitUntil { sb.text(since: 0).text.contains("END") })
        let t = sb.text(since: 0).text
        #expect(t.contains("/dev/ttys") && t.contains("40 120"), "\(t)")
    }

    @Test func writeAfterExitThrows() async throws {
        let box = Box()
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "exit 0"]), scrollback: ScrollbackBuffer(spillURL: nil))
        p.onExit = { box.set($0) }
        #expect(await waitUntil { box.value != nil })
        #expect(throws: PTYError.self) { try p.write(Data("x".utf8)) }
    }

    @Test func reportsExitCode() async throws {
        let sb = ScrollbackBuffer(spillURL: nil)
        let box = Box()
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "exit 7"]), scrollback: sb)
        p.onExit = { box.set($0) }
        defer { p.terminate() }
        #expect(await waitUntil { box.value == 7 })
        #expect(await waitUntil { !p.isRunning })
    }

    @Test func passesEnvironmentAndCwd() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("collie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let real = String(cString: realpath(dir, nil))
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: spec("/bin/sh", ["-c", "echo $COLLIE_TEST:$(pwd)"], env: ["COLLIE_TEST": "ok"], cwd: dir), scrollback: sb)
        defer { p.terminate() }
        #expect(await waitUntil { sb.text(since: 0).text.contains("ok:\(real)") })
    }
}

private final class Box: @unchecked Sendable {
    private let l = NSLock(); private var v: Int32?
    func set(_ x: Int32) { l.lock(); v = x; l.unlock() }
    var value: Int32? { l.lock(); defer { l.unlock() }; return v }
}

private final class Tally: @unchecked Sendable {
    private let l = NSLock(); private var total = 0, lost: [String] = []
    /// nil = output arrived intact
    func add(_ failure: String?) { l.lock(); total += 1; if let failure { lost.append(failure) }; l.unlock() }
    var result: (Int, [String]) { l.lock(); defer { l.unlock() }; return (total, lost) }
}
