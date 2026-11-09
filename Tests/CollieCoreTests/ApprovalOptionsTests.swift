import Testing
import Foundation
@testable import CollieCore

@Suite struct ApprovalOptionsTests {
    private func a(_ kind: ApprovalKind, _ reason: String, _ prompt: String) -> Approval {
        Approval(terminalId: UUID(), terminal: "t", kind: kind, reason: reason, prompt: prompt)
    }

    @Test func permissionMenuOptions() {
        let p = "Bash command\n  rm -rf build\n\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again for rm commands\n  3. No, and tell Claude what to do differently (esc)\n"
        let o = a(.menu, "Do you want to proceed?", p).options
        #expect(o.map(\.number) == [1, 2, 3] && o[1].isSession && o[2].isNo && !o[0].isSession)
    }

    @Test func questionDropsTextInputOptionsAndRefusesMultiSelect() {
        let q = "Which db?\n❯ 1. Postgres\n  2. SQLite\n  3. Type something.\n  4. Chat about this\n"
        let r = a(.unknown, Approval.questionReason, q)
        #expect(r.options.map(\.label) == ["Postgres", "SQLite"] && r.question == "Which db?")
        #expect(a(.unknown, Approval.questionReason, q + "space to select").options.isEmpty)
    }

    @Test func trustFolderAndOtherKindsHaveNoOptions() {
        #expect(a(.unknown, "do you trust the files in this folder", "❯ 1. Yes, proceed\n  2. No, exit\n").options.isEmpty)
        #expect(a(.yesNo, "(y/n)", "1. a\n").options.isEmpty)
    }

    @Test func onlyTheLastRunCounts() {
        #expect(a(.menu, "x", "1. old\n2. old2\n\nDo you want?\n1. Yes\n2. No\n").options.map(\.label) == ["Yes", "No"])
    }
}
