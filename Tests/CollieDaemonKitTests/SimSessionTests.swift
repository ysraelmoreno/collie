import Testing
import Foundation
import Darwin
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
private let udid = "000BA2AE-04FB-42B0-A7CE-1CC4FCC3C163"

/// One booted simulator for the fake xcrun; the fake AXe's log and stream-video pids.
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-simsess-\(UUID().uuidString.prefix(8))")
    var axeLog: URL { dir.appendingPathComponent("axe.log") }
    var xcrunLists: Int {
        ((try? String(contentsOf: dir.appendingPathComponent("xcrun.log"), encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { $0.hasPrefix("simctl\tlist") }.count
    }
    var pidsFile: URL { dir.appendingPathComponent("pids") }
    init(frames: Int? = nil, sleep: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "List of devices attached\n".write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try sim("Booted")
        try Data().write(to: axeLog); try Data().write(to: pidsFile)
        setenv("COLLIE_FAKE_ADB_LOG", dir.appendingPathComponent("adb.log").path, 1)
        setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
        setenv("COLLIE_FAKE_XCRUN_LOG", dir.appendingPathComponent("xcrun.log").path, 1)
        setenv("COLLIE_FAKE_SIM_DEVICES", dir.appendingPathComponent("sims.json").path, 1)
        setenv("COLLIE_FAKE_AXE_LOG", axeLog.path, 1)
        setenv("COLLIE_FAKE_AXE_PIDS", pidsFile.path, 1)
        if let frames { setenv("COLLIE_FAKE_AXE_FRAMES", "\(frames)", 1) } else { unsetenv("COLLIE_FAKE_AXE_FRAMES") }
        if let sleep { setenv("COLLIE_FAKE_AXE_SLEEP", sleep, 1) } else { unsetenv("COLLIE_FAKE_AXE_SLEEP") }
    }
    /// The fake xcrun's one simulator, in simctl `state`.
    func sim(_ state: String) throws {
        let list: [[String: Any]] = [["udid": udid, "name": "iPhone 16e", "state": state, "isAvailable": true]]
        try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-3": list]])
            .write(to: dir.appendingPathComponent("sims.json"), options: .atomic)
    }
    var axe: [String] {
        ((try? String(contentsOf: axeLog, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
    }
    /// Pids of the fake's `stream-video` runs.
    var streams: [pid_t] {
        ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { $0.hasPrefix("axe ") ? pid_t($0.dropFirst(4)) : nil }
    }
    /// The other suites must not see simulators.
    func cleanup() {
        streams.forEach { kill(-$0, SIGKILL) }
        for k in ["COLLIE_FAKE_XCRUN_LOG", "COLLIE_FAKE_SIM_DEVICES", "COLLIE_FAKE_AXE_LOG", "COLLIE_FAKE_AXE_PIDS", "COLLIE_FAKE_AXE_FRAMES", "COLLIE_FAKE_AXE_SLEEP"] {
            unsetenv(k)
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

private func withSim(grace: Duration = .milliseconds(300), poll: Duration = .seconds(2), _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: {
        $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh")
        $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
        $0.deviceGrace = grace
        $0.devicePollInterval = poll
    }, body)
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 30)
}
/// Opens a docked panel on the simulator; its id.
private func openPanel(_ d: Daemon, _ p: Paths) async throws -> String {
    let r = try await admin(d, p, "panel.open", ["plugin": "device", "placement": "dock.right", "name": "sim", "serial": udid])
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
            throw ProtocolError(code: .internal, message: "stream ended after \(got.count) frames")
        }
        got.append(f)
        if stop(f) { return got }
    }
}
private func isStatus(_ s: String) -> (StreamFrame) -> Bool {
    { if case .deviceStatus(let st, _) = $0 { st == s } else { false } }
}
private func isJpeg(_ f: StreamFrame) -> Bool { if case .jpeg = f { true } else { false } }
private func dead(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 }
private func input(_ i: SimInput) throws -> StreamFrame { .in(try JSONEncoder().encode(i)) }

/// Nested in `DeviceCommandTests` (serialized): the fakes are driven by process-wide environment variables.
extension DeviceCommandTests { @Suite struct SimSessionTests {
    @Test func jpegFrameRoundTrips() throws {
        let f = StreamFrame.jpeg(Data([1, 2, 3]))
        #expect(try JSONDecoder().decode(StreamFrame.self, from: f.line.dropLast()) == f)
        let s = String(decoding: f.line, as: UTF8.self)
        #expect(s.contains("\"t\":\"jpeg\"") && s.contains("\"d\":\"AQID\""))
    }

    @Test func streamDeliversMetaAndJpegs() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            var got = try await read(c, until: isJpeg)
            got.append(contentsOf: try await read(c, until: isJpeg))
            #expect(Array(got.prefix(3)) == [.deviceStatus(state: "connecting", message: nil), .videoMeta(width: 390, height: 844),
                                              .deviceStatus(state: "streaming", message: nil)], "\(got.prefix(3))")
            let jpegs = got.compactMap { if case .jpeg(let j) = $0 { j } else { nil } }
            #expect(jpegs.count == 2 && jpegs.allSatisfy { $0.prefix(2) == Data([0xFF, 0xD8]) })
            #expect(fx.axe.contains("stream-video --format mjpeg --fps 15 --quality 70 --scale 0.5 --udid \(udid)"), "\(fx.axe)")
        }
    }

    @Test func inputRunsAxe() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            try await c.send(try input(.tap(x: 10, y: 20)))
            try await c.send(try input(.swipe(x1: 1, y1: 2, x2: 3.5, y2: 4, seconds: 0.3)))
            try await c.send(try input(.text("hé")))       // not US-keyboard: dropped
            try await c.send(.in(Data("nonsense".utf8)))   // not a SimInput: dropped
            try await c.send(try input(.text("-hi")))
            try await c.send(try input(.key(40)))
            try await c.send(try input(.button("home")))
            let want = ["tap -x 10 -y 20 --udid \(udid)",
                        "swipe --start-x 1 --start-y 2 --end-x 3.5 --end-y 4 --duration 0.3 --udid \(udid)",
                        "type --udid \(udid) -- -hi", "key 40 --udid \(udid)", "button home --udid \(udid)"]
            #expect(await waitFor(5) { fx.axe.filter { !$0.hasPrefix("describe-ui") && !$0.hasPrefix("stream-video") } == want }, "\(fx.axe)")
        }
    }

    /// ponytail: the fake sleeps 0.1 s per input (not 0.5) so the 32-deep backlog drains in ~4 s.
    @Test func inputBacklogIsBounded() async throws {
        let fx = try Fx(sleep: "0.1"); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            for i in 0..<100 { try await c.send(try input(.tap(x: Double(i), y: 1))) }
            func taps() -> Int { fx.axe.filter { $0.hasPrefix("tap ") }.count }
            #expect(await waitFor(3) { taps() > 0 })
            // drained: no new tap for 3 s (one tap is a 0.1 s fake run, but a spawn can stall for a second or more under
            // load); unbounded, the 100 would take ≥ 12 s and the 45 s cap leaves them room to show up
            var n = -1, rounds = 0
            while taps() != n && rounds < 15 { n = taps(); rounds += 1; try await Task.sleep(for: .seconds(3)) }
            #expect((20...33).contains(taps()), "\(taps()) taps ran")
            #expect(fx.axe.filter { $0.hasPrefix("tap ") }.prefix(3) == ["tap -x 0 -y 1 --udid \(udid)", "tap -x 1 -y 1 --udid \(udid)",
                                                                         "tap -x 2 -y 1 --udid \(udid)"])
            _ = try await read(c, until: isJpeg)   // the stream is still up
        }
    }

    @Test func typedCharactersCoalesce() async throws {
        let fx = try Fx(sleep: "0.3"); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isStatus("streaming"))
            let text = String((0..<100).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
            for ch in text { try await c.send(try input(.text(String(ch)))) }
            func typed() -> [String] { fx.axe.filter { $0.hasPrefix("type ") }.map { String($0.split(separator: " -- ", maxSplits: 1)[1]) } }
            #expect(await waitFor(5) { typed().joined() == text }, "\(typed())")
            #expect(typed().count < 20, "\(typed().count) type runs")
        }
    }

    @Test func slowViewerDropsFrames() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            try await Task.sleep(for: .seconds(3))   // stalled viewer (the fake makes ~3 MiB/s)
            var got: [StreamFrame] = []
            while let f = try await c.next(timeoutSeconds: 30) {
                got.append(f)
                if got.count > 40 { break }
            }
            #expect(!got.contains(.overflow))
            #expect(got.filter(isJpeg).count > 10, "\(got.count) frames")
            let frame = got.first(where: isJpeg)?.line.count ?? 0
            #expect(d.streamQueuePeakBytes < 1_572_864 + frame, "\(d.streamQueuePeakBytes)")
        }
    }

    @Test func streamExitEndsSession() async throws {
        let fx = try Fx(frames: 3); defer { fx.cleanup() }
        try await withSim { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            let got = try await read(c, until: isStatus("ended"))
            #expect(got.contains(where: isJpeg))
            #expect(await waitFor(3) { fx.streams.count == 1 && fx.streams.allSatisfy(dead) })
            #expect(try await c.next(timeoutSeconds: 30) == nil)
        }
    }

    @Test func lastViewerGraceStops() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim(grace: .milliseconds(300)) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isJpeg)
            #expect(fx.streams.count == 1 && fx.streams.allSatisfy { !dead($0) })
            c.close()
            let closed = ContinuousClock.now
            #expect(await waitFor(3) { fx.streams.allSatisfy(dead) })
            // waitFor paddocks at 20 s, so tell the injected 300 ms grace from the 5 s production default explicitly
            #expect(ContinuousClock.now - closed < .seconds(4))
        }
    }

    @Test func panelCloseStopsNow() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim(grace: .seconds(30)) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isJpeg)
            #expect(try await admin(d, p, "panel.close", ["name": "sim"]).ok)
            _ = try await read(c, until: isStatus("ended"))
            #expect(await waitFor(2) { fx.streams.count == 1 && fx.streams.allSatisfy(dead) })
        }
    }

    /// `axe stream-video` may not exit when its simulator goes away; the booted watcher ends the session.
    @Test func simulatorShutdownEndsSession() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim(grace: .seconds(30), poll: .milliseconds(200)) { d, p in
            let c = try await view(d, p, try await openPanel(d, p))
            _ = try await read(c, until: isJpeg)
            // the watcher's first poll sets the booted baseline: two more polls started, so one ran start to finish
            let n = fx.xcrunLists
            #expect(await waitFor(20) { fx.xcrunLists >= n + 2 })
            try fx.sim("Shutdown")
            let got = try await read(c, until: isStatus("ended"), timeout: 20)
            #expect(got.last == .deviceStatus(state: "ended", message: "Simulator shut down"))
            #expect(await waitFor(3) { fx.streams.count == 1 && fx.streams.allSatisfy(dead) })
        }
    }

    @Test func lateJoinerGetsLastFrame() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withSim { d, p in
            let id = try await openPanel(d, p)
            let a = try await view(d, p, id)
            _ = try await read(a, until: isJpeg)
            let b = try await view(d, p, id)
            var got: [StreamFrame] = []
            for _ in 0..<3 { if let f = try await b.next(timeoutSeconds: 30) { got.append(f) } }
            #expect(got.count == 3 && Array(got.prefix(2)) == [.videoMeta(width: 390, height: 844), .deviceStatus(state: "streaming", message: nil)])
            #expect(got.count == 3 && isJpeg(got[2]))
            #expect(fx.axe.filter { $0.hasPrefix("stream-video") }.count == 1)
        }
    }
}
}
