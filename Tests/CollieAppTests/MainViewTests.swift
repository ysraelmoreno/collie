import Testing
@testable import CollieApp

@Suite struct MainViewTests {
    @Test func startsOnCanvas() {
        let s = MainViewState()
        #expect(s.current == .canvas && !s.isPreferences)
    }

    @Test func showAndBack() {
        var s = MainViewState()
        s.show(.preferences)
        #expect(s.current == .preferences && s.isPreferences)
        s.back()
        #expect(s.current == .canvas && !s.isPreferences)
        s.show(.preferences); s.show(.canvas)
        #expect(!s.isPreferences)
    }

    @Test func backOutsidePreferencesChangesNothing() {
        var s = MainViewState()
        let before = s
        s.back()
        #expect(s == before)
    }
}
