import Foundation
import Testing
import CollieCore
@testable import CollieApp

/// L6: the first-use card shows only while the current paddock (or the Pasture) has no agent.
struct FirstRunTests {
    private let paddock = UUID(), other = UUID()
    private func term(in p: UUID?) -> TerminalRecord {
        TerminalRecord(id: UUID(), name: "A", preset: .claude, command: nil, cwd: "/x", isShepherd: false, paddockId: p)
    }

    @Test func showsWithNoAgentInTheCurrentPaddock() {
        #expect(FirstRun.shows(connected: true, terminals: [], current: paddock))
        #expect(FirstRun.shows(connected: true, terminals: [term(in: other), term(in: nil)], current: paddock))
    }

    @Test func goneWithTheFirstAgent() {
        #expect(!FirstRun.shows(connected: true, terminals: [term(in: paddock)], current: paddock))
    }

    @Test func thePastureCountsItsOwnTerminals() {
        #expect(FirstRun.shows(connected: true, terminals: [term(in: paddock)], current: nil))
        #expect(!FirstRun.shows(connected: true, terminals: [term(in: nil)], current: nil))
    }

    @Test func hiddenWhileDisconnected() {
        #expect(!FirstRun.shows(connected: false, terminals: [], current: paddock))
    }
}
