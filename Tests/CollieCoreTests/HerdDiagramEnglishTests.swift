import Testing
import Foundation
import CollieCore
import CollieProtocol

@Suite struct HerdDiagramEnglishTests {
    @Test func herdBadJSONIsEnglish() {
        L10n.$override.withValue(.en) {
            do throws(ProtocolError) { _ = try HerdFormat.decode(Data("{}".utf8)) } catch {
                #expect(error.message == "herd: invalid JSON or missing fields", "\(error.message)")
                return
            }
            Issue.record("accepted")
        }
    }
    @Test func herdBadJSONIsPortugueseUnderPt() {
        L10n.$override.withValue(.pt) {
            do throws(ProtocolError) { _ = try HerdFormat.decode(Data("{}".utf8)) } catch {
                #expect(error.message == "rebanho: JSON inválido ou campos faltando")
                return
            }
            Issue.record("accepted")
        }
    }
    @Test func factoryHerdsSpeakEnglish() {
        L10n.$override.withValue(.en) {
            #expect(Herd.factory.first?.name == "Fullstack feature")
            #expect(Herd.factory.allSatisfy { $0.terminals.allSatisfy { !($0.role ?? "").contains("Você") } })
        }
    }
    @Test func diagramXMLErrorIsEnglish() {
        L10n.$override.withValue(.en) {
            do throws(ProtocolError) { _ = try DiagramFile.validate(xml: "<a/>\0") } catch {
                #expect(error.message.contains("null character"), "\(error.message)")
                return
            }
            Issue.record("accepted")
        }
    }
}
