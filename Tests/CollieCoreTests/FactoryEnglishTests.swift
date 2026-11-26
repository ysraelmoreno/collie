import Testing
import Foundation
import CollieCore

@Suite struct FactoryEnglishTests {
    @Test func configErrorsSpeakTheActiveLanguage() {
        let data = Data(#"{"version":2}"#.utf8)
        func msg() -> String { if case .failure(let e) = ProjectWorkConfig.parse(data) { e.message } else { "" } }
        L10n.$override.withValue(.pt) { #expect(msg() == "collie-work.json tem version 2; só a version 1 é aceita") }
        L10n.$override.withValue(.en) { #expect(msg() == "collie-work.json has version 2; only version 1 is accepted") }
    }
    @Test func stopLabelsAndNoteFollowTheLanguage() {
        let stop = WorkLoopState.Stop(.budgetSpent)
        L10n.$override.withValue(.pt) { #expect(stop.note == "[loop] laço parado: orçamento de tempo esgotado") }
        L10n.$override.withValue(.en) { #expect(stop.note == "[loop] loop stopped: time budget spent") }
    }
    @Test func doctorWithoutConfigIsEnglish() {
        L10n.$override.withValue(.en) {
            let l = FactoryDoctor.review(.init())
            #expect(l.evidence == ["no review personas (factory.review.personas)"])
        }
    }
}
