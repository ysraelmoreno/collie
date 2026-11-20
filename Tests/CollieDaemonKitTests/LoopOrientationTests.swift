import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// M2.4: a Shepherd follows a loop by reading the daemon's state (`collie work wait`, `collie work status`); the
/// notice typed into its terminal is only a hint. `/collie:loop`, the orientation and the notices all say so.
@Suite struct LoopOrientationTests {
    private let hint = " · estado: collie work status"

    @Test func theLoopCommandWaitsOnStateNotOnTheNotice() {
        for md in [LoopCommand.markdown(arguments: true), LoopCommand.markdown(arguments: false)] {
            for must in ["collie work wait", "--since <version>", "collie work status",
                         "typed into your terminal is only a hint and may never arrive",
                         "When collie work wait says ended (laço terminou), run collie work status and report what passed, what was deferred and why.",
                         // the rest of the text stays
                         "Only their Permitir starts the loop", "Do not edit the paddock's worktree while the loop runs.", "Never land or push.",
                         "To stop a loop: collie work stop. Answer in the owner's language."] {
                #expect(md.contains(must), "\(must)")
            }
            // the old instruction (wait for the notice) is gone
            #expect(!md.contains("reaches you when it ends") && !md.contains("Laço de … terminou"))
            #expect(!md.contains("`"))   // still no inline shell
        }
        // six numbered steps, as before
        let steps = LoopCommand.body.split(separator: "\n").filter { $0.first?.isNumber == true }.map { String($0.prefix(2)) }
        #expect(steps == ["1.", "2.", "3.", "4.", "5.", "6."])
    }

    /// Every copy of the skill's text is the same one. Today the only source is `LoopCommand.body` (Claude's rendered
    /// `commands/loop.md` and the form for an agent without `$ARGUMENTS`); a copy kept in the repository (a plugin, a
    /// resource, a project skill) must carry the body word for word.
    @Test func everyCopyOfTheSkillTextIsTheSame() throws {
        #expect(LoopCommand.markdown(arguments: true).hasSuffix("\n\n" + LoopCommand.body))
        #expect(LoopCommand.markdown(arguments: false).hasSuffix("\n\n" + LoopCommand.body))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("collie-lo-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try LoopCommand.render(into: tmp.appendingPathComponent("collie"))
        let rendered = try String(contentsOf: tmp.appendingPathComponent("collie/commands/loop.md"), encoding: .utf8)
        #expect(rendered == LoopCommand.markdown(arguments: true))

        // Tests/CollieDaemonKitTests/<this file>: the repository is three levels up
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = "Only a Shepherd inside a paddock with its own worktree can start a loop"
        for dir in ["plugins", "Resources", ".claude", "skills"] {
            guard let files = FileManager.default.enumerator(at: repo.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in files where ["md", "txt", "json"].contains(f.pathExtension) {
                guard let text = try? String(contentsOf: f, encoding: .utf8), text.contains(marker) else { continue }
                #expect(text.contains(LoopCommand.body.trimmingCharacters(in: .whitespacesAndNewlines)), "\(f.path) differs from LoopCommand.body")
            }
        }
    }

    @Test func theShepherdOrientationTeachesWorkWait() {
        let phrase = "Wait for a loop: collie work wait, not a terminal notice."
        for agent in ["claude", "cursor", "codex"] {
            let t = CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], agent: agent)
            let loop = t.split(separator: "\n").first { $0.hasPrefix("- Loop") }.map(String.init) ?? ""
            #expect(t.count <= 1500 && loop.hasSuffix(phrase) && loop.contains("collie work run"), "\(agent) \(t.count)\n\(t)")
            #expect(t.contains("collie work status"))
            #expect(t.components(separatedBy: phrase).count == 2)   // once
        }
        // at the cap the short sentence stays rather than the Loop line going with a shorter form (a Cursor Shepherd, real names)
        let tightFit = CollieOrientation.text(terminal: "Collie Main", isShepherd: true, paddock: "collie", peers: ["Bob"], panels: [], agent: "cursor")
        let short = tightFit.split(separator: "\n").first { $0.hasPrefix("- Loop") }.map(String.init) ?? ""
        #expect(tightFit.count <= 1500 && short.hasSuffix("the checks. Wait: collie work wait."), "\(tightFit.count)\n\(tightFit)")
        // who cannot start a loop does not carry it: another agent, a Shepherd without a paddock or in a shared folder
        for t in [CollieOrientation.text(terminal: "Ana", isShepherd: false, paddock: "P", peers: ["Bob"], panels: []),
                  CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: nil, peers: ["Bob"], panels: []),
                  CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], sharedFolder: ["x"])] {
            #expect(!t.contains("collie work wait"), "\(t)")
        }
    }

    @Test func theNoticesEndWithTheStateHintOnOneLine() {
        let e = TaskEvidence(commits: ["abc1234 feat: x"], shortstat: "1 file changed", checkTail: "ok", seconds: 9, attempt: 1)
        let done = WorkTask(id: "a", title: "Build it", state: .done, evidence: e)
        let late = WorkTask(id: "b", title: "Flaky\none", state: .deferred, reason: "loop: check failed\n(exit 1)")
        for t in [done, late] {
            let line = WorkStatusText.taskEnded(t)
            #expect(line.hasSuffix(hint) && !line.contains("\n") && !line.contains("?"), "\(line)")
        }
        #expect(WorkStatusText.taskEnded(late) == "[collie] Laço, tarefa terminada: – Flaky one · adiada: loop: check failed (exit 1)" + hint)
        var w = Work(title: "W", terminalId: UUID(), tasks: [done, late])
        w.loop = WorkLoopState(state: .finished, tasks: ["a", "b"])
        #expect(WorkStatusText.loopEnded(w) == """
            [collie] Laço de "W" terminou: 1 feitas, 1 adiadas. · estado: collie work status
            ✓ Build it · tentativa 1 · 1 commit · 1 file changed
            – Flaky one · adiada: loop: check failed (exit 1)
            """)
    }
}
