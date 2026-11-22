import Testing
import Foundation
import Darwin
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// Helper stand-in on 127.0.0.1 (what `adb forward` reaches): not installed closes each connection at once (as a forward
/// with nobody on the abstract socket), `mute` accepts and never answers, else it answers `hello` with `version` and
/// `dump` with one node (or `dumpNodes`) after `emptyDumps` empty ones; `tap`/`swipe`/`click`/`text`/`global` are
/// acknowledged, `click` answering `node gone` while `goneClicks` lasts. `subscribe` is acknowledged and the connection
/// kept: an event is pushed at each of `pushes` (ms after the ack), then it is closed with `drop`, else held open.
/// `ops` logs each request line.
private final class FakeHelper: @unchecked Sendable {
    let port: UInt16
    private let lfd: Int32
    private let lock = NSLock()
    private var state: (installed: Bool, version: Int, mute: Bool, emptyDumps: Int)
    private var held: [Int32] = []
    private var log: [String] = []
    private var gone = 0
    /// The `nodes` array `dump` answers with (JSON), when set.
    private var dumpNodes: String?
    private var pushes: [Int] = [], drop = false
    var ops: [String] { lock.withLock { log } }

    init(installed: Bool, version: Int = HelperProtocol.version, mute: Bool = false, emptyDumps: Int = 0) throws {
        state = (installed, version, mute, emptyDumps)
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        self.lfd = lfd
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(lfd, $0, len) == 0 && listen(lfd, 8) == 0 && getsockname(lfd, $0, &len) == 0
        } }
        guard ok else { throw ProtocolError(code: .internal, message: "fake helper listen: \(errno)") }
        port = UInt16(bigEndian: a.sin_port)
        Thread { [self] in
            while true {
                let c = accept(lfd, nil, nil)
                // under load accept can be interrupted or see an aborted connection: only a closed listener ends it
                if c < 0 && (errno == EINTR || errno == ECONNABORTED) { continue }
                guard c >= 0 else { return }
                Thread { [self] in serve(c) }.start()
            }
        }.start()
    }

    /// `adb install` of the bundled APK: installed at the current version.
    func installed() { lock.withLock { state.installed = true; state.version = HelperProtocol.version } }
    /// The helper goes away (the app killed): each connection is closed at once, as a forward with nobody behind it.
    func die() { lock.withLock { state.installed = false } }
    func set(nodes: String? = nil, goneClicks: Int = 0) {
        lock.withLock { dumpNodes = nodes?.replacingOccurrences(of: "\n", with: ""); gone = goneClicks }   // one answer, one line
    }

    func set(emptyDumps: Int) { lock.withLock { state.emptyDumps = emptyDumps } }

    func set(pushes: [Int], drop: Bool = false) { lock.withLock { self.pushes = pushes; self.drop = drop } }

    private func subscribed(_ c: Int32) {
        let (at, drop) = lock.withLock { (pushes, self.drop) }
        var one: Int32 = 1   // the daemon closes once quiet: a later event must fail the write, not kill the test run
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ack = Array(#"{"ok":true,"id":1}\#n"#.utf8)
        _ = write(c, ack, ack.count)
        let start = Date()
        for ms in at {
            Thread.sleep(until: start.addingTimeInterval(Double(ms) / 1000))
            let ev = Array(#"{"ev":"content","t":1}\#n"#.utf8)
            guard write(c, ev, ev.count) == ev.count else { close(c); return }
        }
        if drop { close(c) } else { lock.withLock { held.append(c) } }
    }

    private func serve(_ c: Int32) {
        let s = lock.withLock { state }
        guard s.installed else { close(c); return }
        if s.mute { lock.withLock { held.append(c) }; return }
        var got = Data(), b = [UInt8](repeating: 0, count: 4096)
        while !got.contains(0x0A) {
            let n = read(c, &b, b.count)
            guard n > 0 else { close(c); return }
            got.append(contentsOf: b[0..<n])
        }
        let req = (try? JSONSerialization.jsonObject(with: got.prefix { $0 != 0x0A })) as? [String: Any] ?? [:]
        let nodes = lock.withLock { () -> String? in log.append(String(decoding: got.prefix { $0 != 0x0A }, as: UTF8.self)); return dumpNodes }
        let reply: String
        switch req["op"] as? String {
        case "hello": reply = #"{"ok":true,"version":\#(s.version),"sdk":37,"w":1080,"h":2400,"id":1}"#
        case "dump":
            let empty = lock.withLock { () -> Bool in
                guard state.emptyDumps > 0 else { return false }
                state.emptyDumps -= 1; return true
            }
            reply = empty ? #"{"ok":true,"root":true,"nodes":[],"id":1}"#
                : nodes.map { #"{"ok":true,"root":true,"id":1,"nodes":\#($0)}"# }
                ?? #"{"ok":true,"root":true,"id":1,"nodes":[{"p":[0],"text":"Combos","desc":"","id":"","cls":"android.widget.TextView","b":[0,0,10,10],"clk":true,"sel":false,"chk":false,"en":true,"foc":false,"scr":false,"pw":false}]}"#
        case "click":
            let stale = lock.withLock { () -> Bool in
                guard gone > 0 else { return false }
                gone -= 1; return true
            }
            reply = stale ? #"{"ok":false,"error":"node gone","id":1}"# : #"{"ok":true,"via":"action","id":1}"#
        case "subscribe": subscribed(c); return
        case "tap", "swipe", "text", "global": reply = #"{"ok":true,"id":1}"#
        default: reply = #"{"ok":false,"error":"unknown op"}"#
        }
        let out = Array((reply + "\n").utf8)
        _ = write(c, out, out.count)
        close(c)
    }

    func stop() { close(lfd); lock.withLock { held.forEach { close($0) }; held = [] } }
}

/// adb stand-in: logs each call, keeps `enabled_accessibility_services` and prints `port` for `forward tcp:0`.
private actor FakeAdb {
    var calls: [[String]] = []
    var services: String
    var accessibilityEnabled = "0"
    let helper: FakeHelper
    init(services: String = "null", helper: FakeHelper) { self.services = services; self.helper = helper }

    func run(_ a: [String]) -> String {
        calls.append(a)
        switch a {
        case ["forward", "tcp:0", "localabstract:collie-helper"]: return "\(helper.port)\n"
        case ["shell", "settings", "get", "secure", "enabled_accessibility_services"]: return services + "\n"
        case ["shell", "settings", "delete", "secure", "enabled_accessibility_services"]: services = "null"
        default:
            if a.count == 6, a.prefix(5) == ["shell", "settings", "put", "secure", "enabled_accessibility_services"] {
                services = a[5].trimmingCharacters(in: CharacterSet(charactersIn: "'"))   // the device shell unquotes it
            } else if a.prefix(5) == ["shell", "settings", "put", "secure", "accessibility_enabled"] {
                accessibilityEnabled = a[5]
            } else if a.first == "install" {
                helper.installed(); return "Performing Streamed Install\nSuccess\n"
            }
        }
        return ""
    }
    var installs: Int { calls.filter { $0.first == "install" }.count }
    var removedForward: Bool { calls.contains { $0 == ["forward", "--remove", "tcp:\(helper.port)"] } }
}

/// A clock the test moves by hand (`recover`'s `retrySchedule` without sleeping).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { t } }
    func advance(_ d: Duration) { lock.withLock { t += d } }
}

private func make(_ adb: FakeAdb, serial: String = "emulator-5554", apk: URL? = URL(fileURLWithPath: "/bundle/collie-helper.apk"),
                  clock: TestClock = TestClock()) -> DeviceHelper {
    DeviceHelper(serial: serial, adb: { args in await adb.run(args) }, apk: { apk }, answer: .milliseconds(300), gap: .milliseconds(10),
                 now: { clock.now })
}
private func field(_ v: JSONValue, _ k: String) -> JSONValue? { if case .object(let o) = v { o[k] } else { nil } }

@Suite struct DeviceHelperTests {
    @Test func installEnablesByAppendingAndWaitsForARealDump() async throws {
        let srv = try FakeHelper(installed: false, emptyDumps: 2); defer { srv.stop() }
        let adb = FakeAdb(services: "com.other/.Talk", helper: srv)
        let h = make(adb)
        await h.start(install: true)
        #expect(await h.state == .ready)
        #expect(await h.version == HelperProtocol.version)
        #expect(await h.port == srv.port)
        #expect(await adb.services == "com.other/.Talk:\(HelperProtocol.service)")   // the other service kept
        #expect(await adb.accessibilityEnabled == "1")
        #expect(await adb.calls.contains(["install", "-r", "/bundle/collie-helper.apk"]))
        let s = await h.status
        #expect(field(s, "source") == .string("helper") && field(s, "state") == .string("ready"))
    }

    @Test func helperAlreadyThereIsNotReinstalled() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let h = make(adb)
        await h.start(install: true)
        #expect(await h.state == .ready)
        #expect(await adb.installs == 0)
    }

    @Test func versionIsThree() { #expect(HelperProtocol.version == 3) }

    @Test func oldVersionIsReinstalled() async throws {
        let srv = try FakeHelper(installed: true, version: 1); defer { srv.stop() }   // v1: the one that kept the socket
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let h = make(adb)
        await h.start(install: true)
        #expect(await h.state == .ready)
        #expect(await h.version == HelperProtocol.version)
        #expect(await adb.installs == 1)
        #expect(await adb.services == HelperProtocol.service)   // already listed: not duplicated
    }

    @Test func muteHelperFallsBackWithTheReason() async throws {
        let srv = try FakeHelper(installed: true, mute: true); defer { srv.stop() }
        let adb = FakeAdb(helper: srv)
        let h = make(adb)
        await h.start(install: true)
        #expect(await h.state == .fallback)
        #expect(await h.reason?.contains("did not answer") == true)
        #expect(await adb.removedForward)
        #expect(await h.port == nil)
        #expect(field(await h.status, "source") == .string("uiautomator"))
        await h.start(install: true)   // the fallback holds for the session: no second try
        #expect(await adb.installs == 1)
    }

    @Test func physicalDeviceIsNotInstalledWithoutOptIn() async throws {
        let srv = try FakeHelper(installed: false); defer { srv.stop() }
        let adb = FakeAdb(helper: srv)
        let h = make(adb, serial: "R5CT1234")
        await h.start(install: false)
        #expect(await h.state == .fallback)
        #expect(await h.reason?.contains("collie device helper install --serial R5CT1234") == true)
        #expect(await adb.installs == 0)
        await h.start(install: true, again: true)   // `helper install`
        #expect(await h.state == .ready)
        #expect(await adb.installs == 1)
    }

    @Test func noBundledApkSendsNoAdb() async throws {
        let srv = try FakeHelper(installed: false); defer { srv.stop() }
        let adb = FakeAdb(helper: srv)
        let h = make(adb, apk: nil)
        await h.start(install: true)
        #expect(await h.state == .fallback)
        #expect(await h.reason == "collie-helper.apk is not bundled")
        #expect(await adb.calls.isEmpty)
    }

    @Test func forwardOpensOnceAndCloseRemovesIt() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let h = make(adb)
        await h.start(install: true)
        #expect(await adb.calls.filter { $0.first == "forward" } == [["forward", "tcp:0", "localabstract:collie-helper"]])
        await h.close()
        #expect(await adb.removedForward)
        #expect(await h.state == .off)
        #expect(await h.port == nil)
    }

    @Test func removeKeepsTheOtherServices() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let adb = FakeAdb(services: "com.a/.X:\(HelperProtocol.service):com.b/.Y", helper: srv)
        let h = make(adb)
        await h.start(install: true)
        try await h.remove()
        #expect(await adb.services == "com.a/.X:com.b/.Y")
        #expect(await adb.calls.contains(["uninstall", HelperProtocol.package]))
        #expect(await adb.removedForward)
        #expect(await h.state == .off)
        #expect(await h.reason == "removed")
    }

    @Test func emptyDumpsRebindTheServiceOnceKeepingTheOthers() async throws {
        let srv = try FakeHelper(installed: true, emptyDumps: DeviceHelper.tries + 2); defer { srv.stop() }
        let adb = FakeAdb(services: "com.a/.X:\(HelperProtocol.service):com.b/.Y", helper: srv)
        let h = make(adb)
        await h.start(install: true)
        let (up, why) = (await h.state, await h.reason)
        #expect(up == .ready, "\(why ?? "")")
        let puts = await adb.calls.filter { $0.prefix(5) == ["shell", "settings", "put", "secure", "enabled_accessibility_services"] }.map { $0[5] }
        #expect(puts == ["'com.a/.X:com.b/.Y'", "'com.a/.X:com.b/.Y:\(HelperProtocol.service)'"], "off, then on again: \(puts)")
        #expect(await adb.services == "com.a/.X:com.b/.Y:\(HelperProtocol.service)")
        #expect(await adb.accessibilityEnabled == "1")
        #expect(await adb.installs == 0)
    }

    @Test func blindHelperClimbsTheLadderInOrderThenFallsBack() async throws {
        let srv = try FakeHelper(installed: true, emptyDumps: 1000); defer { srv.stop() }
        let adb = FakeAdb(services: "com.a/.X:\(HelperProtocol.service):com.b/.Y", helper: srv)
        let h = make(adb)
        await h.start(install: true)
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .fallback, "\(reason ?? "")")
        #expect(reason?.contains("re-enabling the service, force-stopping the app, reinstalling the app; using uiautomator") == true, "\(reason ?? "")")
        #expect(field(await h.status, "source") == .string("uiautomator"))
        let calls = await adb.calls
        let off = calls.firstIndex { $0 == ["shell", "settings", "put", "secure", "enabled_accessibility_services", "'com.a/.X:com.b/.Y'"] }
        let stop = calls.firstIndex { $0 == ["shell", "am", "force-stop", HelperProtocol.package] }
        let inst = calls.firstIndex { $0.first == "install" }
        #expect(off != nil && stop != nil && inst != nil && off! < stop! && stop! < inst!, "\(calls)")
        #expect(calls.filter { $0.first == "install" }.count == 1 && calls.filter { $0.contains("force-stop") }.count == 1)
        #expect(await adb.services == "com.a/.X:com.b/.Y:\(HelperProtocol.service)", "the others kept by every step")
        // each step probes at once: its tries of dump follow it, nothing else first
        let dumps = srv.ops.filter { $0.contains(#""op":"dump""#) }.count
        #expect(dumps == 4 * DeviceHelper.tries, "\(dumps)")
    }

    @Test func ladderStopsAtTheFirstStepWithNodes() async throws {
        let srv = try FakeHelper(installed: true, emptyDumps: 2 * DeviceHelper.tries + 1); defer { srv.stop() }
        let adb = FakeAdb(services: "com.a/.X:\(HelperProtocol.service)", helper: srv)
        let h = make(adb)
        await h.start(install: true)
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .ready, "\(reason ?? "")")
        #expect(await adb.calls.filter { $0.contains("force-stop") }.count == 1)
        #expect(await adb.installs == 0, "cured by the force-stop: no reinstall")
        #expect(await adb.services == "com.a/.X:\(HelperProtocol.service)")
    }

    @Test func physicalDeviceLadderSkipsTheReinstall() async throws {
        let srv = try FakeHelper(installed: true, emptyDumps: 1000); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let h = make(adb, serial: "R5CT1234")
        await h.start(install: false)
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .fallback && reason?.contains("force-stopping the app; using uiautomator") == true, "\(reason ?? "")")
        #expect(await adb.installs == 0)
        #expect(await adb.services == HelperProtocol.service)
    }

    @Test func recoverClimbsTheSameLadder() async throws {
        let srv = try FakeHelper(installed: true, emptyDumps: 1000); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let clock = TestClock()
        let h = make(adb, clock: clock)
        await h.start(install: true)
        #expect(await h.state == .fallback)
        srv.set(emptyDumps: 2 * DeviceHelper.tries + 1)   // the next bring-up: blind until the force-stop
        clock.advance(.seconds(30))
        await h.recover()
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .ready, "\(reason ?? "")")
        #expect(await adb.calls.filter { $0.contains("force-stop") }.count == 2)
        #expect(await adb.installs == 1, "only the first bring-up reached the reinstall")
    }

    @Test func retryScheduleIs2_5_15ThenThirtyForGood() {
        #expect(DeviceHelper.retrySchedule == [.seconds(2), .seconds(5), .seconds(15), .seconds(30)])
    }

    @Test func fallbackIsRetriedAlongTheScheduleAndRestartsOnReady() async throws {
        let srv = try FakeHelper(installed: false); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        let clock = TestClock()
        let h = make(adb, serial: "R5CT1234", clock: clock)
        await h.start(install: false)
        #expect(await h.state == .fallback)
        let forwards = { await adb.calls.filter { $0.prefix(2) == ["forward", "tcp:0"] }.count }
        var tries = 1
        // each wait counts from the fall or the last failed try: 2, 5, 15, then 30 s (twice: the last value repeats)
        for wait in [2, 5, 15, 30, 30] {
            clock.advance(.seconds(wait - 1))
            await h.recover()
            #expect(await forwards() == tries, "not before \(wait) s")
            clock.advance(.seconds(1))
            await h.recover()   // still not there: the fallback and its reason stay
            tries += 1
            #expect(await forwards() == tries, "tried at \(wait) s")
            let (state, reason) = (await h.state, await h.reason)
            #expect(state == .fallback && reason?.contains("not answering") == true, "\(reason ?? "")")
        }
        srv.installed()
        clock.advance(.seconds(30))
        await h.recover()
        #expect(await h.state == .ready)
        let s = await h.status
        #expect(field(s, "source") == .string("helper") && field(s, "reason") == .null)
        #expect(await adb.installs == 0)
        // back at ready the count restarts: a new fall is retried 2 s later, not 30 s
        srv.set(emptyDumps: 1)
        #expect(await h.dump() == nil)
        #expect(await h.state == .fallback)
        tries = await forwards()
        clock.advance(.seconds(1))
        await h.recover()
        #expect(await forwards() == tries, "not before 2 s")
        clock.advance(.seconds(1))
        await h.recover()
        #expect(await forwards() == tries + 1)
        #expect(await h.state == .ready)
    }

    @Test func removeOfTheOnlyServiceDeletesTheSetting() async throws {
        let srv = try FakeHelper(installed: false); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        try await make(adb).remove()
        #expect(await adb.calls.contains(["shell", "settings", "delete", "secure", "enabled_accessibility_services"]))
    }
}

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

/// A `DeviceService` on an adb script of its own (no environment: other suites set the fake adb's env in parallel):
/// `forward` reaches `srv`, the helper is already listed, `uiautomator dump /dev/tty` prints Fixtures/ui-dump.xml.
private struct Svc {
    let dir = URL(fileURLWithPath: "/tmp/collie-h3-\(UUID().uuidString.prefix(8))")
    let svc: DeviceService
    let panel = Panel(id: UUID(), name: "d", pluginId: "device", placement: .canvas, state: ["serial": .string("emulator-5554")])
    init(_ srv: FakeHelper) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = dir.appendingPathComponent("adb"), log = dir.appendingPathComponent("adb.log").path
        try """
        #!/bin/sh
        echo "$*" >> '\(log)'
        case "$*" in
          "devices -l") printf 'List of devices attached\\nemulator-5554 device product:x\\n' ;;
          *"forward tcp:0 localabstract:collie-helper") echo \(srv.port) ;;
          *"settings get secure enabled_accessibility_services") echo '\(HelperProtocol.service)' ;;
          *"uiautomator dump /dev/tty") cat '\(fixtures.appendingPathComponent("ui-dump.xml").path)'; echo 'UI hierchary dumped to: /dev/tty' ;;
        esac
        exit 0
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let dir = dir
        svc = DeviceService(root: dir, runDir: dir, adb: { adb }, helperApk: { URL(fileURLWithPath: "/bundle/collie-helper.apk") }) { _, _, _ in }
    }
    /// The helper up (as the panel's first command starts it), ready.
    func ready() async -> DeviceHelper {
        let h = await svc.helper("emulator-5554")
        await h.start(install: true)
        return h
    }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await svc.run(c, panel: panel, args: a, cwd: nil)
    }
    var adb: [String] { ((try? String(contentsOf: dir.appendingPathComponent("adb.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() async { await svc.stop(); try? FileManager.default.removeItem(at: dir) }
}

/// A tab bar row (selected first tab) and a password field, as the helper dumps them.
private let tabsAndPassword = #"""
[{"p":[],"text":"","desc":"","id":"","cls":"android.widget.FrameLayout","b":[0,0,1080,2400],"clk":false,"sel":false,"chk":false,"en":true,"foc":false,"scr":false,"pw":false},
 {"p":[0],"text":"Combos","desc":"","id":"com.x:id/combos","cls":"android.widget.TextView","b":[0,1000,500,1100],"clk":true,"sel":true,"chk":false,"en":true,"foc":false,"scr":false,"pw":false},
 {"p":[1],"text":"Deals","desc":"","id":"","cls":"android.widget.TextView","b":[540,1000,1080,1100],"clk":true,"sel":false,"chk":false,"en":true,"foc":false,"scr":false,"pw":false},
 {"p":[2],"text":"•••","desc":"","id":"com.x:id/pass","cls":"android.widget.EditText","b":[0,1200,1080,1300],"clk":true,"sel":false,"chk":false,"en":true,"foc":true,"scr":false,"pw":true}]
"""#

private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }

/// H3: the `device` commands through the helper, the same answers, and uiautomator / `input` when it is not there.
extension DeviceHelperTests {
    @Test func uiAndScreenReadThroughTheHelperWithItsStates() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(nodes: tabsAndPassword)
        let fx = try Svc(srv)
        _ = await fx.ready()
        let ui = obj(try await fx.run("device.ui", ["timing": .bool(true)]))
        guard case .string(let tree)? = ui["tree"] else { Issue.record("\(ui)"); await fx.cleanup(); return }
        #expect(tree.contains("[e1] TextView \"Combos\" id=combos (250,1050) clickable"), "\(tree)")   // the empty root dropped, as uiautomator
        #expect(obj(ui["timingMs"])["source"] == .string("helper"))
        let screen = obj(try await fx.run("device.screen", ["timing": .bool(true)]))
        #expect(obj(screen["timingMs"])["source"] == .string("helper"))
        guard case .array(let tabs)? = screen["tabs"], case .array(let fields)? = screen["fields"] else { Issue.record("\(screen)"); await fx.cleanup(); return }
        #expect(obj(tabs.first)["state"] == .array([.string("selected")]))
        #expect(obj(fields.first)["state"] == .array([.string("focused"), .string("password")]))
        #expect(!fx.adb.contains { $0.contains("uiautomator") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func tapByTextClicksThePathAndRetriesAStaleOnce() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(nodes: tabsAndPassword, goneClicks: 1)
        let fx = try Svc(srv)
        _ = await fx.ready()
        let r = try await fx.run("device.tap", ["text": .string("Deals")])
        #expect(r == .object([:]))
        let ops = srv.ops
        #expect(ops.filter { $0.contains(#""op":"click""#) && $0.contains(#""path":[1]"#) }.count == 2, "\(ops)")
        let clicks = ops.indices.filter { ops[$0].contains("click") }
        #expect(clicks.count == 2 && ops[clicks[0]..<clicks[1]].contains { $0.contains(#""op":"dump""#) })   // re-read between the two
        #expect(!fx.adb.contains { $0.contains("input") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func tapXYSwipeTextAndGlobalKeysGoThroughTheHelper() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Svc(srv)
        _ = await fx.ready()
        for (c, a) in [("device.tap", ["x": JSONValue.number(3), "y": .number(4)]),
                       ("device.swipe", ["x1": .number(1), "y1": .number(2), "x2": .number(3), "y2": .number(4)]),
                       ("device.text", ["text": .string("hi")]), ("device.key", ["key": .string("back")]),
                       ("device.key", ["key": .string("recents")]), ("device.key", ["key": .string("enter")])] {
            #expect(try await fx.run(c, a) == .object([:]))
        }
        let ops = srv.ops
        #expect(ops.contains { $0.contains(#""op":"tap""#) && $0.contains(#""x":3"#) })
        #expect(ops.contains { $0.contains(#""op":"swipe""#) && $0.contains(#""ms":300"#) })
        #expect(ops.contains { $0.contains(#""op":"text""#) && $0.contains(#""value":"hi""#) })
        #expect(ops.contains { $0.contains(#""action":"back""#) } && ops.contains { $0.contains(#""action":"recents""#) })
        #expect(fx.adb.filter { $0.contains("input") } == ["-s emulator-5554 shell input keyevent 66"], "\(fx.adb)")   // enter: a keyevent
        await fx.cleanup()
    }

    @Test func emptyDumpOfAReadyHelperShowsInTheStatus() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Svc(srv)
        let h = await fx.ready()
        srv.set(emptyDumps: 1)
        let ui = obj(try await fx.run("device.ui", ["timing": .bool(true)]))
        #expect(obj(ui["timingMs"])["source"] == .string("uiautomator"))
        let s = try await fx.svc.helperCommand("status", serial: "emulator-5554")
        #expect(field(s, "state") == .string("fallback") && field(s, "source") == .string("uiautomator"), "\(s)")
        #expect(await h.reason?.contains("without nodes") == true)
        await fx.cleanup()
    }

    @Test func helperGoneMidwayFallsBackToUiautomatorAndInput() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        let fx = try Svc(srv)
        let h = await fx.ready()
        #expect(obj(obj(try await fx.run("device.ui", ["timing": .bool(true)]))["timingMs"])["source"] == .string("helper"))
        srv.die()
        let ui = obj(try await fx.run("device.ui", ["timing": .bool(true)]))
        guard case .string(let tree)? = ui["tree"] else { Issue.record("\(ui)"); await fx.cleanup(); return }
        #expect(tree.contains("Login") && obj(ui["timingMs"])["source"] == .string("uiautomator"))
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .fallback && reason?.contains("stopped answering") == true, "\(reason ?? "")")
        #expect(try await fx.run("device.tap", ["x": .number(3), "y": .number(4)]) == .object([:]))
        #expect(fx.adb.contains("-s emulator-5554 shell input tap 3 4"), "\(fx.adb)")
        await fx.cleanup()
    }
}

/// H4: `wait --stable` and `--settle stable` by the helper's `subscribe` events, the polling when it is not there.
extension DeviceHelperTests {
    @Test func stableAfterSilenceWithoutDumpPolling() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(pushes: [])
        let fx = try Svc(srv)
        let h = await fx.ready()
        let (up, why) = (await h.state, await h.reason)
        #expect(up == .ready, "\(why ?? "")")
        let dumps = srv.ops.filter { $0.contains(#""op":"dump""#) }.count   // the ready check's
        let r = obj(try await fx.run("device.wait", ["stable": .bool(true)]))
        guard case .number(let ms)? = r["waitedMs"] else { Issue.record("\(r)"); await fx.cleanup(); return }
        #expect(r["ok"] == .bool(true) && ms >= 300 && ms < 2000, "\(r)")
        let after = await h.reason
        #expect(srv.ops.filter { $0.contains(#""op":"subscribe""#) }.count == 1, "\(srv.ops) \(after ?? "")")
        #expect(srv.ops.filter { $0.contains(#""op":"dump""#) }.count == dumps, "no dump polling: \(srv.ops)")
        let t = obj(try await fx.run("device.tap", ["x": .number(3), "y": .number(4), "then": .string("ui"), "settle": .string("stable"), "quiet": .number(100)]))
        #expect(t["settled"] == .bool(true), "\(t)")
        #expect(srv.ops.filter { $0.contains(#""op":"subscribe""#) }.count == 2)
        #expect(!fx.adb.contains { $0.contains("uiautomator") }, "\(fx.adb)")
        await fx.cleanup()
    }

    @Test func eventRestartsTheQuietCount() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(pushes: [200, 400])
        let fx = try Svc(srv)
        _ = await fx.ready()
        let r = obj(try await fx.run("device.wait", ["stable": .bool(true), "quiet": .number(300)]))
        guard case .number(let ms)? = r["waitedMs"] else { Issue.record("\(r)"); await fx.cleanup(); return }
        #expect(ms >= 700 && ms < 3000, "the last event at 400 ms + 300 quiet: \(r)")
        await fx.cleanup()
    }

    @Test func eventsUntilTheTimeoutFailTheWait() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(pushes: Array(stride(from: 100, through: 3000, by: 100)))
        let fx = try Svc(srv)
        _ = await fx.ready()
        do {
            _ = try await fx.run("device.wait", ["stable": .bool(true), "timeout": .string("800ms")])
            Issue.record("a screen that keeps changing must time out")
        } catch let e as ProtocolError {
            #expect(e.code == .timeout && e.message.contains("stable screen not reached in 800 ms") && e.message.contains("Combos"), "\(e.message)")
        }
        #expect(!fx.adb.contains { $0.contains("uiautomator") }, "the last screen read through the helper: \(fx.adb)")
        await fx.cleanup()
    }

    @Test func helperDropMidwayFallsBackToPolling() async throws {
        let srv = try FakeHelper(installed: true); defer { srv.stop() }
        srv.set(pushes: [100], drop: true)
        let fx = try Svc(srv)
        let h = await fx.ready()
        let r = obj(try await fx.run("device.wait", ["stable": .bool(true)]))
        #expect(r["ok"] == .bool(true), "\(r)")
        let (state, reason) = (await h.state, await h.reason)
        #expect(state == .fallback && reason?.contains("subscription") == true, "\(reason ?? "")")
        #expect(fx.adb.filter { $0.contains("uiautomator") }.count >= 2, "two equal dumps: \(fx.adb)")
        await fx.cleanup()
    }
}
