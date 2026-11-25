import Testing
import Foundation
@testable import CollieApp

/// The pure parts of the Sparkle wrapper (spec 2026-11-25): the real framework, the network and the relaunch never run here.
@Suite struct SparkleUpdaterTests {
    @Test func postponesOnlyWhileAnAgentIsWorking() {
        #expect(!SparkleUpdater.shouldPostpone(busy: []))
        #expect(SparkleUpdater.shouldPostpone(busy: ["api"]))
        #expect(SparkleUpdater.shouldPostpone(busy: ["api", "web"]))
    }

    @Test func noticeNamesTheBusyAgents() {
        #expect(UpdateModel.busyNotice(version: "0.3.0", busy: ["api"]).contains("1 agente trabalhando"))
        let two = UpdateModel.busyNotice(version: "0.3.0", busy: ["api", "web"])
        #expect(two.contains("2 agentes trabalhando") && two.contains("api, web") && two.contains("0.3.0"))
    }

    /// Local builds (no Apple team) never start the updater, so `checkNow()` is a no-op and nothing is scheduled.
    @MainActor @Test func disabledWrapperDoesNothing() {
        let u = SparkleUpdater(busy: { [] }, disabled: true)
        #expect(!u.isEnabled && !u.canCheck)
        u.checkNow()
        #expect(!u.automaticChecks)
    }

    /// "Depois" keeps the pending relaunch; it runs once nobody is working, or when the owner insists.
    @MainActor @Test func deferredRelaunchRunsWhenIdleOrForced() {
        var busy = ["api"]
        var ran = 0
        let u = SparkleUpdater(busy: { busy }, disabled: true)
        u.hold { ran += 1 }
        u.releaseIfIdle(); #expect(ran == 0)
        busy = []
        u.releaseIfIdle(); #expect(ran == 1)
        u.releaseIfIdle(); #expect(ran == 1)   // once
        u.hold { ran += 1 }
        u.releaseNow(); #expect(ran == 2)
    }
}
