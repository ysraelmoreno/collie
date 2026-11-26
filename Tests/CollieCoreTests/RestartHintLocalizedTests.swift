import Testing
import CollieCore
import CollieProtocol

@Suite struct RestartHintLocalizedTests {
    @Test func hintFollowsTheActiveLanguage() {
        let e = ProtocolError(code: .invalidArgs, message: "Unknown command 'lot.board'")
        L10n.$override.withValue(.pt) {
            #expect(RestartHint.wrap(e, text: RestartHint.localized).message == "lot.board: reinicie o serviço para usar isto")
        }
        L10n.$override.withValue(.en) {
            let m = RestartHint.wrap(e, text: RestartHint.localized).message
            #expect(m == "lot.board: restart the service to use this" && RestartHint.isHint(m))
        }
    }
    @Test func permissionHelperLinesStayFalseForOtherText() {
        #expect(!RestartHint.isHint("sandbox must be sandboxed or free"))
    }
}
