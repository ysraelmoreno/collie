import Testing
import Foundation
import os
import CollieDevice
@testable import CollieDaemonKit

/// b5 (findings 7 and 9 of engine in rev-device-flows-d1-d7): a failed Android density read is not cached, concurrent
/// reads share one adb call, and an iOS viewer frame is decoded only while the flow log is on.
/// Nested in DeviceCommandTests: its tests change the process-wide adb env, so they run apart from these.
extension DeviceCommandTests {
    @Suite struct FlowMinorsTests {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowminors-\(UUID().uuidString.prefix(8))")
        var calls: URL { dir.appendingPathComponent("density-calls") }

        /// A fake adb: every `wm density` appends a line to `calls`; with `failFirst` the first one exits 1.
        func service(failFirst: Bool = false) throws -> DeviceService {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let adb = dir.appendingPathComponent("adb")
            let fail = failFirst ? "[ \"$(wc -l < '\(calls.path)')\" -eq 1 ] && exit 1" : ":"
            try """
            #!/bin/sh
            case "$*" in *density*) echo x >> '\(calls.path)'; \(fail); echo "Physical density: 320";; esac
            exit 0
            """.write(to: adb, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
            return DeviceService(root: dir, runDir: dir, adb: { adb }, emit: { _, _, _ in })
        }
        func adbCalls() -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        let small = UINode(ref: "e", cls: "android.widget.Button", text: "a", desc: "", id: "b",
                           bounds: CGRect(x: 0, y: 0, width: 80, height: 80), clickable: true, depth: 1, parent: nil)   // 40 dp at 320

        @Test func failedReadIsRetriedAndTheSecondShowsSmallTargets() async throws {
            defer { try? FileManager.default.removeItem(at: dir) }
            let s = try service(failFirst: true)
            let first = await s.density("emu-1")
            #expect(first == nil)
            #expect(ScreenAccessibility.summary([small], platform: .android(density: first)) == nil)
            let second = await s.density("emu-1")
            #expect(second == 2)
            #expect(ScreenAccessibility.summary([small], platform: .android(density: second)) == "0 sem nome, 1 alvos pequenos")
            #expect(adbCalls() == 2)
        }

        @Test func successIsReadOnce() async throws {
            defer { try? FileManager.default.removeItem(at: dir) }
            let s = try service()
            #expect(await s.density("emu-1") == 2)
            #expect(await s.density("emu-1") == 2)
            #expect(adbCalls() == 1)
        }

        @Test func concurrentReadsCallAdbOnce() async throws {
            defer { try? FileManager.default.removeItem(at: dir) }
            let s = try service()
            async let a = s.density("emu-1")
            async let b = s.density("emu-1")
            let (x, y) = await (a, b)
            #expect(x == 2 && y == 2)
            #expect(adbCalls() == 1)
        }

        @Test func iosFrameIsNotDecodedWithTheLogOff() throws {
            let decoded = OSAllocatedUnfairLock(initialState: 0)
            let count: @Sendable (Data) -> SimInput? = { d in decoded.withLock { $0 += 1 }; return DeviceService.decodeSim(d) }
            let down = OSAllocatedUnfairLock<(x: Int32, y: Int32)?>(initialState: nil)
            let frame = try JSONEncoder().encode(SimInput.tap(x: 12.6, y: 30))
            #expect(DeviceService.viewerTap(frame, ios: true, logOn: { false }, down: down, decode: count) == nil)
            #expect(decoded.withLock { $0 } == 0)
            #expect(DeviceService.viewerTap(frame, ios: true, logOn: { true }, down: down, decode: count) == "12,30")
            #expect(decoded.withLock { $0 } == 1)
        }

        @Test func androidTapIsRecordedOnlyWithTheLogOn() {
            let down = OSAllocatedUnfairLock<(x: Int32, y: Int32)?>(initialState: nil)
            let press = Scrcpy.touch(.down, x: 100, y: 200, width: 720, height: 1280), lift = Scrcpy.touch(.up, x: 100, y: 200, width: 720, height: 1280)
            _ = DeviceService.viewerTap(press, ios: false, logOn: { false }, down: down)
            #expect(DeviceService.viewerTap(lift, ios: false, logOn: { false }, down: down) == nil)
            _ = DeviceService.viewerTap(press, ios: false, logOn: { true }, down: down)
            #expect(DeviceService.viewerTap(lift, ios: false, logOn: { true }, down: down) == "100,200")
        }
    }
}
