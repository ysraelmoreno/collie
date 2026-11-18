import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Cursor has no turn hook: idle must not end its ask while the latest frame shows the `ctrl+c to stop` footer.
@Suite(.serialized) struct CursorTurnEndTests {
    private struct Term { var id: String; var token: String }

    private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String, command: String? = nil) async throws -> Term {
        let s = try await spawn(d, p, name, preset: preset, command: command)
        #expect(s.resp.ok, "spawn \(name): \(s.resp)")
        return Term(id: s.id, token: try await tokenOf(d, s.id, echo: command == nil))
    }

    /// Reads the prompt, prints `frames`, then stays silent.
    private func agent(_ frames: String) -> String { "echo T=$COLLIE_TOKEN; read x; \(frames); exec sleep 999" }
    /// A repaint without the footer, taller than the 10 lines the check looks at.
    private let doneFrame = "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo done$i; done"

    private func ask(_ d: Daemon, _ p: Paths, preset: String, _ frames: String, timeout: Int) async throws -> Response {
        let a = try await term(d, p, "A", preset: "shell")
        _ = try await term(d, p, "B", preset: preset, command: agent(frames))
        let r = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")]))
        #expect(r.ok)
        return try await send(p, Request(id: "a", terminalId: a.id, token: a.token, command: "ask",
                                         args: ["target": .string("B"), "prompt": .string("go"), "timeout": .number(Double(timeout))]),
                              timeoutSeconds: Double(timeout) + 10)
    }

    private func source(_ r: Response) -> String? {
        guard case .object(let o)? = r.result, case .string(let s)? = o["source"] else { return nil }
        return s
    }

    @Test func cursorFooterOnLatestFrameHoldsIdle() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let r = try await ask(d, p, preset: "cursor", "echo Editing; echo 'ctrl+c to stop'", timeout: 5)
            #expect(r.error?.code == .timeout, "\(r)")
        }
    }

    @Test func cursorFooterOnlyOnOldFramesCompletesOnIdle() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let r = try await ask(d, p, preset: "cursor", "echo 'ctrl+c to stop'; echo 'ctrl+c to stop'; \(doneFrame)", timeout: 15)
            #expect(source(r) == "idle", "\(r)")
        }
    }

    @Test func nonCursorPresetIgnoresFooter() async throws {
        for preset in ["shell", "custom"] {
            try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
                let r = try await ask(d, p, preset: preset, "echo 'ctrl+c to stop'", timeout: 15)
                #expect(source(r) == "idle", "\(preset): \(r)")
            }
        }
    }
}
