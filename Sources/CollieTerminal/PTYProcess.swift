import Foundation
import Darwin

public struct LaunchSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String
    public var cols: UInt16 = 120
    public var rows: UInt16 = 40
    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:],
                cwd: String, cols: UInt16 = 120, rows: UInt16 = 40) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.cwd = cwd; self.cols = cols; self.rows = rows
    }
    /// The same command run through `collie-ctty` at `helper`, which makes the PTY its controlling terminal first.
    public func throughControllingTerminal(_ helper: String) -> LaunchSpec {
        var s = self
        s.arguments = [executable] + arguments; s.executable = helper
        return s
    }
}

/// `stalled`: the reader did not accept input before the write deadline (bytes already written stay written).
public enum PTYError: Error, Equatable { case spawnFailed(errno: Int32), closed, stalled }

public final class PTYProcess: @unchecked Sendable {
    private let scrollback: ScrollbackBuffer
    private let queue: DispatchQueue // one per process
    private let lock = NSLock()
    private var master: Int32
    private var replica: Int32 // guarded by ioLock once spawned
    private let ioLock = NSLock()
    private var closed = false
    private var running = true
    private var exitCode: Int32?
    private var lastOutput: ContinuousClock.Instant?
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private var _onOutput: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?
    public let pid: pid_t
    private let writeStall: Duration

    public var isRunning: Bool { lock.withLock { running } }
    public var lastOutputAt: ContinuousClock.Instant? { lock.withLock { lastOutput } }
    public var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onOutput } } set { lock.withLock { _onOutput = newValue } }
    }
    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set {
            let done = lock.withLock { _onExit = newValue; return exitCode }
            if let done, let newValue { newValue(done) } // exited before the handler was set
        }
    }

    public convenience init(spec: LaunchSpec, scrollback: ScrollbackBuffer, writeStall: Duration = .seconds(2)) throws {
        try self.init(spec: spec, scrollback: scrollback, writeStall: writeStall, queue: DispatchQueue(label: "collie.pty"))
    }

    /// `queue`: tests pass a suspended one to hold the sources' registration until the child is already exiting.
    init(spec: LaunchSpec, scrollback: ScrollbackBuffer, writeStall: Duration, queue: DispatchQueue) throws {
        self.scrollback = scrollback; self.writeStall = writeStall; self.queue = queue
        // posix_spawn instead of forkpty: no fork in a multithreaded process (libc atfork handlers
        // such as libnotify's crashed under concurrent spawns), no Swift code between fork and exec.
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0 else { throw PTYError.spawnFailed(errno: errno) }
        // ptsname_r, not ptsname: ptsname's static buffer is shared by concurrent spawns, so a child could open another
        // terminal's replica (its output went there, and its own terminal stayed silent)
        var sn = [CChar](repeating: 0, count: 128)
        guard grantpt(fd) == 0, unlockpt(fd) == 0, ptsname_r(fd, &sn, sn.count) == 0 else {
            let e = errno; close(fd); throw PTYError.spawnFailed(errno: e)
        }
        let slave = String(cString: sn)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var ws = winsize(ws_row: spec.rows, ws_col: spec.cols, ws_xpixel: 0, ws_ypixel: 0)
        // size must be set on an open slave (a size set before the first slave open is reset).
        // The parent keeps this replica open until the child is reaped and the master drained: the exiting child
        // (session leader) waits in exit for its unread output to drain, and if the last replica close lands then,
        // macOS flushes that output and the master reads EOF (an immediate-exit child lost all its output).
        let sfd = open(slave, O_RDWR | O_NOCTTY | O_CLOEXEC)
        if sfd >= 0 { _ = ioctl(sfd, TIOCSWINSZ, &ws) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var acts: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&acts)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&acts) }
        var defaults = sigset_t(), empty = sigset_t()
        sigfillset(&defaults); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // On macOS this open does not make the replica the new session's controlling terminal: commands that need one
        // (SIGWINCH on resize, ^C to the foreground job) are wrapped by `LaunchSpec.throughControllingTerminal`.
        posix_spawn_file_actions_addopen(&acts, 0, slave, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&acts, 0, 1)
        posix_spawn_file_actions_adddup2(&acts, 0, 2)
        posix_spawn_file_actions_addchdir_np(&acts, spec.cwd)

        let args = [spec.executable] + spec.arguments
        let env = spec.environment.map { "\($0.key)=\($0.value)" }
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var p: pid_t = 0
        let rc = posix_spawn(&p, spec.executable, &acts, &attr, argv, envp)
        guard rc == 0 else { close(fd); if sfd >= 0 { close(sfd) }; throw PTYError.spawnFailed(errno: rc) }
        pid = p; master = fd; replica = sfd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.drain() }
        readSource = rs
        let ps = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: queue)
        // strong self: keeps the process alive until reaped; reap() breaks the cycle
        ps.setEventHandler { self.reap() }
        procSource = ps
        rs.resume(); ps.resume()
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let data = Data(bytes: buf, count: n) // owned copy
                lock.withLock { lastOutput = .now }
                scrollback.append(data)
                onOutput?(data)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                readSource?.cancel() // EOF / EIO
                return
            } else if errno == EAGAIN { return }
        }
    }

    private func reap() {
        // Never block this queue in waitpid: the exit event can fire while the child still waits in exit for its unread
        // tty output (an exit source registered late gets ESRCH, and libdispatch fires the handler at once), and only
        // this queue drains that output, so a blocking waitpid here deadlocked.
        var status: Int32 = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            drain()
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid || (w == -1 && errno != EINTR) { return finish(w, status) }
            if ContinuousClock.now > deadline { break }
            usleep(1000)
        }
        // ponytail: not reapable after 5 s of draining. Release a child held by the tty (output still unread is lost)
        // and wait off the queue; the read source keeps draining meanwhile.
        ioLock.withLock { if replica >= 0 { close(replica); replica = -1 } }
        DispatchQueue.global().async {
            var st: Int32 = 0, w: pid_t
            repeat { w = waitpid(self.pid, &st, 0) } while w == -1 && errno == EINTR
            self.queue.async { self.finish(w, st) }
        }
    }

    private func finish(_ w: pid_t, _ status: Int32) {
        drain() // flush trailing output
        scrollback.closeSpill() // memory tail stays readable for `check` until the terminal is removed
        // if waitpid failed (e.g. ECHILD) still clean up so the self-retain cycle breaks
        let code: Int32 = w != pid ? 255 : (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        let cb = lock.withLock { running = false; exitCode = code; return _onExit }
        procSource?.cancel(); procSource = nil
        closeMaster()
        cb?(code)
    }

    private func closeMaster() {
        // runs on the serial queue (same as drain), so no read races the close
        readSource?.cancel(); readSource = nil
        // replica before master: with the opposite order a later posix_openpt spun forever in grantpt (seen in
        // soaks). Likely cause (inferred from a sample stack, not kernel source): the master's close freed the pty
        // number while this replica still referenced the old /dev/ttysN, and the reuse of that number spun
        ioLock.withLock { closed = true; if replica >= 0 { close(replica) }; close(master) }
    }

    public func write(_ data: Data) throws {
        var off = 0
        let deadline = ContinuousClock.now + writeStall
        try ioLock.withLock {
            guard !closed else { throw PTYError.closed }
            try data.withUnsafeBytes { raw in
                while off < raw.count {
                    let n = Darwin.write(master, raw.baseAddress! + off, raw.count - off)
                    if n > 0 { off += n }
                    else if errno == EAGAIN || errno == EINTR {
                        if ContinuousClock.now > deadline { throw PTYError.stalled }
                        usleep(1000)
                    } else { throw PTYError.closed }
                }
            }
        }
    }

    /// Runs `body` on the output queue: no output is read (scrollback append + `onOutput`) while it runs.
    public func serialized(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    public func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioLock.withLock { if !closed { _ = ioctl(master, TIOCSWINSZ, &ws) } }
    }

    public func terminate() {
        guard isRunning else { return }
        kill(-pid, SIGHUP); kill(pid, SIGHUP)
        let pid = pid
        queue.asyncAfter(deadline: .now() + 2) {
            if self.isRunning { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        }
    }
}
