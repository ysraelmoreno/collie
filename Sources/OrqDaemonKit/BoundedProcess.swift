import Foundation
import os
import OrqCore
import OrqProtocol

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var truncated: Bool
    /// Raw stdout (`stdout` is lossy UTF-8): for binary output such as a PNG.
    var stdoutData = Data()
}

/// Runs a child in its own process group, off the cooperative pool, draining stdout/stderr
/// concurrently (each capped at `cap`). One deadline covers the leader's exit and the drains reaching EOF;
/// past it the whole group gets SIGTERM, then SIGKILL, and `.timeout` is thrown. Processes that left the
/// group (setsid) are out of reach. `salvage` may accept the output read so far at the deadline (a holder kept the
/// pipes open after the answer was complete): the result is then returned instead of `.timeout`.
enum BoundedProcess {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var over = false
        let cap: Int
        init(cap: Int) { self.cap = cap }
        func drain(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                lock.lock()
                let room = cap - data.count
                if Int(n) > room { over = true }
                data.append(contentsOf: buf[0..<min(Int(n), room)])
                lock.unlock()
            }
        }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var truncated: Bool { lock.lock(); defer { lock.unlock() }; return over }
    }

    private final class Status: @unchecked Sendable { var value: Int32 = 0 }

    /// Leaders spawned and not yet reaped: their descendants (git hooks, usage providers) run agent-writable code,
    /// so `adminOnly` refuses them like managed terminals.
    private static let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    static func livePids() -> Set<pid_t> { live.withLock { $0 } }
    /// Other daemon-run leaders (`LongProcess`) join the same set.
    static func track(_ pid: pid_t) { live.withLock { _ = $0.insert(pid) } }
    static func untrack(_ pid: pid_t) { live.withLock { _ = $0.remove(pid) } }

    static func run(executable: URL, args: [String], in dir: URL, env: [String: String], timeout: Duration,
                    cap: Int = 1 << 20, salvage: (@Sendable (Data) -> Bool)? = nil) async throws(ProtocolError) -> ProcessResult {
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await UnixSocketClient.offPool {
            var o: [Int32] = [0, 0], e: [Int32] = [0, 0]
            guard pipe(&o) == 0 else { throw ProtocolError(code: .internal, message: "pipe: \(errno)") }
            guard pipe(&e) == 0 else { close(o[0]); close(o[1]); throw ProtocolError(code: .internal, message: "pipe: \(errno)") }
            for fd in o + e { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            var fa: posix_spawn_file_actions_t? ; posix_spawn_file_actions_init(&fa)
            var at: posix_spawnattr_t? ; posix_spawnattr_init(&at)
            defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at) }
            posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&fa, o[1], 1)
            posix_spawn_file_actions_adddup2(&fa, e[1], 2)
            posix_spawn_file_actions_addchdir_np(&fa, dir.path)
            posix_spawnattr_setpgroup(&at, 0)
            posix_spawnattr_setflags(&at, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = ([executable.path] + args).map { strdup($0) } + [nil]
            let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            let rc = posix_spawn(&pid, executable.path, &fa, &at, argv, envp)
            let child = pid
            if rc == 0 { track(child) }
            close(o[1]); close(e[1])
            guard rc == 0 else {
                close(o[0]); close(e[0])
                throw ProtocolError(code: .internal, message: "cannot launch \(executable.path): \(String(cString: strerror(rc)))")
            }
            let so = Sink(cap: cap), se = Sink(cap: cap), group = DispatchGroup()
            for (sink, fd) in [(so, o[0]), (se, e[0])] {
                group.enter()
                Thread { sink.drain(fd); group.leave() }.start()
            }
            let exited = DispatchSemaphore(value: 0), st = Status()
            Thread {
                var s: Int32 = 0; while waitpid(child, &s, 0) < 0 && errno == EINTR {}
                untrack(child)   // reaped: the pid may be reused
                st.value = s; exited.signal()
            }.start()
            // One deadline covers the leader's exit AND the drains (a backgrounded grandchild can keep the pipes open).
            let deadline = DispatchTime.now() + secs
            let leaderDone = exited.wait(timeout: deadline) == .success
            let drained = leaderDone && group.wait(timeout: deadline) == .success
            let timedOut = !drained
            var drainsDone = drained
            if timedOut {
                kill(-pid, SIGTERM)
                drainsDone = group.wait(timeout: .now() + 1) == .success
                if !leaderDone { _ = exited.wait(timeout: .now() + 0.1) }
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }   // also reaps any grandchild that survived the leader
                if !leaderDone { exited.wait() }
                if !drainsDone { drainsDone = group.wait(timeout: .now() + 2) == .success }
            }
            // ponytail: a holder that escaped the group (setsid) is out of reach; its drain thread and read fd are leaked
            // rather than closed (closing an fd under a blocked read risks fd reuse).
            if drainsDone { close(o[0]); close(e[0]) }
            if timedOut, salvage?(so.bytes) != true { throw ProtocolError(code: .timeout, message: "\(executable.lastPathComponent) timed out") }
            let s = st.value
            let code: Int32 = (s & 0x7f) == 0 ? (s >> 8) & 0xff : 128 + (s & 0x7f)   // WIFEXITED / signaled
            return ProcessResult(status: code, stdout: so.text, stderr: se.text, truncated: so.truncated || se.truncated,
                                 stdoutData: so.bytes)
        }
    }
}
