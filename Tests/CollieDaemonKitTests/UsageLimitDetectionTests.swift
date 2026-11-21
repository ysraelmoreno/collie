import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

private typealias Stop = WorkLoopState.Stop

/// Claude Code's usage-limit dialog, as the scrollback's last non-empty lines show it.
private let dialog = [
    "⏺ Vou rodar os testes agora.",
    "  ⎿  You've hit your limit · resets 3pm (America/Sao_Paulo)",
    "",
    " What do you want to do?",
    " ❯ 1. Stop and wait for limit to reset",
    "   2. Upgrade your plan",
    "",
    " Enter to confirm · Esc to cancel",
].filter { !$0.isEmpty }

/// The agent writing about the limit in its normal output (this very task): the input box and the footer follow.
private let prose = [
    "⏺ Quando o limite estoura, a tela mostra \"You've hit your limit · resets 3pm\"",
    "  e o menu:",
    "  1. Stop and wait for limit to reset",
    "  2. Upgrade your plan",
    "╭──────────────────────────────────────╮",
    "│ >                                    │",
    "╰──────────────────────────────────────╯",
    "  ? for shortcuts",
]

/// M5.3: the loop's agent stuck in the usage-limit dialog is seen on its screen (only while it prints nothing), the
/// attempt is not counted, nothing is discarded and the loop stops with `usageLimit` and a note saying what to do.
@Suite struct UsageLimitDetectionTests {
    @Test func theDialogOnAQuietScreenIsSeen() {
        #expect(UsageLimit.detect(dialog, quiet: true) == "You've hit your limit · resets 3pm (America/Sao_Paulo)")
        // the menu as the last line (no hint below it)
        #expect(UsageLimit.detect(Array(dialog.dropLast(2)), quiet: true) != nil)
    }

    @Test func anAgentThatPrintsIsNotInTheDialog() {
        #expect(UsageLimit.detect(dialog, quiet: false) == nil)
    }

    @Test func anAgentWritingAboutTheLimitIsNotInTheDialog() {
        #expect(UsageLimit.detect(prose, quiet: true) == nil)
        // the menu's text with no limit line above it
        #expect(UsageLimit.detect(Array(dialog.dropFirst(2)), quiet: true) == nil)
        // the limit line, its menu long scrolled away
        #expect(UsageLimit.detect(dialog + (1...10).map { "linha \($0) da saída" }, quiet: true) == nil)
        #expect(UsageLimit.detect([], quiet: true) == nil)
    }

    @Test func theTextReadFromTheScreenIsData() {
        let long = "You've hit your limit \u{1B}[31m· resets\u{07} 3pm\r\n" + String(repeating: "x", count: 200)
        let e = UsageLimit.excerpt(long)
        #expect(e.count <= UsageLimit.excerptMax)
        #expect(!e.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, "\(e)")
        #expect(e.hasPrefix("You've hit your limit · resets 3pm x") && e.hasSuffix("…") && !e.contains("[31m"), "\(e)")
        #expect(UsageLimit.excerpt("  curto  ") == "curto")
        // what `detect` hands back is already the excerpt
        var screen = dialog
        screen[1] = "You've hit your limit \u{1B}[1m" + String(repeating: "y", count: 200)
        let d = UsageLimit.detect(screen, quiet: true)
        #expect(d != nil && d!.count <= UsageLimit.excerptMax && !d!.contains("\u{1B}"))
    }

    @Test func theNewStopCodeDecodesAndAnUnknownOneIsUnknown() throws {
        #expect(try JSONDecoder().decode(Stop.Code.self, from: Data(#""usageLimit""#.utf8)) == .usageLimit)
        #expect(try JSONDecoder().decode(Stop.Code.self, from: Data(#""somethingNewer""#.utf8)) == .unknown)
        let s = Stop(.usageLimit, detail: "You've hit your limit · resets 3pm")
        #expect(try JSONDecoder().decode(Stop.self, from: JSONEncoder().encode(s)) == s)
        #expect(s.label == "o agente atingiu o limite de uso do modelo (You've hit your limit · resets 3pm); relance com work run --model <outro>")
    }

    /// End to end: the turn would hang until its timeout; the loop sees the dialog, dismisses the agent, does not count
    /// the attempt, discards nothing and stops instead of trying the next one.
    @Test func theLoopStopsWithoutCountingTheAttempt() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true"), WorkTask(id: "b", title: "Task b", check: "true")], tries: 3)
        defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try "meio\n".write(to: $0.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8) },
                                                   screen: dialog))
        #expect(await r.run() == .stopped)
        let w = try await r.get(), t = w.tasks[0]
        #expect(w.loop?.stopReason == Stop(.usageLimit, detail: "You've hit your limit · resets 3pm (America/Sao_Paulo)"))
        #expect(w.loop?.used == 0)
        #expect(t.state == .open && t.tries == nil && t.lastFailure == nil, "\(t)")
        #expect(w.tasks[1].state == .open)
        #expect(await r.host.summoned == ["w-task-a-t1"])
        #expect(await r.host.dismissed == ["w-task-a-t1"])
        #expect(await r.host.checks == 0)
        // nothing discarded: the agent's file is still there, no patch, no discarded event
        #expect(FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("wip.txt").path))
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .discarded })
        #expect(w.notes.last?.text == "[loop] laço parado: o agente atingiu o limite de uso do modelo (You've hit your limit · resets 3pm (America/Sao_Paulo)); relance com work run --model <outro>")
    }
}
