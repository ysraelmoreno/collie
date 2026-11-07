import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct PaddockAutoStatusTests {
    @Test func activityFromTheTerminalsBadges() {
        #expect(PaddockAutoStatus.activity([.idle, .attention, .working]) == .blocked)   // a card waiting wins
        #expect(PaddockAutoStatus.activity([.idle, .working, .stopped]) == .working)
        #expect(PaddockAutoStatus.activity([.idle, .stopped, nil]) == .quiet)
        #expect(PaddockAutoStatus.activity([]) == .quiet)
    }

    @Test func quietIsReviewWithWorkToLandElseIdle() {
        #expect(PaddockAutoStatus.quiet(pending: true) == .review)
        #expect(PaddockAutoStatus.quiet(pending: false) == .idle)
    }

    /// The computed status replaces the shown one only when it changes: a manual pick holds until then.
    @Test func manualPickHoldsUntilTheComputedStatusChanges() {
        // first computation: applied
        #expect(PaddockAutoStatus.apply(computed: .working, last: nil, shown: .working) == nil)
        #expect(PaddockAutoStatus.apply(computed: .review, last: nil, shown: .working) == .review)
        // the user marked it blocked by hand; the computed is still working: stays blocked
        #expect(PaddockAutoStatus.apply(computed: .working, last: .working, shown: .blocked) == nil)
        // then the agents stop with commits to land: the event wins
        #expect(PaddockAutoStatus.apply(computed: .review, last: .working, shown: .blocked) == .review)
    }

    /// Landed: done holds while the paddock is quiet (its terminals closing must not undo it); new work replaces it.
    @Test func doneHoldsUntilWorkStartsAgain() {
        #expect(PaddockAutoStatus.apply(computed: .idle, last: .working, shown: .done) == nil)
        #expect(PaddockAutoStatus.apply(computed: .review, last: nil, shown: .done) == nil)
        #expect(PaddockAutoStatus.apply(computed: .working, last: .idle, shown: .done) == .working)
        #expect(PaddockAutoStatus.apply(computed: .blocked, last: .idle, shown: .done) == .blocked)
    }

    /// Work to land: commits on the branch not in the base, or uncommitted changes; Collie's own folder doesn't count.
    @Test func pendingSeesCommitsAndChangesButNotCollieFolder() async throws {
        let repo = try await makeRepo()
        let f = try await PaddockManager.create(name: "feat", repoRoot: repo, createdBy: nil)
        let dir = URL(fileURLWithPath: f.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".collie/memory"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent(".collie/memory/m.md"), atomically: true, encoding: .utf8)
        #expect(try await PaddockAutoStatus.pending(f) == false)

        try "two\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(try await PaddockAutoStatus.pending(f) == true)   // uncommitted

        try await commit("f.txt", "two\n", in: dir)
        #expect(try await PaddockAutoStatus.pending(f) == true)   // committed, not landed

        var landed = f
        _ = try await PaddockManager.land(&landed, mode: .merge, message: nil)
        #expect(try await PaddockAutoStatus.pending(f) == false)
    }

    @Test func folderPaddockHasNothingToLand() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-folder-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try await PaddockAutoStatus.pending(.folder(name: "x", path: d.path)) == false)
    }
}
