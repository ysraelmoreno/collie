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

    /// A `collieOpenPreferences` for a page: the tab opens, `back()` leaves it, and reopening keeps the page.
    @Test func requestedPageOpensTabAndIsRememberedAfterBack() throws {
        var s = MainViewState()
        #expect(s.page == .aparencia)
        s.page = try #require(PreferencePage.requested("desenho"))
        s.show(.preferences)
        #expect(s.isPreferences && s.page == .desenho)
        s.back()
        #expect(!s.isPreferences && s.page == .desenho)
        s.show(.preferences)
        #expect(s.isPreferences && s.page == .desenho)
    }

    @Test func unknownRequestOpensTabOnTheRememberedPage() {
        var s = MainViewState()
        s.page = .memoria
        if let p = PreferencePage.requested("nada") { s.page = p }
        s.show(.preferences)
        #expect(s.isPreferences && s.page == .memoria)
    }

    @Test func backOutsidePreferencesChangesNothing() {
        var s = MainViewState()
        let before = s
        s.back()
        #expect(s == before)
    }
}
