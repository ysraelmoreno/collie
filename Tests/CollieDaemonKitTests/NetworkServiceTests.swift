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

/// Records every call; `failAttach` makes attach throw.
private final class FakeDevice: NetworkDevice, @unchecked Sendable {
    let calls = OSAllocatedUnfairLock(initialState: [String]())
    let failAttach: Bool
    init(failAttach: Bool = false) { self.failAttach = failAttach }
    var log: [String] { calls.withLock { $0 } }
    func attach(serial: String, port: Int, caCert: URL) async throws(ProtocolError) -> DeviceNetworkSetup.AttachResult {
        calls.withLock { $0.append("attach \(serial) \(port)") }
        if failAttach { throw ProtocolError(code: .unavailable, message: "not rootable") }
        return .init(sdk: 37, hash: "c8750f0d", system: "mounted 146 CAs", user: "added", previousProxy: "null")
    }
    func detach(serial: String, port: Int?) async throws(ProtocolError) -> [String] {
        calls.withLock { $0.append("detach \(serial) \(port.map(String.init) ?? "nil")") }
        return ["proxy: restored :0"]
    }
    func reconcile(serial: String, activePort: Int?, caCert: URL?) async throws(ProtocolError) -> DeviceNetworkSetup.Reconcile {
        calls.withLock { $0.append("reconcile \(serial) \(activePort.map(String.init) ?? "nil")") }
        return .none
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

    private func rig(device: FakeDevice = FakeDevice(), online: [String] = []) -> Rig {
        let proxies = OSAllocatedUnfairLock(initialState: [FakeProxy]())
        let events = OSAllocatedUnfairLock(initialState: [(String, String, JSONValue)]())
        let ports = OSAllocatedUnfairLock(initialState: 40000)   // first proxy: 40001
        let s = NetworkService(pollInterval: .seconds(3600),
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

    @Test func failedDeviceAttachStopsTheProxy() async throws {
        let r = rig(device: FakeDevice(failAttach: true))
        await #expect(throws: ProtocolError.self) { try await r.service.attach("emulator-5560") }
        #expect(r.proxy.stopped)
        #expect(await r.service.attached.isEmpty)
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
