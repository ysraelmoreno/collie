import Testing
import Foundation

@Suite struct CLITests {
    @Test func cliListPrintsNames() async throws {
        try await withRig { rig in
            let r = try await runOrq(["list"], env: rig.env)
            #expect(r.status == 0)
            #expect(r.out.contains("B\tcustom\trunning"))
            let j = try await runOrq(["--json", "list"], env: rig.env)
            #expect(j.status == 0 && j.out.hasPrefix("["))
        }
    }
    @Test func cliErrorGoesToStderr() async throws {
        try await withRig { rig in
            let r = try await runOrq(["ask", "Zed", "oi"], env: rig.env)
            #expect(r.status == 1)
            #expect(r.err.hasPrefix("orq: "))
        }
    }
    @Test func cliUsageExit2() async throws {
        let r = try await runOrq(["ask"], env: ["ORQ_SOCKET": "/nonexistent/x.sock"])
        #expect(r.status == 2)
        #expect((try await runOrq([], env: [:])).status == 2)
        let h = try await runOrq(["help"], env: [:])
        #expect(h.status == 0 && h.out.contains("ask") && h.out.contains("admin spawn"))
    }
    @Test func promptHookWithoutPromptLogsSilently() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orq-hooklog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await runOrq(["hook", "claude-prompt"], env: ["ORQ_LOG_DIR": dir.path], stdin: "not json")
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty, "\(r)")
        let log = try String(contentsOf: dir.appendingPathComponent("hooks.log"), encoding: .utf8)
        #expect(log.contains("claude-prompt"), "\(log)")
    }
    @Test func oversizedWorkHookDrainsStdin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orq-hooklog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // the whole payload is read (the writer never gets a broken pipe), then dropped
        let r = try await runOrq(["hook", "claude-tool"], env: ["ORQ_LOG_DIR": dir.path], stdin: String(repeating: "x", count: 512 << 10))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty, "\(r)")
        let log = try String(contentsOf: dir.appendingPathComponent("hooks.log"), encoding: .utf8)
        #expect(log.contains("over 64 KiB"), "\(log)")
    }
    @Test func cliReportsDaemonDown() async throws {
        let r = try await runOrq(["list"], env: ["ORQ_SOCKET": "/nonexistent/x.sock"])
        #expect(r.status == 3)
        #expect(r.err.contains("orqd"))
    }
    @Test func cliAskAndAdmin() async throws {
        try await withRig { rig in
            let r = try await runOrq(["ask", "B", "hi", "there"], env: rig.env)
            #expect(r.status == 0 && r.out.contains("answer:hi there") && r.out.hasSuffix("\n"))
            let s = try await runOrq(["admin", "spawn", "C", "--preset", "shell", "--cwd", "/tmp"], env: rig.env)
            #expect(s.status == 0 && UUID(uuidString: s.out.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
            let k = try await runOrq(["admin", "kill", "C"], env: rig.env)
            #expect(k.status == 0)
        }
    }
}
