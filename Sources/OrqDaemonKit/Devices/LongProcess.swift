import Foundation
import os
import OrqProtocol

/// A child that runs until stopped (`adb logcat`, the scrcpy server), in its own process group like `BoundedProcess`:
/// stdin `/dev/null` (or a pipe fed by `write`), stdout delivered line by line (a line over 64 KiB is cut there) or in binary chunks on a reader thread,
/// stderr dropped.
/// A pidfile under `<runDir>/terminals` lets a restarted daemon kill the group if this one crashes; the leader is in
/// `BoundedProcess`'s live set, so `adminOnly` refuses its descendants. `onExit` gets the exit code (128+signal) once the
/// leader is reaped and its stdout drained.
final class LongProcess: Sendable {
    let pid: pid_t
    private let id = UUID()
    private let runDir: URL
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let input: Input?

    /// The write end of the child's stdin; an `NSLock`, not an unfair lock, since writes block. Closed once the leader is reaped.
    private final class Input: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        func write(_ data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            var off = 0
            while off < data.count && fd >= 0 {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, data.count - off) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return fd >= 0
        }
        func close() { lock.lock(); defer { lock.unlock() }; if fd >= 0 { Darwin.close(fd); fd = -1 } }
    }

    static let lineCap = 64 * 1024

    convenience init(executable: URL, args: [String], env: [String: String], runDir: URL,
                     onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws(ProtocolError) {
        try self.init(executable: executable, args: args, env: env, runDir: runDir, drain: { Self.readLines($0, onLine) }, onExit: onExit)
    }

    /// Same, with stdout handed out as it comes, in chunks of up to 64 KiB (binary output: `axe stream-video`).
    /// `stdin`: the child reads a pipe fed by `write` instead of `/dev/null` (an MCP server).
    convenience init(executable: URL, args: [String], env: [String: String], runDir: URL, stdin: Bool = false,
                     onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws(ProtocolError) {
        try self.init(executable: executable, args: args, env: env, runDir: runDir, stdin: stdin,
                      drain: { Self.readData($0, onData) }, onExit: onExit)
    }

    /// `drain` runs on the reader thread: reads stdout to EOF and closes it.
    private init(executable: URL, args: [String], env: [String: String], runDir: URL, stdin: Bool = false,
                 drain: @escaping @Sendable (Int32) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws(ProtocolError) {
        self.runDir = runDir
        var o: [Int32] = [0, 0]
        guard pipe(&o) == 0 else { throw ProtocolError(code: .internal, message: "pipe: \(errno)") }
        var i: [Int32] = [-1, -1]
        if stdin {
            guard pipe(&i) == 0 else { close(o[0]); close(o[1]); throw ProtocolError(code: .internal, message: "pipe: \(errno)") }
            _ = fcntl(i[1], F_SETNOSIGPIPE, 1)   // a dead child is a failed write, not a daemon killed by SIGPIPE
        }
        for fd in o + i where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var fa: posix_spawn_file_actions_t? ; posix_spawn_file_actions_init(&fa)
        var at: posix_spawnattr_t? ; posix_spawnattr_init(&at)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at) }
        if stdin { posix_spawn_file_actions_adddup2(&fa, i[0], 0) } else { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&fa, o[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&fa, "/")
        posix_spawnattr_setpgroup(&at, 0)
        // default dispositions and no blocked signals, like `PTYProcess`: orqd ignores SIGTERM, which a child would inherit
        // and then only die by `terminate`'s KILL (never sent if the daemon exits first)
        var defaults = sigset_t(), empty = sigset_t()
        sigfillset(&defaults); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&at, &defaults)
        posix_spawnattr_setsigmask(&at, &empty)
        posix_spawnattr_setflags(&at, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = ([executable.path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable.path, &fa, &at, argv, envp)
        close(o[1]); if stdin { close(i[0]) }
        guard rc == 0 else {
            close(o[0]); if stdin { close(i[1]) }
            throw ProtocolError(code: .internal, message: "cannot launch \(executable.path): \(String(cString: strerror(rc)))")
        }
        pid = child
        let input = stdin ? Input(i[1]) : nil
        self.input = input
        BoundedProcess.track(child)
        do { try OrphanReaper.record(pid: child, terminal: id, in: runDir) } catch {
            // without a pidfile a daemon crash would orphan the group for good: refuse to run it
            kill(-child, SIGKILL)
            var s: Int32 = 0; while waitpid(child, &s, 0) < 0 && errno == EINTR {}
            BoundedProcess.untrack(child); close(o[0]); input?.close()
            throw ProtocolError(code: .internal, message: "cannot record pidfile: \(error.localizedDescription)")
        }
        let fd = o[0], drained = DispatchSemaphore(value: 0)
        Thread { drain(fd); drained.signal() }.start()
        let id = id, leader = child
        Thread {
            var s: Int32 = 0; while waitpid(leader, &s, 0) < 0 && errno == EINTR {}
            BoundedProcess.untrack(leader)   // reaped: the pid may be reused
            OrphanReaper.forget(terminal: id, in: runDir, ifPid: leader)
            // ponytail: a holder that escaped the group keeps the pipe open; its reader thread and fd are leaked after 1 s
            _ = drained.wait(timeout: .now() + 1)
            onExit((s & 0x7f) == 0 ? (s >> 8) & 0xff : 128 + (s & 0x7f))
            input?.close()   // last: a writer stuck on a pipe an escaped holder keeps open must not delay onExit
        }.start()
    }

    /// Blocking: reads `fd` to EOF, handing out lines without their `\n` (and `\r`); closes `fd` at EOF.
    private static func readLines(_ fd: Int32, _ onLine: (String) -> Void) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024), line: [UInt8] = [], skipping = false
        func emit() {
            if line.last == 13 { line.removeLast() }
            onLine(String(decoding: line, as: UTF8.self)); line.removeAll(keepingCapacity: true)
        }
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var chunk = buf[0..<n]
            while !chunk.isEmpty {
                let nl = chunk.firstIndex(of: 10)
                let piece = chunk[chunk.startIndex..<(nl ?? chunk.endIndex)]
                if !skipping {
                    line.append(contentsOf: piece.prefix(lineCap - line.count))
                    if line.count >= lineCap && nl == nil { emit(); skipping = true }   // cut: the rest of it is dropped
                }
                guard let nl else { break }
                if skipping { skipping = false } else { emit() }
                chunk = chunk[(nl + 1)...]
            }
        }
        if !line.isEmpty { emit() }
        close(fd)
    }

    /// Blocking: reads `fd` to EOF in chunks of up to 64 KiB; closes `fd` at EOF.
    private static func readData(_ fd: Int32, _ onData: (Data) -> Void) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            onData(Data(buf[0..<n]))
        }
        close(fd)
    }

    /// Blocking (call off the cooperative pool): writes all of `data` to the child's stdin; false if it is gone or has no pipe.
    func write(_ data: Data) -> Bool { input?.write(data) ?? false }

    /// SIGTERM to the group, SIGKILL 1 s later if any of it is left; drops the pidfile. Idempotent, never blocks.
    func terminate() {
        guard stopped.withLock({ was in defer { was = true }; return !was }) else { return }
        OrphanReaper.forget(terminal: id, in: runDir, ifPid: pid)
        let pid = pid
        kill(-pid, SIGTERM)
        // ponytail: if the whole group is gone and a new process became leader of a group with this id within 1 s it gets
        // the KILL; same window `BoundedProcess` accepts
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) } }
    }
}
