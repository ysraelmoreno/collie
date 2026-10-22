import Foundation
import Darwin
import OrqProtocol

// Client side of the daemon socket (and the fd helpers the server shares). Lives in OrqCore so the app's
// OrqClient can use it without depending on OrqDaemonKit.

package let maxRequestBytes = 4 * 1024 * 1024

package func makeSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd >= 0 { prepare(fd) }
    return fd
}
/// CLOEXEC (never leak into spawned agents), non-blocking, no SIGPIPE.
package func prepare(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}
package func withAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else {
        throw ProtocolError(code: .invalidArgs, message: "socket path too long (\(bytes.count) bytes, max 103): \(path)")
    }
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes + [0]) }
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}
package func sysError(_ what: String) -> ProtocolError {
    ProtocolError(code: .internal, message: "\(what): \(String(cString: strerror(Darwin.errno)))")
}
/// Write all of `data` to a non-blocking fd, polling until `deadline`. False on failure/timeout.
package func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
    var off = 0
    while off < data.count {
        let n = data.dropFirst(off).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { off += n; continue }
        if n < 0 && Darwin.errno == EINTR { continue }
        guard n < 0, Darwin.errno == EAGAIN else { return false }
        let ms = Int32(max(0, min(1000, deadline.timeIntervalSinceNow * 1000)))
        if deadline.timeIntervalSinceNow <= 0 { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); poll(&p, 1, ms)
    }
    return true
}

public enum UnixSocketClient {
    public static func send(_ req: Request, to path: URL, timeoutSeconds: Double?) async throws(ProtocolError) -> Response {
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        // Own thread, not the GCD pool: an `ask` blocks here for minutes, and many concurrent
        // blocked exchanges would exhaust GCD workers (starving the server's reply queue in-process).
        return try await offPool { try exchange(req, path.path, deadline) }
    }

    /// Connects the non-blocking `fd`, waiting up to `ms()` for an in-progress connect.
    package static func connectSocket(_ fd: Int32, _ path: String, _ ms: () throws -> Int32) throws {
        let timeout = ProtocolError(code: .timeout, message: "timed out waiting for daemon")
        let rc = try withAddr(path) { connect(fd, $0, $1) }
        if rc != 0 {
            switch Darwin.errno {
            case ENOENT, ECONNREFUSED: throw ProtocolError(code: .daemonUnavailable, message: "daemon não está rodando (orqd)")
            case EINPROGRESS, EAGAIN:
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                while true {
                    let pr = poll(&p, 1, try ms())
                    if pr < 0 && Darwin.errno == EINTR { continue }
                    guard pr > 0 else { throw timeout }
                    break
                }
                var soErr: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr == ENOENT || soErr == ECONNREFUSED { throw ProtocolError(code: .daemonUnavailable, message: "daemon não está rodando (orqd)") }
                if soErr != 0 { Darwin.errno = soErr; throw sysError("connect") }
            default: throw sysError("connect")
            }
        }
    }

    /// Runs blocking socket work on its own thread, not the cooperative pool or GCD.
    package static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws(ProtocolError) -> T {
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                Thread { do { c.resume(returning: try body()) } catch { c.resume(throwing: error) } }.start()
            }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }

    private static func exchange(_ req: Request, _ path: String, _ deadline: Date?) throws -> Response {
        var line = try JSONEncoder().encode(req); line.append(10)
        guard line.count <= maxRequestBytes + 1 else { throw ProtocolError(code: .invalidArgs, message: "request too large") }
        let fd = makeSocket()
        guard fd >= 0 else { throw sysError("socket") }
        defer { close(fd) }
        let timeout = ProtocolError(code: .timeout, message: "timed out waiting for daemon")
        func ms() throws -> Int32 {
            guard let d = deadline else { return -1 }
            let left = d.timeIntervalSinceNow
            if left <= 0 { throw timeout }
            return Int32(min(left * 1000 + 1, Double(Int32.max)))
        }

        try connectSocket(fd, path, ms)

        var writeFailure: ProtocolError?
        if !writeAll(fd, line, deadline: deadline ?? .distantFuture) {
            if let d = deadline, d.timeIntervalSinceNow <= 0 { throw timeout }
            writeFailure = sysError("write")      // server may have replied (e.g. error) and closed; try to read it
        }

        var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
        while !buf.contains(10) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&p, 1, try ms())
            if pr == 0 { throw timeout }
            if pr < 0 { if Darwin.errno == EINTR { continue }; throw sysError("poll") }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]) }
            else if n == 0 { break }
            else if Darwin.errno != EAGAIN && Darwin.errno != EINTR { if let w = writeFailure { throw w }; throw sysError("read") }
        }
        guard let nl = buf.firstIndex(of: 10) ?? (buf.isEmpty ? nil : buf.endIndex),
              let resp = try? JSONDecoder().decode(Response.self, from: buf[buf.startIndex..<nl])
        else { if let w = writeFailure { throw w }; throw ProtocolError(code: .internal, message: "malformed response from daemon") }
        return resp
    }
}

private func msLeft(_ d: Date) throws -> Int32 {
    let left = d.timeIntervalSinceNow
    if left <= 0 { throw ProtocolError(code: .timeout, message: "timed out waiting for daemon") }
    return Int32(min(left * 1000 + 1, Double(Int32.max)))
}

/// Client side of a `ui.*` stream (the app, tests): one `StreamFrame` per line both ways. Blocking I/O on own threads.
public final class StreamClient: @unchecked Sendable {
    private let fd: Int32
    private let rlock = NSLock(), wlock = NSLock()
    private var buf = Data()     // rlock

    /// Sends `req` (`ui.attach` / `ui.events`, admin token) and returns the open stream; throws the daemon's refusal.
    public static func open(_ req: Request, path: URL, timeoutSeconds: Double = 10) async throws(ProtocolError) -> StreamClient {
        try await UnixSocketClient.offPool { try StreamClient(req, path.path, Date().addingTimeInterval(timeoutSeconds)) }
    }
    /// Blocking `open`, for callers that run their own socket thread/queue.
    package static func openBlocking(_ req: Request, path: URL, timeoutSeconds: Double = 10) throws -> StreamClient {
        try StreamClient(req, path.path, Date().addingTimeInterval(timeoutSeconds))
    }

    private init(_ req: Request, _ path: String, _ deadline: Date) throws {
        fd = makeSocket()
        guard fd >= 0 else { throw sysError("socket") }
        // No close on throw: every stored property is set, so a throw still runs deinit, which closes `fd`. Closing it
        // here as well closed the number twice; the second close hit whatever another thread had opened in between.
        try UnixSocketClient.connectSocket(fd, path) { try msLeft(deadline) }
        var line = try JSONEncoder().encode(req); line.append(10)
        guard writeAll(fd, line, deadline: deadline) else { throw sysError("write") }
        guard let first = try readLine(deadline),
              let r = try? JSONDecoder().decode(Response.self, from: first) else {
            throw ProtocolError(code: .internal, message: "malformed response from daemon")
        }
        guard r.ok else { throw r.error ?? ProtocolError(code: .internal, message: "stream refused") }
    }
    deinit { Darwin.close(fd) }

    /// Next frame; nil when the daemon closed the stream. Throws `.timeout` after `timeoutSeconds`.
    public func next(timeoutSeconds: Double) async throws(ProtocolError) -> StreamFrame? {
        try await UnixSocketClient.offPool { [self] in try nextBlocking(timeoutSeconds: timeoutSeconds) }
    }
    /// Blocking `next`.
    package func nextBlocking(timeoutSeconds: Double) throws -> StreamFrame? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        return try rlock.withLock {
            guard let l = try readLine(deadline) else { return nil }
            guard let f = try? JSONDecoder().decode(StreamFrame.self, from: l) else {
                throw ProtocolError(code: .internal, message: "malformed frame from daemon")
            }
            return f
        }
    }

    public func send(_ f: StreamFrame, timeoutSeconds: Double = 10) async throws(ProtocolError) {
        try await UnixSocketClient.offPool { [self] in try sendBlocking(f, timeoutSeconds: timeoutSeconds) }
    }
    /// Blocking `send`.
    package func sendBlocking(_ f: StreamFrame, timeoutSeconds: Double = 10) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        try wlock.withLock { guard writeAll(fd, f.line, deadline: deadline) else { throw sysError("write") } }
    }

    /// Ends the stream (the daemon drops the subscription); pending reads return nil. The fd closes on deinit.
    public func close() { shutdown(fd, SHUT_RDWR) }

    private func readLine(_ deadline: Date) throws -> Data? {    // rlock (or init)
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = buf.firstIndex(of: 10) {
                let line = Data(buf[buf.startIndex..<nl]); buf = Data(buf[(nl + 1)...]); return line
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&p, 1, try msLeft(deadline))
            if pr == 0 { throw ProtocolError(code: .timeout, message: "timed out waiting for daemon") }
            if pr < 0 { if Darwin.errno == EINTR { continue }; throw sysError("poll") }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]) }
            else if n == 0 { return nil }
            else if Darwin.errno != EAGAIN && Darwin.errno != EINTR { throw sysError("read") }
        }
    }
}
