import Testing
import Foundation

@Suite struct CLITests {
    @Test func cliListPrintsNames() async throws {
        try await withRig { rig in
            let r = try await runCollie(["list"], env: rig.env)
            #expect(r.status == 0)
            #expect(r.out.contains("B\tcustom\trunning"))
            let j = try await runCollie(["--json", "list"], env: rig.env)
            #expect(j.status == 0 && j.out.hasPrefix("["))
        }
    }
    @Test func cliErrorGoesToStderr() async throws {
        try await withRig { rig in
            let r = try await runCollie(["ask", "Zed", "oi"], env: rig.env)
            #expect(r.status == 1)
            #expect(r.err.hasPrefix("collie: "))
        }
    }
    @Test func cliUsageExit2() async throws {
        let r = try await runCollie(["ask"], env: ["COLLIE_SOCKET": "/nonexistent/x.sock"])
        #expect(r.status == 2)
        #expect((try await runCollie([], env: [:])).status == 2)
        let h = try await runCollie(["help"], env: [:])
        #expect(h.status == 0 && h.out.contains("ask") && h.out.contains("admin spawn"))
    }
    @Test func promptHookWithoutPromptLogsSilently() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-hooklog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await runCollie(["hook", "claude-prompt"], env: ["COLLIE_LOG_DIR": dir.path], stdin: "not json")
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty, "\(r)")
        let log = try String(contentsOf: dir.appendingPathComponent("hooks.log"), encoding: .utf8)
        #expect(log.contains("claude-prompt"), "\(log)")
    }
    @Test func oversizedWorkHookDrainsStdin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-hooklog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // the whole payload is read (the writer never gets a broken pipe), then dropped
        let r = try await runCollie(["hook", "claude-tool"], env: ["COLLIE_LOG_DIR": dir.path], stdin: String(repeating: "x", count: 512 << 10))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty, "\(r)")
        let log = try String(contentsOf: dir.appendingPathComponent("hooks.log"), encoding: .utf8)
        #expect(log.contains("over 64 KiB"), "\(log)")
    }
    @Test func cliReportsDaemonDown() async throws {
        let r = try await runCollie(["list"], env: ["COLLIE_SOCKET": "/nonexistent/x.sock"])
        #expect(r.status == 3)
        #expect(r.err.contains("collied"))
    }
    @Test func cliAskAndAdmin() async throws {
        try await withRig { rig in
            let r = try await runCollie(["ask", "B", "hi", "there"], env: rig.env)
            #expect(r.status == 0 && r.out.contains("answer:hi there") && r.out.hasSuffix("\n"))
            // admin is the user's shell, outside any terminal: the CLI refuses it with COLLIE_TERMINAL_ID set
            let user = rig.env.filter { $0.key != "COLLIE_TERMINAL_ID" && $0.key != "COLLIE_TOKEN" }
            let s = try await runCollie(["admin", "spawn", "C", "--preset", "shell", "--cwd", "/tmp"], env: user)
            #expect(s.status == 0 && UUID(uuidString: s.out.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
            let k = try await runCollie(["admin", "kill", "C"], env: user)
            #expect(k.status == 0)
        }
    }
}
