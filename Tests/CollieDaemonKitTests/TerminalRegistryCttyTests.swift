import Foundation
import Testing
import CollieCore
import CollieTerminal
@testable import CollieDaemonKit

private let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie-ctty").path

/// The registry starts terminals through `collie-ctty`, so the shell owns its PTY as controlling terminal.
@Suite struct TerminalRegistryCttyTests {
    private func ttyOf(helper h: String?) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = TerminalRegistry(spillDir: dir, memoryCapBytes: 1 << 16, runDir: dir, cttyHelper: h)
        let rec = TerminalRecord(id: UUID(), name: "A", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)
        let p = try await reg.spawn(rec, launch: LaunchSpec(executable: "/bin/zsh",
                                                            arguments: ["-fc", "echo tty=$(ps -o tty= -p $$); sleep 5"], cwd: "/tmp"))
        defer { p.terminate() }
        let sb = try #require(await reg.scrollback(rec.id))
        for _ in 0..<400 where !sb.text(since: 0).text.contains("tty=") { try await Task.sleep(for: .milliseconds(50)) }
        await reg.remove(rec.id)
        return sb.text(since: 0).text
    }

    @Test func spawnsThroughTheHelper() async throws {
        let out = try await ttyOf(helper: helper)
        #expect(out.contains("tty=ttys") && !out.contains("tty=??"), "\(out)")
    }

    @Test func missingHelperSpawnsDirectly() async throws {
        let out = try await ttyOf(helper: "/nonexistent/collie-ctty")
        #expect(out.contains("tty="), "\(out)")
    }
}
