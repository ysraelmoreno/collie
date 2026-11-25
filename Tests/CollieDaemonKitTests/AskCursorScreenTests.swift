import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieScreen
import CollieTerminal
@testable import CollieDaemonKit

extension AskTests {
    /// A4: a Cursor ask that ends by idleness answers with the rendered screen, not the repainted scrollback.
    @Suite struct CursorScreenAsk {
        /// Reads the prompt, repaints the whole screen 50 times (answer, bar, footer, working marker), then a last frame
        /// without the marker and stays silent.
        private static func script(echo: Bool) -> String { """
        printf "> "; read x
        frame() { printf '\\033[H\\033[J'; \(echo ? "printf '   \\n  go\\n   \\n\\n'; " : "")for n in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '  Answer line %s\\n' $n; done; printf '\\n\\n\\n  → Add a follow-up\\n\\n  Composer 2.5 · 7%%\\n  /tmp%s' "$1"; }
        i=0; while [ $i -lt 50 ]; do frame ' ctrl+c to stop'; i=$((i+1)); done
        frame ''
        exec sleep 999
        """ }

        private func ask(renderer: (@Sendable (Data, Int, Int) -> String)?, echo: Bool = true) async throws -> AskResult {
            let asks = AskCoordinator(idleQuietSeconds: 1, submitConfirmSeconds: 0.2, screenRenderer: renderer)
            let rec = TerminalRecord(id: UUID(), name: "c", preset: .cursor, command: nil, cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
            let sb = ScrollbackBuffer(spillURL: nil)
            let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", Self.script(echo: echo)], environment: [:], cwd: "/tmp"), scrollback: sb)
            await asks.attach(rec, process: p, scrollback: sb)
            return try await asks.ask(from: UUID(), to: rec.id, prompt: "go", raw: false, timeout: .seconds(20))
        }

        @Test func idleAnswerIsTheScreenWithoutTheFooter() async throws {
            let r = try await ask(renderer: ScreenRenderer.render)
            #expect(r.source == .idle)
            #expect(r.output == (1...12).map { "Answer line \($0)" }.joined(separator: "\n"), "\(r.output)")
        }

        @Test func aCutAnswerPointsToCheckScreenOfTheTarget() async throws {
            let r = try await ask(renderer: ScreenRenderer.render, echo: false)
            #expect(r.truncated && r.output.hasSuffix("(resposta cortada na altura da tela: collie check c --screen)"), "\(r.output)")
        }

        @Test func withoutARendererTheAnswerIsTheScrollback() async throws {
            let r = try await ask(renderer: nil)
            #expect(r.source == .idle && r.output.contains("Composer 2.5") && r.output.contains("Add a follow-up"), "\(r.output)")
        }
    }
}
