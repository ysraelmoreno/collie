import Testing
import Foundation
@testable import CollieCore

@Suite struct ClaudeRateLimitsTests {
    private func obj(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    private let both = #"{"session_id":"s","cwd":"/x","transcript_path":"/t","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}"#

    @Test func extractsBothWindows() throws {
        let o = try #require(obj(ClaudeRateLimits.extract(Data(both.utf8), now: Date(timeIntervalSince1970: 100))))
        #expect((o["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 23.5)
        #expect((o["seven_day"] as? [String: Any])?["resets_at"] as? Int == 1738857600)
        #expect(o["recorded_at"] as? Int == 100)
    }
    @Test func extractsFiveHourOnly() throws {
        let j = #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#
        let o = try #require(obj(ClaudeRateLimits.extract(Data(j.utf8))))
        #expect(o["five_hour"] != nil); #expect(o["seven_day"] == nil)
    }
    @Test func nilWithoutRateLimits() {
        #expect(ClaudeRateLimits.extract(Data(#"{"cwd":"/x"}"#.utf8)) == nil)
        #expect(ClaudeRateLimits.extract(Data(#"{"rate_limits":{}}"#.utf8)) == nil)
        #expect(ClaudeRateLimits.extract(Data("nope".utf8)) == nil)
    }
    @Test func dropsOtherFields() throws {
        let o = try #require(obj(ClaudeRateLimits.extract(Data(both.utf8))))
        #expect(Set(o.keys) == ["five_hour", "seven_day", "recorded_at"])
    }
    @Test func userCommandFromSettings() {
        let s = #"{"statusLine":{"type":"command","command":"~/bar.sh"}}"#
        #expect(ClaudeRateLimits.userStatusLineCommand(settings: Data(s.utf8)) == "~/bar.sh")
    }
    @Test func noUserCommand() {
        #expect(ClaudeRateLimits.userStatusLineCommand(settings: Data("{}".utf8)) == nil)
        #expect(ClaudeRateLimits.userStatusLineCommand(settings: Data(#"{"statusLine":{"type":"text","command":"x"}}"#.utf8)) == nil)
    }
    @Test func writeIs0600AndAtomic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ClaudeRateLimits.write(Data("{}".utf8), to: dir)
        try ClaudeRateLimits.write(Data("{\"a\":1}".utf8), to: dir)
        let f = dir.appendingPathComponent(ClaudeRateLimits.fileName)
        #expect(try Data(contentsOf: f) == Data("{\"a\":1}".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }
    @Test func usageDirResolution() {
        #expect(ClaudeRateLimits.usageDir(env: ["COLLIE_USAGE_DIR": "/u"])?.path == "/u")
        #expect(ClaudeRateLimits.usageDir(env: ["COLLIE_SOCKET": "/r/run/collied.sock"])?.path == "/r/usage")
        #expect(ClaudeRateLimits.usageDir(env: [:]) == nil)
    }
}
