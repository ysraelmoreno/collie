import Foundation
import Testing
@testable import CollieApp

@Suite @MainActor struct LegacyDefaultsTests {
    @Test func copiesLegacyDefaultsOnce() {
        let old = "collie.test.legacy.\(UUID().uuidString)", new = "collie.test.new.\(UUID().uuidString)"
        let src = UserDefaults(suiteName: old)!, dst = UserDefaults(suiteName: new)!
        defer { src.removePersistentDomain(forName: old); dst.removePersistentDomain(forName: new) }
        src.set(true, forKey: "consent"); src.set(["/r"], forKey: "new.claudeFolders"); src.set("old", forKey: "kept")
        dst.set("mine", forKey: "kept")
        #expect(CollieApp.migrateDefaults(from: old, into: dst) == 2)
        #expect(dst.bool(forKey: "consent") && dst.stringArray(forKey: "new.claudeFolders") == ["/r"])
        #expect(dst.string(forKey: "kept") == "mine")
        #expect(CollieApp.migrateDefaults(from: old, into: dst) == 0)
    }
}
