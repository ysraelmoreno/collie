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

@Suite struct ClaudeStatusLineRunTests {
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("csl-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    @Test func guardIsNarrow() {
        #expect(ClaudeRateLimits.invokesOurHook("collie hook claude-statusline"))
        #expect(ClaudeRateLimits.invokesOurHook("'/Applications/Collie.app/Contents/MacOS/collie' hook claude-statusline"))
        #expect(!ClaudeRateLimits.invokesOurHook("~/bin/claude-statusline.sh"))
    }
    @Test func scriptNamedClaudeStatuslineRunsAndForwards() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = d.appendingPathComponent("claude-statusline.sh")
        try "#!/bin/sh\ncat | tr a-z A-Z\n".write(to: s, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path)
        let out = ClaudeRateLimits.runUserCommand(s.path, stdin: Data("hi".utf8), env: ["PATH": "/usr/bin:/bin"])
        #expect(out == Data("HI".utf8))
    }
    @Test func timeoutKillsTheWholeGroupAndKeepsPartialOutput() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let pidFile = d.appendingPathComponent("pid").path
        // backgrounded sleep (inherits the group) + the shell itself hangs; some output first
        let cmd = "echo partial; sleep 30 & echo $! > '\(pidFile)'; trap '' TERM; sleep 30"
        let t0 = Date()
        let out = ClaudeRateLimits.runUserCommand(cmd, stdin: Data(), env: ["PATH": "/usr/bin:/bin"], timeout: 1)
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(out == Data("partial\n".utf8))
        let child = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        #expect(kill(child, 0) == -1 && errno == ESRCH)   // the pgid is the shell's pid; the backgrounded sleep must be gone too
        #expect(kill(-child, 0) == -1)
    }
}
