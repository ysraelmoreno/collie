import Testing
import CollieCore

@testable import CollieApp

@Suite(.appEN) struct AppEnglishTests {
    @Test func loopStopReasons() {
        #expect(HistoryRow.stop(nil) == "done")
        #expect(HistoryRow.stop("requested") == "stopped by you")
        #expect(HistoryRow.stop("starterGone") == "Shepherd gone")
    }
    @Test func accessCopyAndStrip() {
        #expect(AccessCopy.verb("read") == "read" && AccessCopy.verb("exec") == "run")
        #expect(AccessStrip.Model(cards: []).text == "")
        #expect(AccessCopy.detection(reason: nil).tag == "detection unavailable")
    }
    @Test func tourAndLoopTexts() {
        #expect(FeatureTour.cards.first?.title == "Canvas and terminals")
        #expect(FeatureTour.Group.trabalhar.title == "Work")
        #expect(LoopsModal.idleText == "No loop running")
        #expect(ThemeEditorFormat.reading(3.74, low: true) == "3.7 low")
        #expect(ThemeEditorFormat.reading(5.8, low: false) == "5.8")
    }
}
