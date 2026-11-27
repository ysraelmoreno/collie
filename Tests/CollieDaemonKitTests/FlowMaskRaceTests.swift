import Testing
import Foundation
import os
import CollieCore
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private extension DeviceService {
    /// The device under `tracked`, staged by the test (no adb).
    func stage(_ f: @escaping @Sendable (String, Panel, [String: JSONValue]) async throws(ProtocolError) -> JSONValue) { performSeam = f }
    func put(_ id: UUID, _ nodes: [UINode]) { refs[id] = nodes }
    func probing(_ serial: String) -> Bool { densityProbe[serial] != nil }
    func provenAt(_ id: UUID) -> Int? { flowFreshAt[id] }
}

private let plain = [UINode(ref: "e1", cls: "android.widget.EditText", text: "Nome", desc: "", id: "", bounds: .zero, clickable: true, depth: 0)]
private let down = Scrcpy.touch(.down, x: 100, y: 200, width: 720, height: 1280)
private let move = Scrcpy.touch(.move, x: 120, y: 260, width: 720, height: 1280)
private let up = Scrcpy.touch(.up, x: 120, y: 260, width: 720, height: 1280)

/// A device service with no adb, its flow log on, one Android panel, and the device staged per test.
private struct Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowmask-\(UUID().uuidString.prefix(8))")
    let panel = Panel(id: UUID(), name: "p", pluginId: "device", placement: .canvas, state: ["serial": .string("emu-1")])
    let s: DeviceService
    let log: FlowActionLog
    let lift = OSAllocatedUnfairLock<(x: Int32, y: Int32)?>(initialState: nil)
    init(wm: (@Sendable (String) async -> String?)? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = FlowActionLog(paddock: dir, flag: dir.appendingPathComponent("flag/enabled"))
        try log.setEnabled(true)
        s = DeviceService(root: dir, runDir: dir, adb: { nil }, wmDensity: wm, now: now, emit: { _, _, _ in })
    }
    /// A viewer frame through the `onFrame` path, synchronously.
    func frame(_ d: Data, ios: Bool = false) { _ = DeviceService.viewerFrame(d, ios: ios, panel: panel.id, gen: s.flowGen, forward: { _ in }, flowLog: nil, down: lift) }
    func run(_ c: String, _ a: [String: JSONValue] = [:]) async throws {
        _ = try await s.run(c, panel: panel, args: a, cwd: nil, flow: FlowRecorder(origin: "agent:A", log: log))
    }
    /// The `text` of each logged line.
    func texts() async -> [String?] {
        await s.flowFlushed()
        return ((try? String(contentsOf: log.file, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }.map { $0["text"] }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// c3 (findings 3, 7 and 9 of rev-device-flows-onda-b): the screen generation moves synchronously, so no viewer touch
/// races the mask; only a touch down marks the screen spent; a failing density read backs off and never holds a screen.
@Suite struct FlowMaskRaceTests {
    @Test func viewerTouchWhileTheTextIsTypedMasksIt() async throws {
        let r = try Rig(); defer { r.cleanup() }
        let touch = OSAllocatedUnfairLock(initialState: true)
        await r.s.stage { [s = r.s, r] c, p, _ async throws(ProtocolError) -> JSONValue in
            if c == "device.ui" { await s.put(p.id, plain) }
            if c == "device.text", touch.withLock({ $0 }) { r.frame(down) }   // after the check, before the text ends
            return .object([:])
        }
        try await r.run("device.ui")
        try await r.run("device.text", ["text": .string("ana")])
        touch.withLock { $0 = false }
        try await r.run("device.ui")
        try await r.run("device.text", ["text": .string("bia")])
        #expect(await r.texts() == [FlowActionLog.mask, "bia"])
    }

    @Test func viewerTapOnThePasswordFieldThenAnImmediateTextIsMasked() async throws {
        let r = try Rig(); defer { r.cleanup() }
        await r.s.stage { [s = r.s] c, p, _ async throws(ProtocolError) -> JSONValue in
            if c == "device.ui" { await s.put(p.id, plain) }
            return .object([:])
        }
        try await r.run("device.ui")
        r.frame(down)   // the viewer taps the password field: no Task, the generation moved already
        try await r.run("device.text", ["text": .string("hunter2")])
        #expect(await r.texts() == [FlowActionLog.mask])
    }

    @Test func readInFlightDuringATouchIsNotFresh() async throws {
        let r = try Rig(); defer { r.cleanup() }
        let touch = OSAllocatedUnfairLock(initialState: true)
        await r.s.stage { [s = r.s, r] c, p, _ async throws(ProtocolError) -> JSONValue in
            if touch.withLock({ $0 }) { r.frame(down) }
            await s.put(p.id, plain)
            return .object([:])
        }
        try await r.run("device.ui")
        #expect(await !r.s.flowFresh(r.panel.id))
        touch.withLock { $0 = false }
        try await r.run("device.ui")
        #expect(await r.s.flowFresh(r.panel.id))
    }

    @Test func androidMoveAndUpDoNotMarkTheScreenSpentDownDoes() async throws {
        let r = try Rig(); defer { r.cleanup() }
        await r.s.stage { [s = r.s] _, p, _ async throws(ProtocolError) -> JSONValue in await s.put(p.id, plain); return .object([:]) }
        try await r.run("device.ui")
        r.frame(move); r.frame(up)
        #expect(await r.s.flowFresh(r.panel.id))
        #expect(r.s.flowGen.value(r.panel.id) == 0)
        r.frame(down)
        #expect(await !r.s.flowFresh(r.panel.id))
        #expect(r.s.flowGen.value(r.panel.id) == 1)
        r.frame(Scrcpy.text("a"))   // a key or text is not a touch: it marks
        #expect(r.s.flowGen.value(r.panel.id) == 2)
    }

    @Test func iosGestureMarksAFrameThatIsNoGestureDoesNot() async throws {
        let r = try Rig(); defer { r.cleanup() }
        r.frame(Data(#"{"move":{"x":1,"y":2}}"#.utf8), ios: true)   // not a SimInput: SimSession drops it
        r.frame(move, ios: true)
        #expect(r.s.flowGen.value(r.panel.id) == 0)
        r.frame(try JSONEncoder().encode(SimInput.tap(x: 10, y: 20)), ios: true)
        #expect(r.s.flowGen.value(r.panel.id) == 1)
        r.frame(try JSONEncoder().encode(SimInput.swipe(x1: 1, y1: 2, x2: 3, y2: 400, seconds: 0.3)), ios: true)
        #expect(r.s.flowGen.value(r.panel.id) == 2)
    }

    @Test func frameMovesTheGenerationBeforeTheDeviceGetsIt() throws {
        let r = try Rig(); defer { r.cleanup() }
        let seen = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let gen = r.s.flowGen, id = r.panel.id
        _ = DeviceService.viewerFrame(down, ios: false, panel: id, gen: gen, forward: { _ in seen.withLock { $0 = gen.value(id) } },
                                      flowLog: nil, down: r.lift)
        #expect(seen.withLock { $0 } == 1)
    }

    @Test func failedDensityBacksOffWithoutCallingAdbThenTriesAgain() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let t0 = ContinuousClock.now
        let clock = OSAllocatedUnfairLock(initialState: t0)
        let r = try Rig(wm: { _ in calls.withLock { $0 += 1; return $0 == 1 ? nil : "Physical density: 320" } },   // the first fails at once
                        now: { clock.withLock { $0 } })
        defer { r.cleanup() }
        #expect(await r.s.densityKnown("emu-1") == nil)   // never waits: the read runs in the background
        await r.s.densitySettled("emu-1")
        #expect(calls.withLock { $0 } == 1)
        clock.withLock { $0 = t0 + .seconds(29) }
        #expect(await r.s.densityKnown("emu-1") == nil)
        #expect(await !r.s.probing("emu-1"))   // within the backoff: back at once, no Task
        await r.s.densitySettled("emu-1")
        #expect(calls.withLock { $0 } == 1)
        clock.withLock { $0 = t0 + .seconds(31) }
        #expect(await r.s.densityKnown("emu-1") == nil)
        await r.s.densitySettled("emu-1")
        #expect(calls.withLock { $0 } == 2)
        #expect(await r.s.densityKnown("emu-1") == 2)
    }

    @Test func stopAndCloseNeverLetAReadInFlightCountAgain() async throws {
        let r = try Rig(); defer { r.cleanup() }
        let during = OSAllocatedUnfairLock(initialState: "stop")
        await r.s.stage { [s = r.s] _, p, _ async throws(ProtocolError) -> JSONValue in
            await s.put(p.id, plain)
            switch during.withLock({ $0 }) {
            case "stop": await s.stop()
            case "close": await s.panelClosed(p.id)
            default: break
            }
            return .object([:])
        }
        try await r.run("device.ui")   // a read in flight while the daemon stops (no panel was ever bumped)
        #expect(await !r.s.flowFresh(r.panel.id))
        during.withLock { $0 = "" }
        try await r.run("device.ui")
        #expect(await r.s.flowFresh(r.panel.id))
        let before = r.s.flowGen.value(r.panel.id)
        during.withLock { $0 = "close" }
        try await r.run("device.ui")
        #expect(await r.s.provenAt(r.panel.id) == nil)   // the panel's entry is gone and not written back
        #expect(r.s.flowGen.value(r.panel.id) > before)   // moved up, never zeroed
        #expect(await !r.s.flowFresh(r.panel.id))
    }
}
