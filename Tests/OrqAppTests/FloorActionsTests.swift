import Foundation
import Testing
import OrqClient
import OrqCore
@testable import OrqApp

@MainActor private func actions() -> FloorActions {
    FloorActions(client: DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("orq-floors-\(UUID())"))))
}
private let floor = Floor(id: UUID(), name: "api", repoRoot: "/r", path: "/r/.orq/floors/api", branch: "orq/api", baseBranch: "main")

@MainActor private func until(_ cond: () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(5)) }
}

/// A short action finishing while a long one (a Land) runs keeps Land / Excluir disabled.
@MainActor @Test func busyCountsOperations() async {
    let a = actions()
    let (gate, open) = AsyncStream<Void>.makeStream()
    var shortDone = false
    a.run { for await _ in gate { break } }
    a.run { shortDone = true }
    await until { shortDone }
    await Task.yield()
    #expect(a.busy)
    open.yield(); open.finish()
    await until { !a.busy }
    #expect(!a.busy)
}

/// The dialog's floor is gone (deleted elsewhere): nothing is sent.
@MainActor @Test func deleteSkipsMissingFloor() {
    let a = actions()
    a.deleting = floor
    a.delete(force: false)
    #expect(!a.busy)
}

@MainActor @Test func floorPaletteCommands() {
    let a = actions()
    #expect(a.commands(for: floor).map(\.title) == ["Status do andar api…", "Land api…", "Excluir andar api…"])
    a.run { try await Task.sleep(for: .seconds(1)) }
    #expect(a.commands(for: floor).map(\.title) == ["Status do andar api…"])   // Land / Excluir wait for the running one
}
