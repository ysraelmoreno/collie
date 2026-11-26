import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit
import CollieProtocol

@Suite("Daemon errors in English (A2)")
struct DaemonErrorsEnglishTests2 {
    @Test func artifactFolderError() {
        L10n.$override.withValue(.en) {
            do { _ = try ArtifactFolder.normalize("/x") } catch let e as ProtocolError { #expect(e.message.hasPrefix("invalid folder")) } catch {}
        }
        L10n.$override.withValue(.pt) {
            do { _ = try ArtifactFolder.normalize("/x") } catch let e as ProtocolError { #expect(e.message.hasPrefix("pasta inválida")) } catch {}
        }
    }

    @Test func engineUnavailable() {
        L10n.$override.withValue(.en) {
            let e = FigcraftServer.unavailable(.absent, admin: true)
            #expect(e.message.hasPrefix("Design engine not installed"))
        }
    }

    @Test func badShaAndTemplateLabel() {
        L10n.$override.withValue(.en) {
            #expect(FigcraftInstaller.badSha.hasPrefix("The downloaded file"))
            #expect(ArtifactTemplates.Kind.deck.label == "Presentation")
        }
    }
}
