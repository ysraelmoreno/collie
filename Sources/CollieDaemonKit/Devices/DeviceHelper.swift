import Foundation
import Darwin
import CollieCore
import CollieDevice
import CollieProtocol

/// The accessibility helper on one Android device (spec 2026-11-22-device-helper-design.md, H2): installs the bundled APK,
/// enables its service by appending to `enabled_accessibility_services` (never overwriting), opens
/// `adb forward tcp:<free> localabstract:collie-helper`, checks `hello`'s version (older: reinstalled) and confirms with a
/// `dump` that has a root and nodes before it is `ready`. Any failure leaves it in `fallback` with the reason: the
/// `device` commands keep using uiautomator and never fail because of the helper.
actor DeviceHelper {
    /// `adb -s <serial> args` → stdout (non-zero exit throws).
    typealias Adb = @Sendable ([String]) async throws(ProtocolError) -> String
    enum State: String, Sendable { case off, starting, ready, fallback }

    let serial: String
    private let adb: Adb
    /// The APK to install (the bundle's `Resources/collie-helper.apk`); nil: not bundled.
    private let apk: @Sendable () -> URL?
    /// How long one answer may take (3 s in the spec), and the pause between tries while a fresh service comes up.
    private let answer: Duration, gap: Duration
    /// Tries of `hello` after an install, and of `dump` until it has a root and nodes (the first one after an enable
    /// can come back empty).
    static let tries = 10

    private(set) var state = State.off
    private(set) var reason: String?
    private(set) var version: Int?
    private(set) var port: UInt16?
    private var run: Task<Void, Never>?

    init(serial: String, adb: @escaping Adb, apk: @escaping @Sendable () -> URL?,
         answer: Duration = .seconds(3), gap: Duration = .milliseconds(300)) {
        self.serial = serial; self.adb = adb; self.apk = apk; self.answer = answer; self.gap = gap
    }

    /// `collie device helper status`: `source` is what the device commands read the screen with.
    var status: JSONValue {
        .object(["serial": .string(serial), "state": .string(state.rawValue), "source": .string(state == .ready ? "helper" : "uiautomator"),
                 "version": version.map { .number(Double($0)) } ?? .null, "reason": reason.map { .string($0) } ?? .null,
                 "emulator": .bool(serial.hasPrefix("emulator-"))])
    }

    /// Brings the helper up, or leaves it in `fallback` with the reason. `install`: it may install (or reinstall an old
    /// one); without it only a helper already on the device is used. A started one (ready or fallback) is left as is
    /// unless `again` (an explicit install retries a fallback). Concurrent callers wait for the one run.
    func start(install: Bool, again: Bool = false) async {
        if let r = run { await r.value }
        guard state == .off || (again && state == .fallback) else { return }
        let t = Task { await self.bringUp(install: install) }
        run = t
        await t.value
        run = nil
    }

    private func bringUp(install: Bool) async {
        state = .starting; reason = nil; version = nil
        do throws(ProtocolError) {
            // ponytail: checked first so a daemon without the APK (tests, dev runs) sends no adb at all; a helper
            // already on the device is then not used either
            guard !install || apk() != nil else { throw Self.fail("collie-helper.apk is not bundled") }
            let p = try await forward()
            var hello = try? await hello(p)
            if hello.map({ $0.version < HelperProtocol.version }) ?? true {
                guard install else {
                    throw Self.fail(hello.map { "helper v\($0.version) is older than v\(HelperProtocol.version)" } ?? "helper not answering"
                                    + "; install it with `collie device helper install --serial \(serial)`")
                }
                try await installAPK()
                try await enable()
                let h = try await retry("hello") { () async throws(ProtocolError) -> HelperProtocol.Hello? in try await self.hello(p) }
                guard h.version >= HelperProtocol.version else {
                    throw Self.fail("helper still answers v\(h.version) after reinstalling (expected v\(HelperProtocol.version))")
                }
                hello = h
            }
            _ = try await retry("dump") { () async throws(ProtocolError) -> HelperProtocol.Dump? in
                let d = try HelperProtocol.decode(try await Self.request(p, .dump, timeout: self.answer), as: HelperProtocol.Dump.self)
                return d.root && !d.nodes.isEmpty ? d : nil
            }
            state = .ready; version = hello?.version
        } catch {
            state = .fallback; reason = error.message
            await unforward()
        }
    }

    /// Disables the service (only the helper leaves the list), uninstalls the app and closes the forward.
    func remove() async throws(ProtocolError) {
        if let r = run { await r.value }
        let cur = try await adb(["shell", "settings", "get", "secure", "enabled_accessibility_services"])
        let next = HelperProtocol.removing(cur)
        if next != cur.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = try await adb(next.isEmpty ? ["shell", "settings", "delete", "secure", "enabled_accessibility_services"]
                                           : ["shell", "settings", "put", "secure", "enabled_accessibility_services", try Self.quoted(next)])
        }
        _ = try? await adb(["uninstall", HelperProtocol.package])   // not installed: nothing to undo
        await unforward()
        state = .off; version = nil; reason = "removed"
    }

    /// The last panel of the device closed: the forward goes; the service stays enabled (it costs ~nothing).
    func close() async {
        if let r = run { await r.value }
        await unforward()
        state = .off; version = nil; reason = nil
    }

    /// One request of a `device` command (H3): its answer line, or nil when the helper is not `ready` (the command then
    /// uses uiautomator / `input`). A helper that stops answering (connection refused or closed, timeout) goes to
    /// `fallback` for the session with the reason, and this call gives nil too; an answer with `ok: false` is returned
    /// as is (the caller decodes it).
    func send(_ r: HelperProtocol.Request) async -> Data? {
        guard state == .ready, let p = port else { return nil }
        do throws(ProtocolError) {
            return try await Self.request(p, r, timeout: answer)
        } catch {
            guard state == .ready else { return nil }
            state = .fallback; reason = "helper stopped answering (\(error.message)); using uiautomator"
            await unforward()
            return nil
        }
    }

    // MARK: steps

    private func forward() async throws(ProtocolError) -> UInt16 {
        if let port { return port }
        let out = try await adb(["forward", "tcp:0", "localabstract:\(HelperProtocol.socket)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = UInt16(out), p > 0 else { throw Self.fail("adb forward printed no port: \(out.prefix(200))") }
        port = p
        return p
    }

    private func unforward() async {
        guard let p = port else { return }
        port = nil
        _ = try? await adb(["forward", "--remove", "tcp:\(p)"])
    }

    private func installAPK() async throws(ProtocolError) {
        guard let apk = apk() else { throw Self.fail("collie-helper.apk is not bundled") }
        let out = try await adb(["install", "-r", apk.path])
        guard out.contains("Success") else { throw Self.fail("install failed: \(out.prefix(300))") }
    }

    /// Appends the service to `enabled_accessibility_services` (others kept) and sets `accessibility_enabled 1`.
    private func enable() async throws(ProtocolError) {
        let cur = try await adb(["shell", "settings", "get", "secure", "enabled_accessibility_services"])
        let next = HelperProtocol.enabling(cur)
        if next != cur.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = try await adb(["shell", "settings", "put", "secure", "enabled_accessibility_services", try Self.quoted(next)])
        }
        _ = try await adb(["shell", "settings", "put", "secure", "accessibility_enabled", "1"])
    }

    private func hello(_ p: UInt16) async throws(ProtocolError) -> HelperProtocol.Hello {
        try HelperProtocol.decode(try await Self.request(p, .hello, timeout: answer), as: HelperProtocol.Hello.self)
    }

    /// `f` until it gives a value, `tries` times `gap` apart. A timeout ends it at once: a mute helper does not get faster.
    private func retry<T: Sendable>(_ what: String, _ f: () async throws(ProtocolError) -> T?) async throws(ProtocolError) -> T {
        var last = "no screen yet"
        for i in 0..<Self.tries {
            if i > 0 { await DeviceService.nap(gap) }
            do throws(ProtocolError) {
                if let v = try await f() { return v }
            } catch {
                if error.code == .timeout { throw error }
                last = error.message
            }
        }
        throw Self.fail("helper \(what) failed after \(Self.tries) tries: \(last)")
    }

    private static func fail(_ m: String) -> ProtocolError { ProtocolError(code: .unavailable, message: m) }

    /// The device shell gets `adb shell` args joined: the list goes single-quoted (component names never hold a quote).
    private static func quoted(_ s: String) throws(ProtocolError) -> String {
        guard !s.contains("'") else { throw fail("enabled_accessibility_services holds a quote: \(s.prefix(200))") }
        return "'\(s)'"
    }

    /// One request to the helper on 127.0.0.1:`port` (the forward), its one answer line.
    /// ponytail: one connection per request; H4's `subscribe` keeps its own open.
    static func request(_ port: UInt16, _ r: HelperProtocol.Request, timeout: Duration) async throws(ProtocolError) -> Data {
        let secs = Double(timeout / .milliseconds(1)) / 1000, line = HelperProtocol.encode(r, id: 1)
        return try await UnixSocketClient.offPool { () throws -> Data in
            let fd = DeviceSession.connect(port, dummy: false, deadline: Date().addingTimeInterval(secs))
            guard fd >= 0 else { throw ProtocolError(code: .unavailable, message: "helper: cannot connect to port \(port)") }
            defer { Darwin.close(fd) }
            DeviceSession.setTimeout(fd, secs)
            let sent = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard sent == line.count else { throw ProtocolError(code: .unavailable, message: "helper: write failed") }
            var got = Data(), buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw ProtocolError(code: .timeout, message: "helper did not answer in \(Int(secs * 1000)) ms")
                }
                guard n > 0 else { throw ProtocolError(code: .unavailable, message: "helper closed the connection (not running?)") }
                got.append(contentsOf: buf[0..<n])
                if let nl = got.firstIndex(of: 0x0A) { return got[..<nl] }
                guard got.count < 32 << 20 else { throw ProtocolError(code: .internal, message: "helper answer over 32 MiB") }
            }
        }
    }
}

/// The helpers of the Android panels' devices.
extension DeviceService {
    /// The helper of `serial` (one per device for the daemon's life).
    func helper(_ serial: String) -> DeviceHelper {
        if let h = helpers[serial] { return h }
        let apk = helperApk
        let h = DeviceHelper(serial: serial, adb: { [weak self] args throws(ProtocolError) in
            guard let self else { throw ProtocolError(code: .unavailable, message: "Collie is shutting down") }
            return try await self.tool().run(args, serial: serial, timeout: .seconds(120)).stdout
        }, apk: apk)
        helpers[serial] = h
        return h
    }

    /// A device command on an Android panel: its first one starts the helper in the background, installing it on an
    /// emulator (disposable) and only using one already there on a physical device (`helper install` opts in).
    func kickHelper(panel: UUID, serial: String) {
        guard helperPanels[panel] == nil, !closed.contains(panel) else { return }
        helperPanels[panel] = serial
        let h = helper(serial), install = serial.hasPrefix("emulator-")
        Task { await h.start(install: install) }
    }

    /// A panel closed: the last one of its device closes the helper's forward.
    func helperPanelClosed(_ panel: UUID) async {
        guard let s = helperPanels.removeValue(forKey: panel), !helperPanels.values.contains(s) else { return }
        await helpers[s]?.close()
    }

    /// `collie device helper status|install|remove [--serial]`: the helper's status after the action.
    func helperCommand(_ action: String, serial: String?) async throws(ProtocolError) -> JSONValue {
        guard ["status", "install", "remove"].contains(action) else {
            throw ProtocolError(code: .invalidArgs, message: "device helper takes status, install or remove")
        }
        let (s, platform, _) = try await resolveSerial(serial)
        guard platform == "android" else { throw ProtocolError(code: .invalidArgs, message: "The device helper is Android only") }
        let h = helper(s)
        switch action {
        case "install": await h.start(install: true, again: true)
        case "remove": try await h.remove()
        default: break
        }
        return await h.status
    }
}
