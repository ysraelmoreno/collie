import Foundation
import Testing
import CollieCore
@testable import CollieApp

/// L3: Completa/Compacta gave way to one structure; Compacta's part is the collapsed sidebar.
@MainActor @Suite struct SidebarMigrationTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "collie.test.\(UUID())")! }

    @Test func compactSavedStartsCollapsedAndTheKeyIsGone() {
        let d = defaults()
        d.set("compact", forKey: CollieApp.legacyStructureKey)
        CollieApp.migrateStructure(d)
        #expect(d.bool(forKey: CollieApp.sidebarCollapsedKey))
        #expect(d.object(forKey: CollieApp.legacyStructureKey) == nil)
    }

    @Test func fullSavedStaysExpandedAndTheKeyIsGone() {
        let d = defaults()
        d.set("full", forKey: CollieApp.legacyStructureKey)
        CollieApp.migrateStructure(d)
        #expect(d.object(forKey: CollieApp.sidebarCollapsedKey) == nil)
        #expect(d.object(forKey: CollieApp.legacyStructureKey) == nil)
    }

    @Test func noKeyStaysExpanded() {
        let d = defaults()
        CollieApp.migrateStructure(d)
        #expect(d.object(forKey: CollieApp.sidebarCollapsedKey) == nil)
    }

    /// Read once: a later start finds no key and leaves the user's own ⌘\ choice alone.
    @Test func readOnlyOnce() {
        let d = defaults()
        d.set("compact", forKey: CollieApp.legacyStructureKey)
        CollieApp.migrateStructure(d)
        d.set(false, forKey: CollieApp.sidebarCollapsedKey)   // the user expanded it
        CollieApp.migrateStructure(d)
        #expect(!d.bool(forKey: CollieApp.sidebarCollapsedKey))
    }

    /// Moved from the rail with the Pasto rule: an empty, selected Pasto leaves for the first paddock.
    @Test func emptyPastoFallsBackToTheFirstPaddock() {
        let p = Paddock(id: UUID(), name: "api", repoRoot: "/r", path: "/r/.collie/paddocks/api", branch: "collie/api", baseBranch: "main")
        #expect(SidebarModel.fallbackPaddock(paddocks: [p], current: nil, pastoHasContent: false) == p.id)
        #expect(SidebarModel.fallbackPaddock(paddocks: [p], current: nil, pastoHasContent: true) == nil)
        #expect(SidebarModel.fallbackPaddock(paddocks: [p], current: p.id, pastoHasContent: false) == nil)
        #expect(SidebarModel.fallbackPaddock(paddocks: [], current: nil, pastoHasContent: false) == nil)
    }
}
