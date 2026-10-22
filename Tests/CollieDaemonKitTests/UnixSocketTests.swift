import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func tmpSock() -> URL {
    URL(fileURLWithPath: "/tmp/colliet-\(UUID().uuidString.prefix(8))/s.sock")
}
private func rawAddr(_ path: String) -> sockaddr_un {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    return a
}
private let echo: @Sendable (Request) async -> Response = { Response(id: $0.id, ok: true, result: .string($0.command)) }

@Suite struct UnixSocketTests {
    @Test func roundTripsOneRequest() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); defer { s.stop() }
        let r = try await UnixSocketClient.send(Request(id: "a", command: "list"), to: p, timeoutSeconds: 5)
        #expect(r.ok && r.id == "a" && r.result == .string("list"))
        var st = stat(); stat(p.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        stat(p.deletingLastPathComponent().path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func removesStaleSocket() throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = rawAddr(p.path)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(rc == 0); close(fd)
        #expect(FileManager.default.fileExists(atPath: p.path))
        let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); s.stop()
    }

    @Test func refusesSecondDaemon() throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); defer { s.stop() }
        #expect(throws: (any Error).self) { try UnixSocketServer(path: p, handler: echo).start() }
    }

    @Test func clientReportsDaemonUnavailable() async {
        do { _ = try await UnixSocketClient.send(Request(id: "x", command: "list"), to: tmpSock(), timeoutSeconds: 1); Issue.record("no throw") }
        catch { #expect(error.code == .daemonUnavailable) }
    }

    @Test func clientTimesOut() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }
        let s = UnixSocketServer(path: p) { r in try? await Task.sleep(for: .seconds(20)); return Response(id: r.id, ok: true) }
        try s.start(); defer { s.stop() }
        let t0 = Date()
        do { _ = try await UnixSocketClient.send(Request(id: "x", command: "list"), to: p, timeoutSeconds: 0.3); Issue.record("no throw") }
        catch { #expect(error.code == .timeout) }
        #expect(Date().timeIntervalSince(t0) < 10)   // well under the handler's 20 s: the client gave up on its own
    }

    @Test func serverHandlesConcurrentClients() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); defer { s.stop() }
        let ids = try await withThrowingTaskGroup(of: String.self) { g in
            for i in 0..<50 { g.addTask { try await UnixSocketClient.send(Request(id: "id\(i)", command: "c"), to: p, timeoutSeconds: 10).id } }
            var out = Set<String>(); for try await id in g { out.insert(id) }; return out
        }
        #expect(ids == Set((0..<50).map { "id\($0)" }))
    }

    @Test func rejectsGarbageAndOversize() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); defer { s.stop() }
        func raw(_ d: Data) throws -> Response {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
            var a = rawAddr(p.path)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            var off = 0
            while off < d.count { let n = d.dropFirst(off).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; if n <= 0 { break }; off += n }
            var buf = Data(); var b = [UInt8](repeating: 0, count: 4096)
            while !buf.contains(10) { let n = read(fd, &b, 4096); if n <= 0 { break }; buf.append(contentsOf: b[0..<n]) }
            return try JSONDecoder().decode(Response.self, from: buf)
        }
        let g = try raw(Data("not json\n".utf8))
        #expect(!g.ok && g.error?.code == .invalidArgs && g.id == "")
        let big = try raw(Data(repeating: 65, count: 4 * 1024 * 1024 + 10))
        #expect(big.error?.code == .invalidArgs && big.error?.message == "request too large")
    }

    @Test func clientReportsRequestTooLarge() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start(); defer { s.stop() }
        let req = Request(id: "x", command: "c", args: ["a": .string(String(repeating: "x", count: 4 * 1024 * 1024 + 5))])
        do { _ = try await UnixSocketClient.send(req, to: p, timeoutSeconds: 5); Issue.record("no throw") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("too large")) }
    }

    @Test func stopDuringAcceptPauseIsSafe() async throws {
        let p = tmpSock(); defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }; let s = UnixSocketServer(path: p, handler: echo)
        try s.start()
        s._simulateAcceptPause()
        s.stop()
        #expect(!FileManager.default.fileExists(atPath: p.path))
        let s2 = UnixSocketServer(path: p, handler: echo)
        try s2.start(); defer { s2.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let r = try await UnixSocketClient.send(Request(id: "z", command: "c"), to: p, timeoutSeconds: 5)
        #expect(r.ok)
    }

    @Test func oversizeReportedEvenWhenDaemonDown() async {
        let req = Request(id: "x", command: "c", args: ["a": .string(String(repeating: "x", count: 4 * 1024 * 1024 + 5))])
        do { _ = try await UnixSocketClient.send(req, to: tmpSock(), timeoutSeconds: 5); Issue.record("no throw") }
        catch { #expect(error.code == .invalidArgs) }
    }
}
