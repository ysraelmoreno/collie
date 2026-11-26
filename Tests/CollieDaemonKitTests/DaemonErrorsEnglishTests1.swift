import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieNetwork
@testable import CollieDaemonKit

@Suite struct DaemonErrorsEnglishTests1 {
    @Test func maintenanceBusyIsEnglish() async {
        await L10n.$override.withValue(.en) {
            let m = Maintenance()
            try? await m.enter("backup")
            do { try await m.enter("import"); Issue.record("expected conflict") }
            catch { #expect(error.message == "backup in progress") }
        }
    }

    @Test func networkCardTextIsEnglish() {
        L10n.$override.withValue(.en) {
            let r = try! JSONDecoder().decode(MapRule.self, from: Data(#"{"id":"r","enabled":true,"match":{},"action":{"drop":{}},"delayMs":300}"#.utf8))
            #expect(CommandRouter.cardText(r) == "any request\ndrop (cuts the connection) · delay 300 ms")
        }
    }

    @Test func pairingRefusalIsEnglish() {
        L10n.$override.withValue(.en) {
            #expect(PluginStore.changed == "contents changed since installation; install again")
            #expect(UpdateChecker.refusedVersion == "this version was already refused at verification")
        }
    }
}
