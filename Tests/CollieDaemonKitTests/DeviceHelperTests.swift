import Testing
import Foundation
import Darwin
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// Helper stand-in on 127.0.0.1 (what `adb forward` reaches): not installed closes each connection at once (as a forward
/// with nobody on the abstract socket), `mute` accepts and never answers, else it answers `hello` with `version` and
/// `dump` with one node after `emptyDumps` empty ones.
private final class FakeHelper: @unchecked Sendable {
    let port: UInt16
    private let lfd: Int32
    private let lock = NSLock()
    private var state: (installed: Bool, version: Int, mute: Bool, emptyDumps: Int)
    private var held: [Int32] = []

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
                guard c >= 0 else { return }
                Thread { [self] in serve(c) }.start()
            }
        }.start()
    }

    /// `adb install` of the bundled APK: installed at the current version.
    func installed() { lock.withLock { state.installed = true; state.version = HelperProtocol.version } }

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
        let reply: String
        switch req["op"] as? String {
        case "hello": reply = #"{"ok":true,"version":\#(s.version),"sdk":37,"w":1080,"h":2400,"id":1}"#
        case "dump":
            let empty = lock.withLock { () -> Bool in
                guard state.emptyDumps > 0 else { return false }
                state.emptyDumps -= 1; return true
            }
            reply = empty ? #"{"ok":true,"root":true,"nodes":[],"id":1}"#
                : #"{"ok":true,"root":true,"id":1,"nodes":[{"p":[0],"text":"Combos","desc":"","id":"","cls":"android.widget.TextView","b":[0,0,10,10],"clk":true,"sel":false,"chk":false,"en":true,"foc":false,"scr":false,"pw":false}]}"#
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

private func make(_ adb: FakeAdb, serial: String = "emulator-5554", apk: URL? = URL(fileURLWithPath: "/bundle/collie-helper.apk")) -> DeviceHelper {
    DeviceHelper(serial: serial, adb: { args in await adb.run(args) }, apk: { apk }, answer: .milliseconds(300), gap: .milliseconds(10))
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

    @Test func oldVersionIsReinstalled() async throws {
        let srv = try FakeHelper(installed: true, version: 0); defer { srv.stop() }
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

    @Test func removeOfTheOnlyServiceDeletesTheSetting() async throws {
        let srv = try FakeHelper(installed: false); defer { srv.stop() }
        let adb = FakeAdb(services: HelperProtocol.service, helper: srv)
        try await make(adb).remove()
        #expect(await adb.calls.contains(["shell", "settings", "delete", "secure", "enabled_accessibility_services"]))
    }
}
