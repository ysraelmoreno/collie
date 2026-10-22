import Testing
import Foundation
import Synchronization
import CollieCore
import CollieProtocol
import CollieClient
@testable import CollieDaemonKit

/// What the fake host saw, and how it answers: url "hang" sleeps 60 s first, "big" returns > 1 MiB.
private final class FakeHost: Sendable {
    let calls = Mutex<[(UUID, String, [String: JSONValue])]>([])
    let tag: String
    init(tag: String = "h") { self.tag = tag }
    func make(_ d: Daemon, _ p: Paths) -> HostConnection {
        HostConnection(paths: p, token: { d.adminToken }) { [self] panel, command, args, _ throws(ProtocolError) in
            calls.withLock { $0.append((panel, command, args)) }
            if args["url"] == .string("hang") { try? await Task.sleep(for: .seconds(60)) }
            if args["url"] == .string("big") { return .string(String(repeating: "x", count: 1_100_000)) }
            if args["url"] == .string("fail") { throw ProtocolError(code: .invalidArgs, message: "bad url") }
            return .object(["host": .string(tag), "url": args["url"] ?? .null])
        }
    }
    var count: Int { calls.withLock { $0.count } }
}

private struct Term { var id: String; var token: String }

private func adminCall(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func termCall(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func newTerm(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let (id, r) = try await spawn(d, p, name)
    guard !id.isEmpty else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func panelId(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Panel {
    let r = try await adminCall(d, p, "ui.snapshot")
    let s = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
    return try #require(s.panels.first { $0.name == name })
}
/// Polls an admin plugin call until the host answers (it connects asynchronously).
private func waitForHost(_ d: Daemon, _ p: Paths, panel: String, tag: String = "h") async throws -> Bool {
    await waitFor(10) {
        let r = try? await adminCall(d, p, "browser.navigate", ["panel": panel, "url": "ping"])
        if case .object(let o)? = r?.result { return o["host"] == .string(tag) }
        return false
    }
}

private func hostCall(_ h: PluginHost, _ panel: Panel, url: String, timeout: Duration) async -> Result<JSONValue, ProtocolError> {
    do throws(ProtocolError) {
        return .success(try await h.call(panel: panel, command: "browser.navigate", args: ["url": .string(url)], timeout: timeout))
    } catch { return .failure(error) }
}

@Suite(.serialized) struct PluginHostTests {
    @Test func callWithoutHostFailsFast() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let t0 = ContinuousClock.now
            let r = try await adminCall(d, p, "browser.navigate", ["panel": "web", "url": "https://x"])
            #expect(r.error == ProtocolError(code: .unavailable, message: "Collie app is not running"), "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(10))   // refused at once, not after the 30 s call timeout
        }
    }

    @Test func hostStreamIsAdminOnly() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            let a = try await newTerm(d, p, "A")
            await #expect(throws: ProtocolError(code: .unauthorized, message: "Invalid admin token")) {
                _ = try await StreamClient.open(Request(id: "h", terminalId: a.id, token: a.token, command: "ui.host"), path: p.socket)
            }
        }
    }

    @Test func callRoundTrip() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            let a = try await newTerm(d, p, "A")
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            #expect(try await adminCall(d, p, "admin.leash", ["a": "A", "b": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let web = try await panelId(d, p, "web")
            let r = try await termCall(p, a, "browser.navigate", ["panel": "web", "url": "https://x"])
            #expect(r.result == .object(["host": .string("h"), "url": .string("https://x")]), "\(r)")
            let last = try #require(fake.calls.withLock { $0.last })
            #expect(last.0 == web.id && last.1 == "browser.navigate" && last.2 == ["url": .string("https://x")])
            // the only reachable browser panel is the default
            #expect(try await termCall(p, a, "browser.text").ok)
            // host errors pass through; oversized results are refused
            #expect(try await termCall(p, a, "browser.navigate", ["url": "fail"]).error == ProtocolError(code: .invalidArgs, message: "bad url"))
            let big = try await termCall(p, a, "browser.navigate", ["url": "big"])
            #expect(big.error == ProtocolError(code: .internal, message: "plugin result exceeds 1 MiB"), "\(big.error.map { "\($0)" } ?? "ok")")
        }
    }

    @Test func hostTimeoutFreesCall() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let web = try await panelId(d, p, "web")
            let t0 = ContinuousClock.now
            let late = await hostCall(d.router.host, web, url: "hang", timeout: .milliseconds(500))
            #expect(late == .failure(ProtocolError(code: .timeout, message: "'browser.navigate' timed out after 0.5 s")))
            #expect(ContinuousClock.now - t0 < .seconds(10))   // the 0.5 s timeout fired (a hung call never returns)
            #expect(await d.router.host.pendingCount == 0)
            let ok = await hostCall(d.router.host, web, url: "y", timeout: .seconds(10))
            #expect(ok == .success(.object(["host": .string("h"), "url": .string("y")])))
        }
    }

    @Test func hostDropFailsPending() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start()
            #expect(try await waitForHost(d, p, panel: "web"))
            let web = try await panelId(d, p, "web")
            let base = fake.count
            let hostRef = d.router.host
            let results = Task {
                await withTaskGroup(of: ErrorCode?.self) { g in
                    for _ in 0..<PluginHost.pendingCap {
                        g.addTask {
                            if case .failure(let e) = await hostCall(hostRef, web, url: "hang", timeout: .seconds(120)) { return e.code }
                            return nil
                        }
                    }
                    return await g.reduce(into: [ErrorCode?]()) { $0.append($1) }
                }
            }
            #expect(await waitFor(10) { fake.count - base == PluginHost.pendingCap })
            // the 65th pending call is refused at once
            let busy = try await adminCall(d, p, "browser.navigate", ["panel": "web", "url": "y"])
            #expect(busy.error == ProtocolError(code: .unavailable, message: "host busy"), "\(busy)")
            let t0 = ContinuousClock.now
            host.stop()
            let codes = await results.value
            #expect(ContinuousClock.now - t0 < .seconds(10))   // failed by the drop, not the 120 s timeout
            #expect(codes.count == PluginHost.pendingCap && codes.allSatisfy { $0 == .unavailable }, "\(codes)")
            #expect(await d.router.host.pendingCount == 0)
        }
    }

    @Test func emitBecomesEvent() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let web = try await panelId(d, p, "web")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            host.emit(panel: web.id, name: "browser.loaded", payload: .object(["url": .string("https://x")]))
            var got: WorkspaceEvent?
            for _ in 0..<20 {
                guard let f = try await ev.next(timeoutSeconds: 30) else { break }
                if case .event(let e) = f, case .pluginEvent = e { got = e; break }
            }
            #expect(got == .pluginEvent(panel: web.id, name: "browser.loaded", payload: .object(["url": .string("https://x")])))
            let r = try await adminCall(d, p, "events", ["panel": "web"])
            guard case .object(let o)? = r.result, case .array(let es)? = o["events"] else { Issue.record("\(r)"); return }
            #expect(es.count == 1 && es.first.map { if case .object(let e) = $0 { return e["name"] == .string("browser.loaded") }; return false } == true)
        }
    }

    @Test func secondHostReplacesFirst() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let f1 = FakeHost(tag: "one"), h1 = f1.make(d, p)
            h1.start(); defer { h1.stop() }
            #expect(try await waitForHost(d, p, panel: "web", tag: "one"))
            let web = try await panelId(d, p, "web")
            let hostRef = d.router.host, base = f1.count
            let pending = Task { await hostCall(hostRef, web, url: "hang", timeout: .seconds(120)) }
            #expect(await waitFor(10) { f1.count > base })
            let f2 = FakeHost(tag: "two"), h2 = f2.make(d, p)
            h2.start(); defer { h2.stop() }
            let t0 = ContinuousClock.now
            #expect(await pending.value == .failure(ProtocolError(code: .unavailable, message: "Collie app disconnected")))
            #expect(ContinuousClock.now - t0 < .seconds(15))   // failed by the replacement, not the 120 s timeout
            #expect(try await waitForHost(d, p, panel: "web", tag: "two"))
            #expect(await waitFor(5) { h1.status == .replaced })
            #expect(h2.status == .connected)
            // the replaced host does not reconnect: h2 keeps the role well past h1's backoff (max 2 s)
            try await Task.sleep(for: .seconds(3))
            #expect(try await waitForHost(d, p, panel: "web", tag: "two") && h1.status == .replaced)
        }
    }

    @Test func daemonStopFailsPending() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in   // stopping twice is harmless
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let web = try await panelId(d, p, "web")
            let hostRef = d.router.host, base = fake.count
            let pending = Task { await hostCall(hostRef, web, url: "hang", timeout: .seconds(120)) }
            #expect(await waitFor(10) { fake.count > base })
            let t0 = ContinuousClock.now
            await d.stop()
            #expect(await pending.value == .failure(ProtocolError(code: .unavailable, message: "Collie app disconnected")))
            #expect(ContinuousClock.now - t0 < .seconds(15))   // failed by the stop, not the 120 s timeout
            #expect(await hostRef.pendingCount == 0)
        }
    }

    @Test func terminalWithoutLeashCannotCallCanvasPanel() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            let a = try await newTerm(d, p, "A")
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))   // admin reaches every panel
            let base = fake.count
            #expect(try await termCall(p, a, "browser.navigate", ["panel": "web", "url": "https://x"]).error?.code == .notConnected)
            #expect(try await termCall(p, a, "browser.navigate", ["url": "https://x"]).error?.code == .notFound)
            #expect(fake.count == base)
        }
    }

    @Test func dockPanelCallableByAnyTerminal() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            let a = try await newTerm(d, p, "A")
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let r = try await termCall(p, a, "browser.navigate", ["panel": "web", "url": "https://x"])
            #expect(r.result == .object(["host": .string("h"), "url": .string("https://x")]), "\(r)")
            #expect(try await termCall(p, a, "browser.navigate", ["url": "https://x"]).ok)
        }
    }

    @Test func hostCallReachesImporter() async throws {
        try await withDaemon { (d: Daemon, p: Paths) async throws in
            #expect(try await adminCall(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let fake = FakeHost(), host = fake.make(d, p)
            host.start(); defer { host.stop() }
            #expect(try await waitForHost(d, p, panel: "web"))
            let r = try await d.router.host.callApp(command: "html.snapshot", args: ["url": .string("collie-artifact://app/x")], timeout: .seconds(10))
            #expect(r == .object(["host": .string("h"), "url": .string("collie-artifact://app/x")]))
            let last = try #require(fake.calls.withLock { $0.last })
            #expect(last.0 == HostTarget.importer && last.1 == "html.snapshot")
        }
    }
}
