import Foundation
import Testing
import CollieCore
@testable import CollieApp

@Suite struct PaddockRailTests {
    @Test(arguments: [("collie", "C"), (" web", "W"), ("-x", "X"), ("", "?"), ("água", "Á"), ("--", "?"), ("9lives", "9")])
    @MainActor func initial(name: String, expected: String) {
        #expect(PaddockRail.initial(of: name) == expected)
    }

    @Test @MainActor func pastoShowsOnlyWithContentOrSelectionOrNoPaddocks() {
        let id = UUID()
        #expect(PaddockRail.showsPasto(hasContent: true, hasPaddocks: true, current: id))
        #expect(!PaddockRail.showsPasto(hasContent: false, hasPaddocks: true, current: id))
        #expect(PaddockRail.showsPasto(hasContent: false, hasPaddocks: false, current: id))   // nothing else to show
        #expect(PaddockRail.showsPasto(hasContent: false, hasPaddocks: true, current: nil))   // never hide the selection
    }

    @Test @MainActor func pastoContentIgnoresDockedPanelsAndOtherPaddocks() {
        let here = TerminalRecord(id: UUID(), name: "a", preset: .shell, command: nil, cwd: "/", isShepherd: false, paddockId: UUID())
        let loose = TerminalRecord(id: UUID(), name: "b", preset: .shell, command: nil, cwd: "/", isShepherd: false)
        #expect(!PaddockRail.pastoHasContent(terminals: [here], panels: []))
        #expect(PaddockRail.pastoHasContent(terminals: [here, loose], panels: []))
    }
}
