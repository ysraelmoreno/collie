import Foundation
import Testing
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// The panels' texts under `.en` (the Portuguese ones are in each panel's own suite).
@Suite struct PluginsEnglishTests {
    @Test func workErrorsInEnglish() {
        func e(_ c: ErrorCode, _ m: String) -> ProtocolError { ProtocolError(code: c, message: m) }
        L10n.$override.withValue(.en) {
            #expect(WorkPanelModel.describe(e(.invalidArgs, "no active work"), "Dev") == "No active work.")
            #expect(WorkPanelModel.describe(e(.notRunning, "Terminal 'Dev' is not running"), nil) == "Dev is not running.")
            #expect(WorkPanelModel.describe(e(.internal, "boom"), nil) == "Something went wrong: boom")
        }
    }

    @Test func memoryLinesInEnglish() {
        L10n.$override.withValue(.en) {
            #expect(MemoryPanelModel.precisionLine(nil) == "Precision: the installed daemon does not measure this yet")
            #expect(MemoryPanelModel.tokens(18_000) == "18k")
            #expect(MemoryPanelModel.usd(0.04) == "$0.04")
            #expect(MemoryPanelModel.Tab.review.label == "Review")
        }
    }

    @Test func networkNoticesInEnglish() {
        L10n.$override.withValue(.en) {
            #expect(NetworkPanelModel.describe(ProtocolError(code: .unavailable, message: "No emulator online")) == "No emulator online.")
        }
    }
}
