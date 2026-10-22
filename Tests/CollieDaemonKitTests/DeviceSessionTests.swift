import Testing
import Foundation
import Darwin
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private let fakeAdb = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-adb.sh")

/// Fake adb inputs for a session: one online device, the adb log, the server pids, a stand-in jar.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-sess-\(UUID().uuidString.prefix(8))")
    var log: URL { dir.appendingPathComponent("adb.log") }
    var pidsFile: URL { dir.appendingPathComponent("pids") }
    var jar: URL { dir.appendingPathComponent("scrcpy-server") }
    init(port: UInt16) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: log); try Data().write(to: pidsFile); try Data("jar".utf8).write(to: jar)
        try "List of devices attached\nemulator-5554 device product:p model:Pixel_7\n"
            .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        setenv("COLLIE_FAKE_ADB_LOG", log.path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_ADB_PIDS", pidsFile.path, 1)
        setenv("COLLIE_FAKE_ADB_PORT", "\(port)", 1)
        unsetenv("COLLIE_FAKE_ADB_CRASH")
    }
    var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }
    /// Pids of the fake's scrcpy server runs (`shell CLASSPATH=…`).
    var servers: [pid_t] {
        ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { $0.hasPrefix("scrcpy ") ? pid_t($0.dropFirst(7)) : nil }
    }
    func cleanup() { servers.forEach { kill(-$0, SIGKILL) }; try? FileManager.default.removeItem(at: dir) }
}

/// scrcpy-server stand-in on 127.0.0.1: the first connection is video (dummy byte, h264 64×64 codec meta, then
/// `video`), the second control (its bytes are kept). `video` runs on its own thread; the fd stays open after it.
private final class FakeScrcpy: @unchecked Sendable {
    let port: UInt16
    private let lfd: Int32
    private let lock = NSLock()
    private var ctrl = Data(), vfd: Int32 = -1, finished = false
    var control: Data { lock.withLock { ctrl } }
    var videoDone: Bool { lock.withLock { finished } }

    init(video: @escaping @Sendable (FakeScrcpy, Int32) -> Void) throws {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        self.lfd = lfd
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(lfd, $0, len) == 0 && listen(lfd, 4) == 0 && getsockname(lfd, $0, &len) == 0
        } }
        guard ok else { throw ProtocolError(code: .internal, message: "fake scrcpy listen: \(errno)") }
        port = UInt16(bigEndian: a.sin_port)
        Thread { [self] in
            let v = accept(lfd, nil, nil)
            guard v >= 0 else { return }
            var one: Int32 = 1; setsockopt(v, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { vfd = v }
            send(v, Data([0]) + Self.meta(width: 64, height: 64))
            Thread { [self] in
                let c = accept(lfd, nil, nil)
                guard c >= 0 else { return }
                var b = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(c, &b, b.count)
                    if n <= 0 { break }
                    lock.withLock { ctrl.append(contentsOf: b[0..<n]) }
                }
                Darwin.close(c)
            }.start()
            video(self, v)
            lock.withLock { finished = true }
        }.start()
    }

    static func meta(width: UInt32, height: UInt32) -> Data {
        var d = Data()
        for v in [0x68323634, width, height] as [UInt32] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        return d
    }
    static func packet(pts: UInt64, config: Bool = false, key: Bool = false, _ body: Data) -> Data {
        var d = Data()
        let flags = pts | (config ? 1 << 63 : 0) | (key ? 1 << 62 : 0)
        withUnsafeBytes(of: flags.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { d.append(contentsOf: $0) }
        return d + body
    }
    /// Blocking write of all of `d` (false: the peer is gone).
    @discardableResult func send(_ fd: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }
    /// The standard opening: config, key (pts 1), three P frames (pts 2...4).
    func opening(_ fd: Int32) {
        send(fd, Self.packet(pts: 0, config: true, Data([0, 0, 0, 1, 0x67])))
        send(fd, Self.packet(pts: 1, key: true, Data([0, 0, 0, 1, 0x65])))
        for pts in 2...4 { send(fd, Self.packet(pts: UInt64(pts), Data([0, 0, 0, 1, 0x41]))) }
    }
    func closeVideo() { lock.withLock { if vfd >= 0 { Darwin.shutdown(vfd, SHUT_RDWR) } } }
    func stop() { Darwin.close(lfd); closeVideo() }
}

/// A port nothing listens on.
private func closedPort() -> UInt16 {
    let s = try! FakeScrcpy { _, _ in }
    s.stop()
    return s.port
}

private func withSession(jar: Bool = true, grace: Duration = .milliseconds(300), _ fx: Fx,
                         _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = fakeAdb
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
        $0.scrcpyServer = jar ? fx.jar : fx.dir.appendingPathComponent("missing")
        $0.deviceGrace = grace
    }, body)
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 30)
}
/// Opens a docked device panel; its id.
private func openPanel(_ d: Daemon, _ p: Paths, name: String = "dev") async throws -> String {
    let r = try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right", "name": name])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return id
}
private func view(_ d: Daemon, _ p: Paths, _ panel: String) async throws -> StreamClient {
    try await StreamClient.open(Request(id: "v", token: d.adminToken, command: "ui.device", args: ["panel": .string(panel)]), path: p.socket,
                                timeoutSeconds: 30)
}
/// Frames up to and including the first `stop` match (throws on timeout or end of stream first).
private func read(_ c: StreamClient, until stop: (StreamFrame) -> Bool, timeout: Double = 30) async throws -> [StreamFrame] {
    var got: [StreamFrame] = []
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        guard let f = try await c.next(timeoutSeconds: max(0.1, deadline.timeIntervalSinceNow)) else {
            throw ProtocolError(code: .internal, message: "stream ended after \(got)")
        }
        got.append(f)
        if stop(f) { return got }
    }
}
private func isStatus(_ s: String) -> (StreamFrame) -> Bool {
    { if case .deviceStatus(let st, _) = $0 { st == s } else { false } }
}
private func dead(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 }

/// Nested in `DeviceCommandTests` (serialized): the fake adb is driven by process-wide environment variables.
extension DeviceCommandTests { @Suite struct DeviceSessionTests {
    @Test func framesRoundTrip() throws {
        for f: StreamFrame in [.videoMeta(width: 1080, height: 2400), .video(Data([1, 2, 3]), pts: 1 << 40, config: true, key: false),
                               .deviceStatus(state: "error", message: "boom"), .deviceStatus(state: "streaming", message: nil)] {
            #expect(try JSONDecoder().decode(StreamFrame.self, from: f.line.dropLast()) == f)
        }
        let s = String(decoding: StreamFrame.video(Data([1, 2, 3]), pts: 7, config: false, key: true).line, as: UTF8.self)
        #expect(s.contains("\"t\":\"video\"") && s.contains("\"d\":\"AQID\""))
    }

    @Test func streamDeliversMetaConfigAndKey() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            var got: [StreamFrame] = []
            for _ in 0..<8 { if let f = try await c.next(timeoutSeconds: 30) { got.append(f) } }
            guard got.count == 8 else { Issue.record("\(got)"); return }
            #expect(got[0] == .deviceStatus(state: "connecting", message: nil))
            #expect(got[1] == .videoMeta(width: 64, height: 64))
            #expect(got[2] == .deviceStatus(state: "streaming", message: nil))
            #expect(got[3] == .video(Data([0, 0, 0, 1, 0x67]), pts: 0, config: true, key: false))
            #expect(got[4] == .video(Data([0, 0, 0, 1, 0x65]), pts: 1, config: false, key: true))
            #expect(Array(got[5...]) == (2...4).map { .video(Data([0, 0, 0, 1, 0x41]), pts: UInt64($0), config: false, key: false) })
            #expect(await waitFor(3) { fx.servers.count == 1 })   // the fake device does not wait for the fake adb shell
            let l = fx.lines
            #expect(l.contains("-s emulator-5554 push \(fx.jar.path) /data/local/tmp/collie-scrcpy-server.jar"), "\(l)")
            #expect(l.contains { $0.wholeMatch(of: /-s emulator-5554 forward tcp:0 localabstract:scrcpy_[0-9a-f]{8}/) != nil }, "\(l)")
            #expect(l.contains { $0.hasPrefix("-s emulator-5554 shell CLASSPATH=/data/local/tmp/collie-scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 3.3.1 scid=") }, "\(l)")
        }
    }

    @Test func inputReachesControlSocket() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            let msg = Scrcpy.key(.down, keycode: 66)
            try await c.send(.in(msg))
            #expect(await waitFor(5) { srv.control == msg }, "\(srv.control as NSData)")
        }
    }

    /// Like a real device: P-frames keep coming (16 KiB every 5 ms, ~3 MiB/s) and every `resetVideo` is answered with config +
    /// a ~300 KiB keyframe. The viewer reads nothing for 3 s: the daemon drops (never cuts the stream, never queues much
    /// more than 1 MiB), does not ask for keyframes it could not deliver (no reset storm), and once the viewer catches
    /// up its next picture after the gap is a keyframe.
    @Test func slowConsumerDropsUntilKeyframe() async throws {
        let pBody = Data(repeating: 0x41, count: 16 * 1024), keyBody = Data(repeating: 0x65, count: 300 * 1024)
        let srv = try FakeScrcpy { s, fd in
            var pts: UInt64 = 0, answered = 0
            s.send(fd, FakeScrcpy.packet(pts: pts, config: true, Data([0, 0, 0, 1, 0x67])))
            pts += 1; s.send(fd, FakeScrcpy.packet(pts: pts, key: true, keyBody))
            let stop = Date().addingTimeInterval(40)   // bound: the test stops it well before
            while Date() < stop {
                let resets = s.control.filter { $0 == 17 }.count
                if resets > answered {
                    answered = resets
                    pts += 1; s.send(fd, FakeScrcpy.packet(pts: pts, config: true, Data([0, 0, 0, 1, 0x67])))
                    pts += 1; guard s.send(fd, FakeScrcpy.packet(pts: pts, key: true, keyBody)) else { return }
                }
                pts += 1; guard s.send(fd, FakeScrcpy.packet(pts: pts, pBody)) else { return }
                usleep(5000)
            }
        }
        defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            try await Task.sleep(for: .seconds(3))   // stalled viewer
            #expect(srv.control.filter { $0 == 17 }.isEmpty, "keyframes asked for while the viewer could not take them")
            // read: an unbroken run, a gap (dropped frames), which must end at a keyframe, then P-frames again
            var got: [StreamFrame] = [], prev: UInt64?, gapAt: Int?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard let f = try await c.next(timeoutSeconds: 30) else { break }
                got.append(f)
                guard case .video(_, let t, false, _) = f else { continue }
                if gapAt == nil, let prev, t != prev + 1 { gapAt = got.count - 1 }
                prev = t
                if let g = gapAt, got.count - g > 20 { break }
            }
            #expect(!got.contains(.overflow))
            let keyLine = StreamFrame.video(keyBody, pts: 1, config: false, key: true).line.count
            #expect(d.streamQueuePeakBytes < 1_572_864 + keyLine, "\(d.streamQueuePeakBytes)")
            guard let g = gapAt else { Issue.record("nothing was dropped"); return }
            if case .video(_, _, false, let key) = got[g] { #expect(key, "first picture after the gap is not a keyframe") }
            #expect(got[(g + 1)...].contains { if case .video(_, _, false, false) = $0 { true } else { false } }, "no P-frames after recovery")
            #expect((1...2).contains(srv.control.filter { $0 == 17 }.count), "\(srv.control.count) resets")
        }
    }

    @Test func serverExitEndsSessionAndCleansUp() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            // the fake device accepts before the fake adb shell has started: wait for its pid
            #expect(await waitFor(3) { fx.servers.count == 1 && fx.servers.allSatisfy { !dead($0) } })
            srv.closeVideo()
            _ = try await read(c, until: isStatus("ended"))
            #expect(await waitFor(3) { fx.servers.allSatisfy(dead) })
            #expect(await waitFor(3) { fx.lines.contains("-s emulator-5554 forward --remove tcp:\(srv.port)") }, "\(fx.lines)")
            #expect(try await c.next(timeoutSeconds: 30) == nil)   // the stream closes after the status
        }
    }

    @Test func lastViewerLeavingStopsAfterGrace() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(grace: .milliseconds(300), fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            c.close()
            let closed = ContinuousClock.now
            #expect(fx.servers.allSatisfy { !dead($0) })
            #expect(await waitFor(3) { fx.servers.allSatisfy(dead) })
            // waitFor floors at 20 s, so tell the injected 300 ms grace from the 5 s production default explicitly
            #expect(ContinuousClock.now - closed < .seconds(4))
            #expect(await waitFor(3) { fx.lines.contains("-s emulator-5554 forward --remove tcp:\(srv.port)") })
        }
    }

    @Test func reattachWithinGraceKeepsSession() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(grace: .seconds(5), fx) { d, p in   // 5 s: closing + reopening may take seconds under load
            let id = try await openPanel(d, p)
            let a = try await view(d, p, id)
            _ = try await read(a, until: isStatus("streaming"))
            a.close()
            try await Task.sleep(for: .milliseconds(300))
            let b = try await view(d, p, id)
            let got = try await read(b, until: isStatus("streaming"))
            #expect(got == [.videoMeta(width: 64, height: 64), .deviceStatus(state: "streaming", message: nil)])
            #expect(try await b.next(timeoutSeconds: 30) == .video(Data([0, 0, 0, 1, 0x67]), pts: 0, config: true, key: false))
            #expect(await waitFor(3) { srv.control == Data([17]) })   // the new viewer needs a keyframe
            try await Task.sleep(for: .milliseconds(5500))           // past the first viewer's grace
            #expect(fx.servers.count == 1 && fx.servers.allSatisfy { !dead($0) })
            #expect(fx.lines.filter { $0.contains(" shell CLASSPATH=") }.count == 1)
        }
    }

    @Test func panelCloseStopsSessionNow() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        try await withSession(grace: .seconds(30), fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            #expect(try await admin(d, p, "panel.close", ["name": "dev"]).ok)
            _ = try await read(c, until: isStatus("ended"))
            #expect(await waitFor(2) { fx.servers.allSatisfy(dead) })
            #expect(await waitFor(2) { fx.lines.contains("-s emulator-5554 forward --remove tcp:\(srv.port)") })
            // gone panel: refused
            do { _ = try await view(d, p, UUID().uuidString); Issue.record("attached to no panel") }
            catch { #expect((error as? ProtocolError)?.code == .notFound) }
        }
    }

    @Test func daemonStopEndsSessionNow() async throws {
        let srv = try FakeScrcpy { s, fd in s.opening(fd) }; defer { srv.stop() }
        let fx = try Fx(port: srv.port); defer { fx.cleanup() }
        let p = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: p.root) }
        var cfg = testConfig(p); cfg.adbPath = fakeAdb; cfg.emulatorPath = URL(fileURLWithPath: "/nonexistent"); cfg.scrcpyServer = fx.jar; cfg.deviceGrace = .seconds(30)
        let d = try Daemon(config: cfg)
        try await d.start()
        let c = try await view(d, p, try await openPanel(d, p))
        _ = try await read(c, until: isStatus("streaming"))
        await d.stop()
        #expect(await waitFor(2) { fx.servers.allSatisfy(dead) })
        #expect(fx.lines.contains("-s emulator-5554 forward --remove tcp:\(srv.port)"))
    }

    @Test func missingJarReportsError() async throws {
        let fx = try Fx(port: closedPort()); defer { fx.cleanup() }
        try await withSession(jar: false, fx) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            let got = try await read(c, until: isStatus("error"))
            #expect(got.last == .deviceStatus(state: "error", message: "scrcpy-server is not bundled (run scripts/fetch-scrcpy-server.sh and rebuild)"))
            #expect(!fx.lines.contains { $0.contains(" push ") || $0.contains(" shell CLASSPATH=") })
        }
    }

    @Test func connectTimeoutReportsError() async throws {
        let fx = try Fx(port: closedPort()); defer { fx.cleanup() }
        try await withSession(fx) { d, p in
            let id = try await openPanel(d, p)
            let start = ContinuousClock.now
            let c = try await view(d, p, id)
            _ = try await read(c, until: isStatus("error"), timeout: 30)
            #expect(ContinuousClock.now - start <= .seconds(15))   // the 5 s connect window (+ fake adb runs), not a hang
            #expect(await waitFor(3) { !fx.servers.isEmpty && fx.servers.allSatisfy(dead) })
        }
    }
}
}
