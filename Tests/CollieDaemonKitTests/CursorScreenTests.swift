import Testing
import Foundation
@testable import CollieDaemonKit

/// A4: the answer of a Cursor turn out of its rendered screen. Fixtures are real screens of cursor-agent
/// 2026.11.22 (Composer 2.5, 120x40), rendered with `ScreenRenderer`.
@Suite struct CursorScreenTests {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cursor-screen/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func answerOfAShortTurnIsTheTableOnly() throws {
        let a = CursorScreen.answer(try fixture("table"))
        #expect(a == """
        ┌────────┬────────┐
        │ Fruit  │ Color  │
        ├────────┼────────┤
        │ Apple  │ Red    │
        ├────────┼────────┤
        │ Banana │ Yellow │
        ├────────┼────────┤
        │ Grape  │ Purple │
        └────────┴────────┘
        """)
    }

    @Test func answerOfALongTurnIsTheVisibleLinesWithoutTheFrame() throws {
        let lines = CursorScreen.answer(try fixture("cut")).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "31. line 31" && lines.last == "60. line 60", "\(lines.first ?? "") … \(lines.last ?? "")")
        #expect(!lines.contains { $0.contains("Add a follow-up") || $0.contains("Composer") || $0.contains("/private") })
    }

    @Test func aTurnWhoseStartScrolledOffIsCut() throws {
        #expect(CursorScreen.isCut(try fixture("cut")))
        #expect(!CursorScreen.isCut(try fixture("table")))
    }

    @Test func aScreenWithoutTheBarIsReturnedTrimmed() {
        #expect(CursorScreen.answer("  hello  \n\n") == "hello")
    }
}
