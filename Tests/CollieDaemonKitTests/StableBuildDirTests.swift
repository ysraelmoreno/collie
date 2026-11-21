import Testing
import Foundation
@testable import CollieDaemonKit

/// M11.3: an attempt's terminal builds in a folder stable across its loop's attempts, so attempt 2 reuses attempt 1's build.
@Suite struct StableBuildDirTests {
    static let max = 40
    func dir(_ work: String, _ task: String, id: String = "a1b2c3d4", attempt: Int, lane: Int? = nil) -> String {
        AgentNaming.buildDir(AgentNaming.name(work: work, task: task, taskId: id, attempt: attempt, lane: lane), max: Self.max)
    }
    func shown(_ terminal: String) -> String {
        CollieOrientation.text(terminal: terminal, isShepherd: false, paddock: nil, peers: [], panels: [], sharedFolder: ["other"])
    }

    @Test func attemptsOfOneTaskShareTheFolder() {
        let t1 = dir("Collie Main 2026", "M11.3 Build estável", attempt: 1), t2 = dir("Collie Main 2026", "M11.3 Build estável", attempt: 2)
        #expect(t1 == t2 && t1.hasPrefix("laco-"), "\(t1) \(t2)")
        #expect(!t1.contains("-t1") && !t1.hasSuffix("-t2"))
        // the orientation tells it
        let name = AgentNaming.name(work: "Collie Main 2026", task: "M11.3 Build estável", taskId: "x", attempt: 2, lane: nil)
        #expect(shown(name).contains(".build/\(t1) (--scratch-path)"), "\(shown(name))")
    }

    @Test func otherTasksAndWorksGetOtherFolders() {
        let base = dir("collie-main", "build", attempt: 1)
        #expect(base != dir("collie-main", "prune", attempt: 1))
        #expect(base != dir("outro-trabalho", "build", attempt: 1))
    }

    @Test func twoLiveLanesNeverShare() {
        let f1 = dir("collie-main", "build", attempt: 1, lane: 1), f2 = dir("collie-main", "build", attempt: 1, lane: 2)
        #expect(f1 != f2 && f1.hasSuffix("-f1") && f2.hasSuffix("-f2"), "\(f1) \(f2)")
        #expect(f1 == dir("collie-main", "build", attempt: 3, lane: 1))
        // long titles: the lane survives the cut
        let long = dir(String(repeating: "trabalho-", count: 5), String(repeating: "tarefa-", count: 5), attempt: 1, lane: 7)
        #expect(long.hasSuffix("-f7") && long.count <= Self.max, "\(long)")
    }

    @Test func anOrdinaryTerminalIsAsBefore() {
        #expect(AgentNaming.buildDir("Ana", max: Self.max) == "Ana")
        #expect(AgentNaming.buildDir("front end/api", max: Self.max) == "front-end-api")
        #expect(AgentNaming.buildDir("solo", max: Self.max) == "solo")
        #expect(AgentNaming.buildDir(String(repeating: "x", count: 60), max: Self.max).count == Self.max)
        #expect(shown("Ana").contains(".build/Ana (--scratch-path)"))
    }

    @Test func neverAPathOrASpace() {
        for t in ["../../etc-t1", "a b/c-d-t2", "..", "x/..-y-f1-t3", "w-t-f1-t2", AgentNaming.name(work: "../x y", task: "a/b", taskId: "..", attempt: 1, lane: 2)] {
            let d = AgentNaming.buildDir(t, max: Self.max)
            #expect(!d.contains("/") && !d.contains("..") && !d.contains(" ") && !d.isEmpty, "\(t) -> \(d)")
        }
    }

    @Test func tightOrientationDoesNotGrow() {
        let name = AgentNaming.name(work: "collie-main", task: "build", taskId: "x", attempt: 2, lane: 1)
        let tight = CollieOrientation.text(terminal: name, isShepherd: true, paddock: "P", peers: (1...30).map { "agent-\($0)" },
                                           panels: [], lot: (String(repeating: "l", count: 60), String(repeating: "g", count: 200)),
                                           sharedFolder: ["x"])
        #expect(tight.contains("- Shared folder: own build dir;"), "\(tight)")
    }
}
