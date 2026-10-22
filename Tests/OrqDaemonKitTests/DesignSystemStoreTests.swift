import Testing
import Foundation
import OrqProtocol
@testable import OrqDaemonKit

private func tempDesignDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orq-ds-\(UUID().uuidString.prefix(8))/design")
}
private func mode(_ u: URL) -> Int? { try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int }

@Suite struct DesignSystemStoreTests {
    private func ds(_ name: String, version: Int = 1) -> DesignSystem {
        DesignSystem(id: UUID(), name: name, fileId: UUID(), viewLink: "figcraft://join?host=h&file=f&token=t", version: version,
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func registryRoundTrip() throws {
        let dir = tempDesignDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(try DesignSystemStore(dir: dir).load() == [])   // none yet
        let all = [ds("Brand"), ds("Docs", version: 3)]
        try DesignSystemStore(dir: dir).save(all)
        #expect(try DesignSystemStore(dir: dir).load() == all)
        // a corrupt registry is an error, not an empty list (its links would be lost)
        try Data("{".utf8).write(to: dir.appendingPathComponent("systems.json"))
        #expect(throws: ProtocolError.self) { try DesignSystemStore(dir: dir).load() }
    }

    @Test func historyKeepsLast200() throws {
        let dir = tempDesignDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = DesignSystemStore(dir: dir), id = UUID()
        #expect(s.history(id) == [])
        for i in 1...205 {
            try s.append(DesignSystemEvent(at: Date(), kind: "published", version: i, scope: nil, by: "app", reason: "r\(i)",
                                           snapshot: "v\(i).figcraft", files: [FileOutcome(file: "x", ok: true, detail: "")]), to: id)
        }
        let h = s.history(id)
        #expect(h.count == 200 && h.first?.version == 6 && h.last?.version == 205)
    }

    @Test func namesValidatedLikeDesignFiles() throws {
        for bad in ["../x", "a/b", "", String(repeating: "a", count: 81), "con\u{0}", "..", "a..b", "tab\there"] {
            #expect(throws: ProtocolError.self, "\(bad.debugDescription)") { try DesignSystemStore.validate(bad) }
        }
        try DesignSystemStore.validate(String(repeating: "a", count: 80))
        try DesignSystemStore.validate("My brand v2.1_final-b")
    }

    @Test func registryIs0600() throws {
        let dir = tempDesignDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = DesignSystemStore(dir: dir), one = ds("Brand")
        try s.save([one])
        try s.append(DesignSystemEvent(at: Date(), kind: "created", version: 1, scope: nil, by: "app", reason: "r", snapshot: nil, files: []),
                     to: one.id)
        #expect(mode(dir.appendingPathComponent("systems.json")) == 0o600)
        #expect(mode(s.dir(one.id).appendingPathComponent("history.json")) == 0o600)
        #expect(mode(s.dir(one.id)) == 0o700)
    }
}
