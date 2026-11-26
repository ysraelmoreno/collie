import Foundation
import Testing
import CollieProtocol
@testable import CollieApp

/// "O que o Collie faz": the table of cards, the model that walks it and the set of seen cards.
@Suite(.appPT) struct FeatureTourTests {
    private var ids: [String] { FeatureTour.cards.map(\.id) }

    // MARK: table

    @Test func seventeenCardsWithDistinctIds() {
        #expect(FeatureTour.cards.count == 17)
        #expect(Set(ids).count == 17)
    }

    @Test func fourGroupsInOrderEachContiguous() {
        #expect(FeatureTour.Group.allCases == [.trabalhar, .paineis, .controle, .personalizar])
        // collapsing runs of equal groups must give each group exactly once, in order: no group is split
        var runs: [FeatureTour.Group] = []
        for c in FeatureTour.cards where runs.last != c.group { runs.append(c.group) }
        #expect(runs == [.trabalhar, .paineis, .controle, .personalizar])
        let sizes = FeatureTour.Group.allCases.map { g in FeatureTour.cards.filter { $0.group == g }.count }
        #expect(sizes == [6, 6, 3, 2])
    }

    @Test func everyCardHasItsTexts() {
        for c in FeatureTour.cards {
            #expect(!c.title.isEmpty && !c.text.isEmpty && !c.how.isEmpty)
        }
    }

    @Test func onlyThePastorCardHasNoButton() {
        #expect(FeatureTour.cards.filter { $0.shortcut == nil }.map(\.id) == ["shepherd"])
    }

    @Test func panelButtonsNameARealPlugin() {
        for case .panel(let id)? in FeatureTour.cards.map({ $0.shortcut?.action }) {
            #expect(PluginRegistry.spec(id) != nil)
        }
    }

    @Test func everyPluginPanelFileIsCoveredByACard() throws {
        let plugins = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ColliePlugins")
        let files = try FileManager.default.contentsOfDirectory(atPath: plugins.path)
        let panels = Set(files.filter { $0.hasSuffix("Panel.swift") }.map { String($0.dropLast(".swift".count)) })
        try #require(!panels.isEmpty)
        let covered = Set(FeatureTour.cards.flatMap(\.panels))
        #expect(panels.subtracting(covered).isEmpty)
        #expect(covered.subtracting(panels).isEmpty)   // a card never names a panel that does not exist
    }

    // MARK: model

    @Test func nextAndPreviousStopAtTheEnds() {
        var m = FeatureTourModel()
        m.previous()
        #expect(m.index == 0)
        for _ in 0..<40 { m.next() }
        #expect(m.index == 16)
        #expect(!m.canGoForward && m.canGoBack)
        m.previous()
        #expect(m.index == 15)
    }

    @Test func jumpGoesToTheFirstCardOfTheGroup() {
        var m = FeatureTourModel()
        m.jump(to: .paineis)
        #expect(m.index == 6 && m.current.id == "browser" && m.group == .paineis)
        m.jump(to: .personalizar)
        #expect(m.index == 15 && m.current.id == "plugins")
        m.jump(to: .controle)
        #expect(m.index == 12 && m.current.id == "memory")
        m.next(); m.jump(to: .controle)   // from inside the group it still goes to its first card
        #expect(m.index == 12)
        m.jump(to: .trabalhar)
        #expect(m.index == 0)
    }

    @Test func opensOnTheFirstCardWhenNothingWasSeen() {
        let m = FeatureTourModel(seen: [])
        #expect(m.index == 0 && m.current.id == "canvas")
    }

    @Test func opensOnTheFirstUnseenCard() {
        let m = FeatureTourModel(seen: Set(ids.prefix(3)))
        #expect(m.index == 3 && m.current.id == "loops")
    }

    @Test func opensOnTheFirstCardWhenAllWereSeen() {
        let all = Set(ids)
        let m = FeatureTourModel(seen: all)
        #expect(m.index == 0)
        #expect(!m.hasUnseen)
        #expect(!FeatureTour.hasUnseen(all))
    }

    @Test func showingACardMarksIt() {
        var m = FeatureTourModel(seen: [])
        #expect(m.seen == [ids[0]])   // the first card is shown on open
        m.next()
        #expect(m.seen == Set(ids.prefix(2)))
        m.jump(to: .controle)
        #expect(m.seen.contains("memory") && m.seen.count == 3)
        m.show(99)   // clamped to the last card, which is then shown
        #expect(m.index == 16 && m.seen.contains("themes"))
        #expect(m.hasUnseen)
    }

    @Test func unknownSavedIdsAreIgnored() {
        let m = FeatureTourModel(seen: ["fantasma"])
        #expect(m.index == 0)
        #expect(!m.seen.contains("fantasma"))
        #expect(FeatureTour.hasUnseen(["fantasma"]))
        #expect(!FeatureTour.hasUnseen(Set(ids).union(["fantasma"])))
    }

    // MARK: seen set

    @Test @MainActor func seenIdsLiveInUserDefaults() throws {
        let name = "collie-tour-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeatureTourSeen(defaults: defaults)
        #expect(store.hasUnseen)
        store.mark("canvas")
        #expect(FeatureTourSeen(defaults: defaults).ids == ["canvas"])
        for id in ids { store.mark(id) }
        #expect(!store.hasUnseen)
        #expect(!FeatureTourSeen(defaults: defaults).hasUnseen)
    }
}
