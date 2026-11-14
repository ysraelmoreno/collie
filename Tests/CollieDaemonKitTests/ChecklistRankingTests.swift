import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct ChecklistRankingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func pit(_ title: String, hits: Int = 1, body: String = "", age: Double = 1) -> MemoryRecord {
        MemoryRecord(kind: .pitfall, subject: title, title: title, body: body, hits: hits, createdAt: now.addingTimeInterval(-age * 86400))
    }
    func byHits(_ r: MemoryRecord) -> Double { Double(r.hits ?? 0) }

    @Test func noFocusKeepsTheHitOrder() {
        let a = pit("a", hits: 3), b = pit("b", hits: 2), c = pit("c", hits: 1)
        let out = ChecklistRanking.pick([c, a, b], relevance: [:], focus: "", max: 7, hitRank: byHits)
        #expect(out.map(\.title) == ["a", "b", "c"])
    }

    @Test func relevantOnesLeadThenTheHitRankFills() {
        let android = (0..<3).map { pit("android \($0)", hits: 3) }
        let deck = pit("export de deck", hits: 1), pdf = pit("pdf do deck", hits: 1)
        let rel = [deck.id: 10.0, pdf.id: 8.0]
        let out = ChecklistRanking.pick(android + [deck, pdf], relevance: rel, focus: "deck export", max: 7, hitRank: byHits)
        #expect(out.prefix(2).map(\.title) == ["export de deck", "pdf do deck"])
        #expect(out.count == 5 && out.dropFirst(2).allSatisfy { $0.title.hasPrefix("android") })
    }

    @Test func relevanceSlotsAreCappedAtFour() {
        let rel = (0..<6).map { pit("rel \($0)", hits: 1) }
        let hot = pit("hot", hits: 9)
        let scores = Dictionary(uniqueKeysWithValues: rel.map { ($0.id, 10.0) })
        let out = ChecklistRanking.pick(rel + [hot], relevance: scores, focus: "x", max: 5, hitRank: byHits)
        #expect(out.count == 5 && out.prefix(4).allSatisfy { $0.title.hasPrefix("rel") } && out[4].title == "hot")
    }

    @Test func belowTheRelativeCutIsNotRelevant() {
        let top = pit("top", hits: 1), weak = pit("weak", hits: 1), hot = pit("hot", hits: 5)
        let out = ChecklistRanking.pick([weak, hot, top], relevance: [top.id: 10, weak.id: 3], focus: "x", max: 2, hitRank: byHits)
        #expect(out.map(\.title) == ["top", "hot"])   // 3 < 0.4 × 10: weak does not take a relevance slot, hot fills
    }

    @Test func aPlatformNamedInTheFocusDropsOtherPlatformsEverywhere() {
        let droid = pit("CA no Android", hits: 5, body: "adb e emulador"), ios = pit("simulador iOS", hits: 1, body: "simctl"), plain = pit("sandbox", hits: 2)
        let out = ChecklistRanking.pick([droid, ios, plain], relevance: [ios.id: 5], focus: "painel iOS simulator", max: 7, hitRank: byHits)
        #expect(out.map(\.title) == ["simulador iOS", "sandbox"])
    }

    @Test func noPlatformInTheFocusLetsAnyPlatformFill() {
        let droid = pit("CA no Android", hits: 5, body: "adb"), deck = pit("deck", hits: 1)
        let out = ChecklistRanking.pick([droid, deck], relevance: [deck.id: 5], focus: "deck export", max: 7, hitRank: byHits)
        #expect(out.map(\.title) == ["deck", "CA no Android"])
    }

    @Test func neverRepeatsAndNeverExceedsMax() {
        let all = (0..<10).map { pit("p\($0)", hits: $0 + 1) }
        let out = ChecklistRanking.pick(all, relevance: [all[0].id: 9, all[1].id: 9], focus: "x", max: 7, hitRank: byHits)
        #expect(out.count == 7 && Set(out.map(\.id)).count == 7)
    }

    // MARK: focus

    @Test func focusDropsGenericBranchPrefixesAndKeepsTheWork() {
        let f = ChecklistFocus.build(branch: "feat/deck-export", workTitle: "Exportar deck", openTasks: ["PDF"], commitSubjects: ["fix: pptx keeps images"])
        #expect(f == "deck export Exportar deck PDF fix: pptx keeps images")
    }

    @Test func focusUsesTheLastTwoPathComponentsAndDedupesEqualTails() {
        let f = ChecklistFocus.build(branch: nil, workTitle: nil, paths: ["Sources/CollieApp/DeckExporter.swift", "Tests/CollieApp/DeckExporter.swift"])
        #expect(f == "CollieApp DeckExporter swift")   // both paths end in CollieApp/DeckExporter.swift: counted once
    }

    @Test func focusIsEmptyWithoutSignalAndCapped() {
        #expect(ChecklistFocus.build(branch: "main", workTitle: nil).isEmpty)
        #expect(ChecklistFocus.build(branch: nil, workTitle: String(repeating: "word ", count: 400)).count == ChecklistFocus.maxChars)
    }
}
