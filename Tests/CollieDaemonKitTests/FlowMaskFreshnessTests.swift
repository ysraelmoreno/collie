import Testing
import Foundation
import Darwin
import os
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

private extension DeviceService {
    func stageFresh(_ f: @escaping @Sendable (String, Panel, [String: JSONValue]) async throws(ProtocolError) -> JSONValue) { performSeam = f }
    func putFresh(_ id: UUID, _ nodes: [UINode]) { refs[id] = nodes }
}

private let field = [UINode(ref: "e1", cls: "android.widget.EditText", text: "Nome", desc: "", id: "", bounds: .zero, clickable: true, depth: 0)]

/// A device service with no adb, its flow log on, one Android panel and an injected clock.
private struct Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowfresh-\(UUID().uuidString.prefix(8))")
    let panel = Panel(id: UUID(), name: "p", pluginId: "device", placement: .canvas, state: ["serial": .string("emu-1")])
    let t0 = ContinuousClock.now
    let clock: OSAllocatedUnfairLock<ContinuousClock.Instant>
    let s: DeviceService
    let log: FlowActionLog
    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = FlowActionLog(paddock: dir, flag: dir.appendingPathComponent("flag/enabled"))
        try log.setEnabled(true)
        let c = OSAllocatedUnfairLock(initialState: t0)
        clock = c
        s = DeviceService(root: dir, runDir: dir, adb: { nil }, wmDensity: nil, now: { c.withLock { $0 } }, emit: { _, _, _ in })
    }
    func advance(_ d: Duration) { clock.withLock { $0 = $0 + d } }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws {
        _ = try await s.run(c, panel: panel, args: a, cwd: nil, flow: FlowRecorder(origin: "agent:A", log: log))
    }
    func texts() async -> [String?] {
        await s.flowFlushed()
        return ((try? String(contentsOf: log.file, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }.map { $0["text"] }
    }
    func staged() async {
        await s.stageFresh { [s] c, p, _ async throws(ProtocolError) -> JSONValue in
            if c == "device.ui" { await s.putFresh(p.id, field) }
            return .object([:])
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    var count: Int { lock.withLock { all.count } }
    func add(_ s: String) { lock.withLock { all.append(s) } }
}

/// wf3: `first` raced against `ceiling`, a signal the test raises (no clock, no yields): `first`'s value, or nil when the
/// ceiling came first. The loser is left running unawaited, so a regression's never-resumed `wait` fails the test
/// instead of hanging the suite (the leaked task dies with the test process).
func race<T: Sendable>(_ first: @escaping @Sendable () async -> T, ceiling: @escaping @Sendable () async -> Void) async -> T? {
    let (s, k) = AsyncStream.makeStream(of: T?.self)
    Task { k.yield(await first()) }
    Task { await ceiling(); k.yield(nil) }
    for await v in s { return v }
    return nil
}

private actor Steps {
    var commands: [String] = []
    func add(_ c: String) -> Int { commands.append(c); return commands.count }
}

/// wd2 (findings 5, 7, 8, 9 and 10 of rev-device-flows-final): the text is in clear only after a recent read, a folder
/// at a rotated file never lets the log grow nor floods the warnings, the old opt-in is reported, and a hangup reaches
/// `device.run` through the socket and the router. Nested in DeviceCommandTests: the daemon test drives the fake adb.
extension DeviceCommandTests {
    @Suite struct FlowMaskFreshnessTests {
        @Test func readOlderThanTheLimitMasksTheText() async throws {
            let r = try Rig(); defer { r.cleanup() }
            await r.staged()
            try await r.run("device.ui")
            r.advance(DeviceService.flowReadMaxAge + .milliseconds(1))
            try await r.run("device.text", ["text": .string("ana")])
            #expect(await r.texts() == [FlowActionLog.mask])
        }

        @Test func recentFreshReadKeepsTheTextInClear() async throws {
            let r = try Rig(); defer { r.cleanup() }
            await r.staged()
            try await r.run("device.ui")
            r.advance(.seconds(1))
            try await r.run("device.text", ["text": .string("bia")])
            #expect(await r.texts() == ["bia"])
        }

        /// A touch in Simulator.app or on the phone moves no generation: only the read's age tells the screen may have changed.
        @Test func externalTouchWithoutGenerationMasksThenANewReadClears() async throws {
            let r = try Rig(); defer { r.cleanup() }
            await r.staged()
            try await r.run("device.ui")
            let gen = r.s.flowGen.value(r.panel.id)
            r.advance(.seconds(5))   // the user typed elsewhere meanwhile
            #expect(r.s.flowGen.value(r.panel.id) == gen)
            try await r.run("device.text", ["text": .string("hunter2")])
            try await r.run("device.ui")
            try await r.run("device.text", ["text": .string("ok")])
            #expect(await r.texts() == [FlowActionLog.mask, "ok"])
        }

        @Test func emptyFolderAtRotatedFileIsRemovedAndRotationConcludes() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("flowrot-\(UUID().uuidString.prefix(8))")
            defer { try? fm.removeItem(at: root) }
            let warnings = Lines()
            var l = FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled"))
            l.maxBytes = 300; l.warn = { warnings.add($0) }
            try l.setEnabled(true)
            try fm.createDirectory(at: l.dir.appendingPathComponent("actions.1.jsonl"), withIntermediateDirectories: true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for i in 0..<20 { try l.append(FlowAction(origin: "panel", action: "tap", target: "n\(i)"), now: t0) }
            #expect(warnings.count == 0)
            for n in ["actions.1.jsonl", "actions.2.jsonl"] {
                let a = try fm.attributesOfItem(atPath: l.dir.appendingPathComponent(n).path)
                #expect(a[.type] as? FileAttributeType == .typeRegular)
            }
        }

        @Test func nonEmptyFolderAtRotatedFileKeepsTheLogBoundedAndWarnsOncePerRotation() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("flowrot-\(UUID().uuidString.prefix(8))")
            defer { try? fm.removeItem(at: root) }
            let warnings = Lines()
            var l = FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled"))
            l.maxBytes = 300; l.warn = { warnings.add($0) }
            try l.setEnabled(true)
            let blocker = l.dir.appendingPathComponent("actions.1.jsonl")
            try fm.createDirectory(at: blocker, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: blocker.appendingPathComponent("inside"))
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let tap = FlowAction(origin: "panel", action: "tap", target: "n")
            let lineSize = try FlowActionLog.line(tap, at: t0).count + 1
            let actions = 60
            for _ in 0..<actions {
                try l.append(tap, now: t0)
                let size = try #require(fm.attributesOfItem(atPath: l.file.path)[.size] as? Int)
                #expect(size < l.maxBytes + lineSize)
            }
            let perRotation = (l.maxBytes + lineSize - 1) / lineSize   // lines that fill the file before it rotates
            #expect(warnings.count >= 1)
            #expect(warnings.count <= actions / perRotation + 1, "one warning per failed rotation, not per action")
        }

        @Test func flowStatusWithTheOldOptInWarns() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("flowold-\(UUID().uuidString.prefix(8))")
            defer { try? fm.removeItem(at: root) }
            let l = FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled"))
            guard case .object(let clean) = l.status(paddock: "k") else { Issue.record("not an object"); return }
            #expect(clean["warning"] == nil)
            try fm.createDirectory(at: l.dir, withIntermediateDirectories: true)
            #expect(fm.createFile(atPath: l.legacyFlag.path, contents: Data()))
            guard case .object(let o) = l.status(paddock: "k"), case .string(let w)? = o["warning"] else { Issue.record("no warning"); return }
            #expect(o["enabled"] == .bool(false))
            #expect(w.contains("moved") && w.contains("off") && w.contains("collie device flow on --paddock k"))
            try l.setEnabled(true)
            guard case .object(let on) = l.status(paddock: "k") else { return }
            #expect(on["warning"] == nil)
        }

        /// socket → router → deviceRunCommand → a 5-step plan; the client hangs up during step 2 and step 3 never runs.
        @Test func hangupThroughSocketAndRouterStopsThePlanBeforeStep3() async throws {
            let dir = URL(fileURLWithPath: "/tmp/collie-flowfresh-\(UUID().uuidString.prefix(8))")
            let paddock = dir.appendingPathComponent("k")
            try FileManager.default.createDirectory(at: paddock, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "List of devices attached\nemulator-5554          device product:sdk_gphone model:Pixel_7 device:emu\n"
                .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("logcat"), atomically: true, encoding: .utf8)
            let adbLog = dir.appendingPathComponent("adb.log")
            try Data().write(to: adbLog)
            setenv("COLLIE_FAKE_ADB_LOG", adbLog.path, 1)
            setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
            setenv("COLLIE_FAKE_ADB_LOGCAT", dir.appendingPathComponent("logcat").path, 1)
            setenv("COLLIE_FAKE_ADB_PNG", fixtures.appendingPathComponent("screen.png").path, 1)
            setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("ui-dump.xml").path, 1)
            unsetenv("COLLIE_FAKE_ADB_TTY")
            let planFile = paddock.appendingPathComponent("plan.json")
            try #"{"steps":[{"action":"key","target":"Tab"},{"action":"key","target":"Tab"},{"action":"key","target":"Tab"},{"action":"key","target":"Back"},{"action":"key","target":"Tab"}]}"#
                .write(to: planFile, atomically: true, encoding: .utf8)

            try await withDaemon(configure: {
                $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh")
                $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
            }) { d, p in
                func send(_ r: Request) async throws -> Response { try await UnixSocketClient.send(r, to: p.socket, timeoutSeconds: 60) }
                #expect(try await send(Request(id: "x", token: d.adminToken, command: "paddock.create",
                                               args: ["name": .string("k"), "folder": .string(paddock.path)])).ok)
                #expect(try await send(Request(id: "x", token: d.adminToken, command: "panel.open", args: ["plugin": .string("device")])).ok)

                let steps = Steps()
                let (responses, responded) = AsyncStream.makeStream(of: Response.self)
                let (probes, probed) = AsyncStream.makeStream(of: Void.self)
                let (overruns, overran) = AsyncStream.makeStream(of: Void.self)
                let fd = OSAllocatedUnfairLock<Int32>(initialState: -1)
                // A socket of the test's own in front of the daemon's router, as the daemon's socket is
                let sock = URL(fileURLWithPath: "/tmp/colliet-\(UUID().uuidString.prefix(8))/s.sock")
                defer { try? FileManager.default.removeItem(at: sock.deletingLastPathComponent()) }
                let probe = try JSONEncoder().encode(Request(id: "probe", token: d.adminToken, command: "probe")) + Data([10])
                await d.router.devices.stageFresh { c, _, _ async throws(ProtocolError) -> JSONValue in
                    let n = await steps.add(c)
                    if n > 2 { overran.yield() }   // the plan went on past the hangup: next()'s ceiling
                    guard n == 2 else { return .object([:]) }
                    close(fd.withLock { $0 })   // ctrl-C on `collie device run` while step 2 is in flight
                    // wf3: the ceiling of `wait`, a probe on a second connection. The server reads every connection on one
                    // serial queue and the EOF was pending before the probe even connected, so by the probe's reply the
                    // hangup has been read: a `wait` still pending then is a regression, failed here instead of hung.
                    let p = makeSocket()
                    try? UnixSocketClient.connectSocket(p, sock.path) { 10_000 }
                    _ = writeAll(p, probe, deadline: Date().addingTimeInterval(10))
                    guard let gone = ClientHangup.current else { Issue.record("device.run runs with no ClientHangup"); return .object([:]) }
                    _ = await race({ await gone.wait() }, ceiling: { for await _ in probes { return } })   // we2: no polling
                    close(p)
                    #expect(gone.isSet, "the hangup was read (the probe was served after it) but never signalled")
                    return .object([:])
                }
                let router = d.router
                let server = UnixSocketServer(path: sock) { r, peer in
                    if r.id == "probe" { probed.yield(); return Response(id: r.id, ok: true) }
                    let res = await router.handle(r, peer: peer.pid)
                    responded.yield(res)
                    return res
                }
                try server.start(); defer { server.stop() }

                let c = makeSocket()
                try UnixSocketClient.connectSocket(c, sock.path) { 10_000 }
                fd.withLock { $0 = c }
                var line = try JSONEncoder().encode(Request(id: "r", token: d.adminToken, command: "device.run",
                                                            args: ["plan": .string(planFile.path)]))
                line.append(10)
                #expect(writeAll(c, line, deadline: Date().addingTimeInterval(10)))

                // we2: the router's reply, no polling; wf3: its ceiling is the plan running a step past the hangup
                let res = await race({ var it = responses.makeAsyncIterator(); return await it.next() },
                                     ceiling: { for await _ in overruns { return } }) ?? nil
                #expect(res?.ok == false && res?.error?.message == "plan cancelled before step 3 (done: 2)", "\(String(describing: res))")
                #expect(await steps.commands == ["device.key", "device.key"])
            }
        }
    }
}
