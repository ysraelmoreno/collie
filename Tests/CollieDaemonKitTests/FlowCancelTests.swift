import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device for c2: records when each command starts and ends; `during` runs inside a command (the hangup, while
/// that step is in flight), `fail` makes a command throw, `screens` answers `then: screen` in order.
private actor Device {
    var log: [String] = []
    var screens: [[String: JSONValue]]
    let during: [Int: @Sendable () -> Void]
    let fail: Int?
    init(screens: [[String: JSONValue]] = [], during: [Int: @Sendable () -> Void] = [:], fail: Int? = nil) {
        self.screens = screens; self.during = during; self.fail = fail
    }
    var started: Int { log.filter { $0.hasPrefix("start") }.count }
    func act(_ c: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let n = started + 1
        log.append("start \(n)")
        during[n]?()
        await Task.yield()   // the step still in flight after the hangup
        log.append("end \(n)")
        if fail == n { throw ProtocolError(code: .notFound, message: "no 'Pagar' on screen") }
        guard a["then"] == .string("screen") else { return .object([:]) }
        return .object(["screen": .object(screens.isEmpty ? [:] : screens.removeFirst())])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    var isSet: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}

private let five = """
{"steps":[{"action":"tap","target":"A"},{"action":"tap","target":"B","expectSig":"s2"},{"action":"tap","target":"C"},
          {"action":"key","target":"Back"},{"action":"tap","target":"D"}]}
"""

private func runner(_ d: Device, hungUp: Flag? = nil) -> FlowRunner {
    var r = FlowRunner { c, a async throws(ProtocolError) in try await d.act(c, a) }
    if let hungUp { r.hungUp = { hungUp.isSet } }
    return r
}

/// Spins (yields, no sleep) until `cond` or 10 s of wall time pass.
private func until(_ cond: @Sendable () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(10)
    while Date() < end { if await cond() { return true }; await Task.yield() }
    return false
}

/// A raw client on `path`: the request line written, the socket left open until the caller closes it.
private func rawClient(_ path: URL, _ req: Request) throws -> Int32 {
    let fd = makeSocket()
    try UnixSocketClient.connectSocket(fd, path.path) { 10_000 }
    var line = try JSONEncoder().encode(req); line.append(10)
    #expect(writeAll(fd, line, deadline: Date().addingTimeInterval(10)))
    return fd
}

private actor Seen {
    var hangup: ClientHangup?; var entered = false; var cancelled = false; var done = false
    func enter(_ h: ClientHangup?) { hangup = h; entered = true }
    func finish(cancelled c: Bool) { cancelled = c; done = true }
}

/// c2 (findings 5, 6, 8 of rev-device-flows-onda-b): `device.run` stops between steps when its client hangs up, the
/// crashes joined so far reach a failing step's error, and a rotation that fails never costs the flow log's line.
extension DeviceCommandTests {
    @Suite struct FlowCancelTests {
        @Test func hangupDuringStep2OfFiveStopsBeforeStep3AndStep2FinishesWhole() async throws {
            let gone = Flag()
            let d = Device(screens: [["sig": .string("s2")]], during: [2: { gone.set() }])
            await #expect(throws: ProtocolError(code: .timeout, message: "plan cancelled before step 3 (done: 2)")) {
                try await runner(d, hungUp: gone).run(try FlowPlan.parse(Data(five.utf8)))
            }
            #expect(await d.log == ["start 1", "end 1", "start 2", "end 2"])
        }

        @Test func hangupBeforeTheFirstStepTouchesNothing() async throws {
            let gone = Flag(); gone.set()
            let d = Device()
            await #expect(throws: ProtocolError.self) { try await runner(d, hungUp: gone).run(try FlowPlan.parse(Data(five.utf8))) }
            #expect(await d.log.isEmpty)
        }

        @Test func aClientThatStaysRunsEveryStep() async throws {
            let d = Device(screens: [["sig": .string("s2")]])
            let r = try await runner(d, hungUp: Flag()).run(try FlowPlan.parse(Data(five.utf8)))
            #expect(r == .object(["ok": .bool(true), "steps": .number(5)]))
            #expect(await d.started == 5)
        }

        @Test func aStepFailingAfterACrashCarriesTheErrors() async throws {
            let plan = #"{"steps":[{"action":"tap","target":"Carrinho","expectSig":"s1"},{"action":"tap","target":"Pagar"}]}"#
            let d = Device(screens: [["sig": .string("s1"), "errors": .array([.string("FATAL EXCEPTION: main (com.loja)")])]], fail: 2)
            do {
                _ = try await runner(d).run(try FlowPlan.parse(Data(plan.utf8)))
                Issue.record("the failing step should throw")
            } catch {
                #expect(error.code == .notFound)
                #expect(error.message.hasPrefix("step 2 (tap Pagar): no 'Pagar' on screen"))
                #expect(error.message.contains("FATAL EXCEPTION: main (com.loja)"))
            }
        }

        @Test func aStepFailingWithNoCrashHasNoErrorsTail() async throws {
            let d = Device(fail: 1)
            await #expect(throws: ProtocolError(code: .notFound, message: "step 1 (tap A): no 'Pagar' on screen")) {
                try await runner(d).run(try FlowPlan.parse(Data(five.utf8)))
            }
        }

        @Test func deviceRunIsFlaggedNotCancelledWhenItsClientHangsUp() async throws {
            let p = URL(fileURLWithPath: "/tmp/colliet-\(UUID().uuidString.prefix(8))/s.sock")
            defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }
            let seen = Seen()
            let s = UnixSocketServer(path: p) { r in
                let h = ClientHangup.current
                await seen.enter(h)
                _ = await until { h?.isSet ?? true }
                await seen.finish(cancelled: Task.isCancelled)
                return Response(id: r.id, ok: true)
            }
            try s.start(); defer { s.stop() }
            let fd = try rawClient(p, Request(id: "r", command: "device.run"))
            #expect(await until { await seen.entered })
            #expect(await seen.hangup?.isSet == false, "a live client: not flagged")
            close(fd)   // ctrl-C on `collie device run`
            #expect(await until { await seen.done })
            #expect(await seen.hangup?.isSet == true)
            #expect(await seen.cancelled == false, "the step in flight is never cancelled")
        }

        @Test func workWaitIsStillCancelledWhenItsClientHangsUp() async throws {
            let p = URL(fileURLWithPath: "/tmp/colliet-\(UUID().uuidString.prefix(8))/s.sock")
            defer { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }
            let seen = Seen()
            let s = UnixSocketServer(path: p) { r in
                await seen.enter(ClientHangup.current)
                _ = await until { Task.isCancelled }
                await seen.finish(cancelled: Task.isCancelled)
                return Response(id: r.id, ok: true)
            }
            try s.start(); defer { s.stop() }
            let fd = try rawClient(p, Request(id: "w", command: "work.wait"))
            #expect(await until { await seen.entered })
            close(fd)
            #expect(await until { await seen.done })
            #expect(await seen.cancelled)
            #expect(await seen.hangup == nil)
        }

        @Test func aRotationThatFailsStillWritesTheLine() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("flowcancel-\(UUID().uuidString.prefix(8))")
            defer { try? fm.removeItem(at: root) }
            var l = FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled"))
            l.maxBytes = 1
            try l.setEnabled(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            try l.append(FlowAction(origin: "agent:M", action: "tap", target: "um"), now: t0)
            // the rotation rewrites actions.1 through actions.1.jsonl.tmp: a folder there makes it fail after the renames
            try fm.createDirectory(at: l.dir.appendingPathComponent("actions.1.jsonl.tmp"), withIntermediateDirectories: true)
            #expect(throws: Never.self) { try l.append(FlowAction(origin: "agent:M", action: "tap", target: "dois"), now: t0) }
            let cur = try String(contentsOf: l.file, encoding: .utf8)
            #expect(cur.contains(#""target":"dois""#))
            #expect(cur.split(separator: "\n").count == 1)
            #expect(try String(contentsOf: l.dir.appendingPathComponent("actions.1.jsonl"), encoding: .utf8).contains(#""target":"um""#))
        }
    }
}
