import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct UseEvidenceTests {
    private func rec(_ title: String) -> MemoryRecord { MemoryRecord(kind: .pitfall, subject: "s", title: title, body: "b") }
    private func id8(_ r: MemoryRecord) -> String { String(r.id.uuidString.lowercased().prefix(8)) }

    @Test func shortIdCitesIt() {
        let a = rec("Ab"), b = rec("Cd")
        #expect(UseEvidence.cited(message: "Segui a [\(id8(a))] aqui.", records: [a, b]) == [a.id])
        #expect(UseEvidence.cited(message: "id \(id8(b).uppercased()) e \(a.id.uuidString)", records: [a, b]) == [a.id, b.id])
        // spec: 8 hex anywhere, a code block or a path too (it doesn't exclude them; the echo risk is measured, phase 2)
        #expect(UseEvidence.cited(message: "```\ncollie memory get \(id8(a))\n```", records: [a]) == [a.id])
    }

    @Test func idInsideLongerHexIsNoCitation() {
        let a = rec("Ab")
        #expect(UseEvidence.cited(message: "commit \(id8(a))ff0", records: [a]).isEmpty)
        #expect(UseEvidence.cited(message: "commit 0\(id8(a))", records: [a]).isEmpty)
        #expect(UseEvidence.cited(message: String(id8(a).prefix(7)), records: [a]).isEmpty)
    }

    @Test func titleOfThreeWordsNormalizedCitesIt() {
        let a = rec("Build compartilhado quebrado: testar só com --filter")
        #expect(UseEvidence.cited(message: "Como diz build   COMPARTILHADO quebrado — testar so com filter, rodei isso.", records: [a]) == [a.id])
        let b = rec("Pin do figcraft")
        #expect(UseEvidence.cited(message: "o pin do figcraft mudou", records: [b]) == [b.id])
    }

    @Test func titleOfTwoWordsOrPartialNeverCites() {
        let a = rec("Build quebrado"), b = rec("Pin do figcraft")
        #expect(UseEvidence.cited(message: "o build quebrado de novo", records: [a, b]).isEmpty)
        #expect(UseEvidence.cited(message: "pin do figcraftzinho", records: [b]).isEmpty)   // whole words only
        #expect(UseEvidence.cited(message: "o pin do", records: [b]).isEmpty)
    }

    @Test func onlyTheFirst64KiBAreRead() {
        let a = rec("Ab")
        let far = String(repeating: "x ", count: UseEvidence.maxBytes / 2) + id8(a)
        #expect(UseEvidence.cited(message: far, records: [a]).isEmpty)
        #expect(UseEvidence.cited(message: id8(a) + far, records: [a]) == [a.id])
    }
}
