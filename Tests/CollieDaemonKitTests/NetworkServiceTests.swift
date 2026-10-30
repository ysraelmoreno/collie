import Testing
import Foundation
import os
import CollieProtocol
@testable import CollieDaemonKit

/// A proxy whose stdout the test writes; `exit()` ends it as a dead mitmdump would.
private final class FakeProxy: NetworkProxy, @unchecked Sendable {
    let port: Int
    let caCert = URL(fileURLWithPath: "/tmp/fake-ca.pem")
    let lines: AsyncStream<String>
    private let cont: AsyncStream<String>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (exited: Int32?.none, stopped: false))
    let droppedCount = OSAllocatedUnfairLock(initialState: 0)
    var dropped: Int { droppedCount.withLock { $0 } }
    func consumed(_ line: String) {}
    let restarts: OSAllocatedUnfairLock<[FakeProxy]>

    init(port: Int, restarts: OSAllocatedUnfairLock<[FakeProxy]> = .init(initialState: [])) {
        self.port = port; self.restarts = restarts
        (lines, cont) = AsyncStream.makeStream(of: String.self)
    }
    var exited: Int32? { state.withLock { $0.exited } }
    var stopped: Bool { state.withLock { $0.stopped } }
    func send(_ line: String) { cont.yield(line) }
    func exit() { state.withLock { $0.exited = 1 }; cont.finish() }
    func stop() { state.withLock { $0.stopped = true }; cont.finish() }
    func restart() async throws(ProtocolError) -> any NetworkProxy {
        stop()
        let p = FakeProxy(port: port, restarts: restarts)
        restarts.withLock { $0.append(p) }
        return p
    }
}

/// Records every call. `failAttach`: attach throws; `failDetach`/`failReconcile`: adb "gone" until cleared;
/// `holdAttach`: attach waits until released; `detachDelay`: detach takes that long.
private final class FakeDevice: NetworkDevice, @unchecked Sendable {
    struct Knobs { var failDetach = false, failReconcile = false, holdAttach = false }
    let calls = OSAllocatedUnfairLock(initialState: [String]())
    let knobs = OSAllocatedUnfairLock(initialState: Knobs())
    let failAttach: Bool, detachDelay: Duration
    init(failAttach: Bool = false, detachDelay: Duration = .zero) { self.failAttach = failAttach; self.detachDelay = detachDelay }
    var log: [String] { calls.withLock { $0 } }
    func set(_ f: @Sendable (inout Knobs) -> Void) { knobs.withLock { f(&$0) } }
    func attach(serial: String, port: Int, caCert: URL) async throws(ProtocolError) -> DeviceNetworkSetup.AttachResult {
        calls.withLock { $0.append("attach \(serial) \(port)") }
        while knobs.withLock({ $0.holdAttach }) { try? await Task.sleep(for: .milliseconds(5)) }
        if failAttach { throw ProtocolError(code: .unavailable, message: "not rootable") }
        return .init(sdk: 37, hash: "c8750f0d", system: "mounted 146 CAs", user: "added", previousProxy: "null",
                     restartSuggested: serial == "emulator-5562" ? ["com.android.chrome"] : [])
    }
    func detach(serial: String, port: Int?) async throws(ProtocolError) -> [String] {
        calls.withLock { $0.append("detach \(serial) \(port.map(String.init) ?? "nil")") }
        if detachDelay > .zero { try? await Task.sleep(for: detachDelay) }
        if knobs.withLock({ $0.failDetach }) { throw ProtocolError(code: .unavailable, message: "adb not found") }
        return ["proxy: restored :0"]
    }
    func reconcile(serial: String, activePort: Int?, caCert: URL?) async throws(ProtocolError) -> DeviceNetworkSetup.Reconcile {
        calls.withLock { $0.append("reconcile \(serial) \(activePort.map(String.init) ?? "nil")") }
        if knobs.withLock({ $0.failReconcile }) { throw ProtocolError(code: .unavailable, message: "device offline") }
        return activePort == nil ? .detached : .none
    }
}

private let request = #"{"type":"request","id":"f1","ts":1730000000.1,"method":"POST","url":"https://example.com/a?b=1","httpVersion":"HTTP/1.1","headers":[{"name":"Content-Type","value":"application/json"}],"body":{"size":7,"truncated":false,"contentEncoding":null,"data":"eyJhIjoxfQ=="},"tls":{"sni":"example.com","alpn":"http/1.1"}}"#
private let response = #"{"type":"response","id":"f1","ttfb":1730000000.2,"ts":1730000000.3,"status":201,"reason":"Created","headers":[],"body":{"size":5,"truncated":false,"contentEncoding":null,"data":"aGVsbG8="}}"#

@Suite struct NetworkServiceTests {
    private struct Rig {
        let service: NetworkService
        let proxies: OSAllocatedUnfairLock<[FakeProxy]>
        let device: FakeDevice
        let events: OSAllocatedUnfairLock<[(String, String, JSONValue)]>
        var proxy: FakeProxy { proxies.withLock { $0.last! } }
        func waitEvents(_ n: Int) async {
            for _ in 0..<200 where events.withLock({ $0.count }) < n { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private func rig(device: FakeDevice = FakeDevice(), online: [String] = [], stopBudget: Duration = .seconds(15)) -> Rig {
        let proxies = OSAllocatedUnfairLock(initialState: [FakeProxy]())
        let events = OSAllocatedUnfairLock(initialState: [(String, String, JSONValue)]())
        let ports = OSAllocatedUnfairLock(initialState: 40000)   // first proxy: 40001
        let s = NetworkService(pollInterval: .seconds(3600), stopBudget: stopBudget,
            startProxy: { _ throws(ProtocolError) in
                let p = FakeProxy(port: ports.withLock { $0 += 1; return $0 }, restarts: proxies)
                proxies.withLock { $0.append(p) }
                return p
            },
            device: { device }, onlineEmulators: { online },
            emit: { s, n, pl in events.withLock { $0.append((s, n, pl)) } })
        return Rig(service: s, proxies: proxies, device: device, events: events)
    }

    @Test func attachCapturesAndDetachRestores() async throws {
        let r = rig()
        let st = try await r.service.attach("emulator-5560")
        guard case .object(let o) = st else { Issue.record("\(st)"); return }
        #expect(o["attached"] == .bool(true) && o["port"] == .number(40001) && o["ca"] == .string("c8750f0d"))
        #expect(r.device.log == ["attach emulator-5560 40001"])

        r.proxy.send("mitmdump noise, not JSON"); r.proxy.send(request); r.proxy.send(response)
        await r.waitEvents(2)
        let ev = r.events.withLock { $0 }
        #expect(ev.count == 2 && ev.allSatisfy { $0.0 == "emulator-5560" && $0.1 == "network.flow" })
        guard case .object(let last)? = ev.last?.2 else { Issue.record("\(ev)"); return }
        #expect(last["id"] == .string("f1") && last["status"] == .number(201) && last["host"] == .string("example.com"))
        #expect(last["path"] == .string("/a?b=1") && last["durationMs"] == .number(200))
        #expect(last["reqBody"] == nil && last["resBody"] == nil && last["serial"] == .string("emulator-5560"))   // never a body
        guard case .array(let none) = try await r.service.list("emulator-5560", host: "other.org") else { Issue.record("host"); return }
        #expect(none.isEmpty)

        guard case .array(let rows) = try await r.service.list("emulator-5560") else { Issue.record("list"); return }
        #expect(rows.count == 1)
        guard case .object(let flow) = try await r.service.get("emulator-5560", id: "f1"),
              case .object(let res)? = flow["resBody"] else { Issue.record("get"); return }
        #expect(res["data"] == .string("aGVsbG8=") && flow["serial"] == .string("emulator-5560"))
        #expect(flow["resBodyText"] == .string("hello") && flow["reqBodyText"] == .string("{\n  \"a\" : 1\n}"))
        guard case .object(let c) = try await r.service.curl("emulator-5560", id: "f1"), case .string(let curl)? = c["curl"] else { Issue.record("curl"); return }
        #expect(curl.hasPrefix("curl") && curl.contains("https://example.com/a?b=1"))
        await #expect(throws: ProtocolError.self) { try await r.service.get("emulator-5560", id: "nope") }

        _ = try await r.service.clear("emulator-5560")
        guard case .array(let empty) = try await r.service.list("emulator-5560") else { Issue.record("list"); return }
        #expect(empty.isEmpty)

        let d = try await r.service.detach("emulator-5560")
        guard case .object(let od) = d else { Issue.record("\(d)"); return }
        #expect(od["attached"] == .bool(false) && r.proxy.stopped)
        #expect(r.device.log.last == "detach emulator-5560 40001")
        await #expect(throws: ProtocolError.self) { try await r.service.list("emulator-5560") }
    }

    @Test func attachAnswerCarriesTheRestartHintOnce() async throws {
        let r = rig()
        guard case .object(let first) = try await r.service.attach("emulator-5562") else { Issue.record("attach"); return }
        #expect(first["restartSuggested"] == .array([.string("com.android.chrome")]))
        guard case .object(let later) = await r.service.status("emulator-5562") else { Issue.record("status"); return }
        #expect(later["restartSuggested"] == nil)
        guard case .object(let quiet) = try await r.service.attach("emulator-5560") else { Issue.record("attach"); return }
        #expect(quiet["restartSuggested"] == nil)
    }

    @Test func attachTwiceKeepsOneProxyAndRepairs() async throws {
        let r = rig()
        _ = try await r.service.attach("emulator-5560")
        _ = try await r.service.attach("emulator-5560")
        #expect(r.proxies.withLock { $0.count } == 1)
        #expect(r.device.log == ["attach emulator-5560 40001", "reconcile emulator-5560 40001"])
    }

    @Test func concurrentAttachesShareOneStart() async throws {
        let r = rig()
        async let a = r.service.attach("emulator-5560")
        async let b = r.service.attach("emulator-5560")
        _ = try await (a, b)
        #expect(r.proxies.withLock { $0.count } == 1)
    }

    @Test func failedDeviceAttachIsRolledBack() async throws {
        let r = rig(device: FakeDevice(failAttach: true))
        await #expect(throws: ProtocolError.self) { try await r.service.attach("emulator-5560") }
        #expect(r.proxy.stopped)
        #expect(r.device.log == ["attach emulator-5560 40001", "detach emulator-5560 40001"])   // whatever it did before failing is undone
        #expect(await r.service.attached.isEmpty)
    }

    @Test func failedDetachStaysPendingUntilThePollerSucceeds() async throws {
        let r = rig()
        _ = try await r.service.attach("emulator-5560")
        r.device.set { $0.failDetach = true; $0.failReconcile = true }
        await #expect(throws: ProtocolError.self) { try await r.service.detach("emulator-5560") }
        let attached = await r.service.attached
        #expect(r.proxy.stopped && attached.isEmpty)
        guard case .object(let st) = await r.service.status("emulator-5560") else { Issue.record("status"); return }
        #expect(st["pendingDetach"] == .bool(true))
        await r.service.reconcileSessions()   // still failing: kept
        guard case .object(let still) = await r.service.status("emulator-5560") else { Issue.record("status"); return }
        #expect(still["pendingDetach"] == .bool(true))
        r.device.set { $0.failReconcile = false }
        await r.service.reconcileSessions()
        guard case .object(let done) = await r.service.status("emulator-5560") else { Issue.record("status"); return }
        #expect(done["pendingDetach"] == nil)
        #expect(r.device.log.filter { $0 == "reconcile emulator-5560 nil" }.count == 2)
    }

    @Test func detachDuringAttachCancelsIt() async throws {
        let device = FakeDevice()
        device.set { $0.holdAttach = true }
        let r = rig(device: device)
        let attach = Task { try await r.service.attach("emulator-5560") }
        for _ in 0..<200 where device.log.isEmpty { try await Task.sleep(for: .milliseconds(5)) }   // attach is on the device
        _ = try await r.service.detach("emulator-5560")
        device.set { $0.holdAttach = false }
        await #expect(throws: ProtocolError.self) { try await attach.value }
        #expect(await r.service.attached.isEmpty)
        #expect(r.proxy.stopped)
        #expect(device.log.last == "detach emulator-5560 40001")   // the cancelled attach undid its device side
    }

    @Test func startReconcileSkipsAnEmulatorBeingAttached() async throws {
        let device = FakeDevice()
        device.set { $0.holdAttach = true }
        let r = rig(device: device, online: ["emulator-5554", "emulator-5560"])
        let attach = Task { try await r.service.attach("emulator-5560") }
        for _ in 0..<200 where device.log.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await r.service.reconcileAtStart()
        #expect(device.log == ["attach emulator-5560 40001", "reconcile emulator-5554 nil"])
        device.set { $0.holdAttach = false }
        _ = try await attach.value
    }

    @Test func statusReportsDroppedLines() async throws {
        let r = rig()
        _ = try await r.service.attach("emulator-5560")
        r.proxy.droppedCount.withLock { $0 = 3 }
        guard case .object(let st) = await r.service.status("emulator-5560") else { Issue.record("status"); return }
        #expect(st["dropped"] == .number(3))
    }

    @Test func stopIsBoundedWhenAdbHangs() async throws {
        let r = rig(device: FakeDevice(detachDelay: .seconds(30)), stopBudget: .milliseconds(200))
        _ = try await r.service.attach("emulator-5560")
        _ = try await r.service.attach("emulator-5562")
        let t0 = ContinuousClock.now
        await r.service.stop()
        #expect(ContinuousClock.now - t0 < .seconds(3))
        #expect(r.device.log.filter { $0.hasPrefix("detach") }.count == 2)   // both started, in parallel
    }

    @Test func emulatorsOnly() async {
        let r = rig()
        await #expect(throws: ProtocolError.self) { try await r.service.attach("R58N12ABCDE") }
        #expect(r.proxies.withLock { $0.isEmpty })
    }

    @Test func deadProxyIsRestartedOnItsPort() async throws {
        let r = rig()
        _ = try await r.service.attach("emulator-5560")
        let first = r.proxy
        first.exit()
        await r.service.reconcileSessions()
        let fresh = r.proxy
        #expect(fresh !== first && fresh.port == first.port)
        fresh.send(request)
        await r.waitEvents(1)
        #expect(r.events.withLock { $0.count } == 1)
        #expect(r.device.log.last == "reconcile emulator-5560 40001")
    }

    @Test func startReconcilesEveryOnlineEmulatorWithoutSession() async {
        let r = rig(online: ["emulator-5554", "emulator-5560"])
        await r.service.reconcileAtStart()
        #expect(r.device.log == ["reconcile emulator-5554 nil", "reconcile emulator-5560 nil"])
    }

    @Test func stopDetachesEverySession() async throws {
        let r = rig()
        _ = try await r.service.attach("emulator-5560")
        _ = try await r.service.attach("emulator-5562")
        await r.service.stop()
        #expect(r.proxies.withLock { $0.allSatisfy(\.stopped) })
        #expect(Set(r.device.log.filter { $0.hasPrefix("detach") }) == ["detach emulator-5560 40001", "detach emulator-5562 40002"])
        #expect(await r.service.attached.isEmpty)
    }
}

/// The whole path on a real emulator, through a test daemon (what `collie network …` sends):
/// `COLLIE_E2E_SERIAL=emulator-5560 swift test --filter NetworkSetupTests`. Needs mitmdump, a rootable emulator and
/// Chrome past its first-run screen; leaves the emulator as it found it. Nested in the serialized `NetworkSetupTests`:
/// two attaches on one emulator at once would undo each other.
extension NetworkSetupTests { @Suite struct DaemonE2E {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_E2E_SERIAL"] != nil), .timeLimit(.minutes(3)))
    func attachBrowseListCurlDetach() async throws {
        let serial = ProcessInfo.processInfo.environment["COLLIE_E2E_SERIAL"]!
        let adb = Adb(url: try #require(Adb.locate(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())))
        try await withDaemon { d, p in
            func call(_ command: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
                var args = args; args["serial"] = .string(serial)
                let r = try await send(p, Request(id: command, token: d.adminToken, command: command, args: args), timeoutSeconds: 120)
                guard r.ok, let v = r.result else { throw r.error ?? ProtocolError(code: .internal, message: "\(command) failed") }
                return v
            }
            guard case .object(let st) = try await call("network.attach") else { Issue.record("attach"); return }
            #expect(st["attached"] == .bool(true))
            let marker = "collie-e2e-\(UUID().uuidString.prefix(8))"
            // this test daemon made a new CA; a running Chrome still holds the user store it read at its start
            _ = try await adb.run(["shell", "am force-stop com.android.chrome"], serial: serial, timeout: .seconds(10))
            _ = try await adb.run(["shell", "am start -a android.intent.action.VIEW -d 'https://example.com/?\(marker)' com.android.chrome"],
                                  serial: serial, timeout: .seconds(20))
            var id: String?
            for _ in 0..<60 where id == nil {
                if case .array(let rows) = try await call("network.list", ["host": "example.com"]) {
                    id = rows.compactMap { r -> String? in
                        guard case .object(let o) = r, case .string(let path)? = o["path"], path.contains(marker), o["status"] == .number(200),
                              case .string(let i)? = o["id"] else { return nil }
                        return i
                    }.first
                }
                if id == nil { try await Task.sleep(for: .milliseconds(500)) }
            }
            let flowId = try #require(id, "Chrome's request never showed up in network.list")
            guard case .object(let flow) = try await call("network.get", ["id": .string(flowId)]),
                  case .string(let html)? = flow["resBodyText"] else { Issue.record("get"); return }
            #expect(html.contains("Example Domain"))
            guard case .object(let c) = try await call("network.curl", ["id": .string(flowId)]), case .string(let curl)? = c["curl"] else {
                Issue.record("curl"); return
            }
            #expect(curl.hasPrefix("curl ") && curl.contains("https://example.com/?\(marker)"))
            print("E2E curl: \(curl.prefix(300))")
            guard case .object(let off) = try await call("network.detach") else { Issue.record("detach"); return }
            #expect(off["attached"] == .bool(false))
        }
        let proxy = try await adb.run(["shell", "settings get global http_proxy"], serial: serial, timeout: .seconds(10)).stdout
        #expect(proxy.trimmingCharacters(in: .whitespacesAndNewlines) == ":0")
    }
} }
