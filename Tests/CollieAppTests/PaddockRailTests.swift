import Testing
@testable import CollieApp

@Suite struct PaddockRailTests {
    @Test(arguments: [("collie", "C"), (" web", "W"), ("-x", "X"), ("", "?"), ("água", "Á"), ("--", "?"), ("9lives", "9")])
    @MainActor func initial(name: String, expected: String) {
        #expect(PaddockRail.initial(of: name) == expected)
    }
}
