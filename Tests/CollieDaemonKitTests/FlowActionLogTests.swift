import Testing
import Foundation
@testable import CollieDaemonKit

/// d4: the device action log, opt-in per paddock. Fixed dates, no clock, no sleep.
@Suite struct FlowActionLogTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowlog-\(UUID().uuidString.prefix(8))")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var log: FlowActionLog { FlowActionLog(paddock: root, flag: root.appendingPathComponent("daemon/enabled")) }
    let tap = FlowAction(origin: "agent:M", action: "tap", target: "text:Entrar", sigBefore: "s1", sigAfter: "s2", app: "com.x", appVersion: "1.2")

    func lines(_ name: String = "actions.jsonl") throws -> [[String: String]] {
        try String(contentsOf: log.dir.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
    }
    func perms(_ u: URL) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) }

    @Test func offWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try log.append(tap, now: t0) == false)
        #expect(!FileManager.default.fileExists(atPath: log.dir.path))
    }

    @Test func onWritesOneLinePerActionWithEveryField() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try log.setEnabled(true)
        #expect(try log.append(tap, now: t0))
        try log.append(FlowAction(origin: "panel", action: "key", target: "Back"), now: t0.addingTimeInterval(1))
        let l = try lines()
        #expect(l.count == 2)
        #expect(l[0] == ["t": "2027-01-15T08:00:00.000Z", "origin": "agent:M", "action": "tap", "target": "text:Entrar",
                         "sigBefore": "s1", "sigAfter": "s2", "app": "com.x", "appVersion": "1.2"])
        #expect(l[1]["origin"] == "panel" && l[1]["action"] == "key")
    }

    @Test func passwordIsMaskedAndLongTextTruncated() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try log.setEnabled(true)
        try log.append(FlowAction(origin: "agent:M", action: "text", text: "hunter2", secure: true), now: t0)
        try log.append(FlowAction(origin: "agent:M", action: "text", text: String(repeating: "a", count: 200)), now: t0)
        let l = try lines()
        #expect(l[0]["text"] == "•••")
        #expect(l[1]["text"] == String(repeating: "a", count: 80))
        #expect(!(try String(contentsOf: log.file, encoding: .utf8)).contains("hunter2"))
    }

    @Test func newlineInTextStaysOneJSONLine() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try log.setEnabled(true)
        try log.append(FlowAction(origin: "panel", action: "text", text: "a\nb\r\nc"), now: t0)
        let l = try lines()
        #expect(l.count == 1 && l[0]["text"] == "a\nb\r\nc")
    }

    @Test func permissionsAre0600And0700() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try log.setEnabled(true)
        try log.append(tap, now: t0)
        #expect(try perms(log.dir) == 0o700)
        #expect(try perms(log.file) == 0o600)
        #expect(try perms(log.flag) == 0o600)
    }

    @Test func rotatesBySizeAndKeepsThreeFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var small = log; small.maxBytes = 1   // every append past the first rotates
        try small.setEnabled(true)
        for i in 0..<5 { try small.append(FlowAction(origin: "panel", action: "tap", target: "n\(i)"), now: t0) }
        let names = try FileManager.default.contentsOfDirectory(atPath: log.dir.path).filter { $0.hasPrefix("actions") }.sorted()
        #expect(names == ["actions.1.jsonl", "actions.2.jsonl", "actions.jsonl"])
        #expect(try lines()[0]["target"] == "n4")
        #expect(try lines("actions.1.jsonl")[0]["target"] == "n3")
        #expect(try lines("actions.2.jsonl")[0]["target"] == "n2")
        #expect(try perms(log.dir.appendingPathComponent("actions.1.jsonl")) == 0o600)
    }

    @Test func rotationDropsLinesOlderThan30Days() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var small = log; small.maxBytes = 200   // two lines pass it
        try small.setEnabled(true)
        try small.append(FlowAction(origin: "panel", action: "tap", target: "old"), now: t0)
        try small.append(FlowAction(origin: "panel", action: "tap", target: "recent"), now: t0.addingTimeInterval(20 * 86_400))
        let later = t0.addingTimeInterval(40 * 86_400)
        try small.append(FlowAction(origin: "panel", action: "tap", target: "now"), now: later)   // past 200 bytes: rotates
        #expect(try lines("actions.1.jsonl").map { $0["target"] } == ["recent"])
        #expect(try lines().map { $0["target"] } == ["now"])
    }

    @Test func offKeepsTheLogAndStopsWriting() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try log.setEnabled(true)
        try log.append(tap, now: t0)
        try log.setEnabled(false)
        #expect(!log.enabled)
        #expect(try log.append(tap, now: t0) == false)
        #expect(try lines().count == 1)
        guard case .object(let s) = log.status() else { Issue.record("status"); return }
        #expect(s["enabled"] == .bool(false) && s["path"] == .string(log.file.path))
    }
}
