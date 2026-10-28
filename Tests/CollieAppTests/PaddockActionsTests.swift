import Foundation
import Testing
import CollieClient
import CollieCore
@testable import CollieApp

@MainActor private func actions() -> PaddockActions {
    PaddockActions(client: DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-paddocks-\(UUID())"))))
}
private let paddock = Paddock(id: UUID(), name: "api", repoRoot: "/r", path: "/r/.collie/paddocks/api", branch: "collie/api", baseBranch: "main")

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

/// The dialog's paddock is gone (deleted elsewhere): nothing is sent.
@MainActor @Test func deleteSkipsMissingPaddock() {
    let a = actions()
    a.deleting = paddock
    a.delete(force: false)
    #expect(!a.busy)
}

@MainActor @Test func paddockPaletteCommands() {
    let a = actions()
    #expect(a.commands(for: paddock).map(\.title) == ["Status do cercado api…", "Land api…", "Excluir cercado api…"])
    a.run { try await Task.sleep(for: .seconds(1)) }
    #expect(a.commands(for: paddock).map(\.title) == ["Status do cercado api…"])   // Land / Excluir wait for the running one
}

@MainActor @Test func folderPaddockHasNoLand() {
    let a = actions()
    #expect(a.commands(for: .folder(name: "docs", path: "/d")).map(\.title) == ["Status do cercado docs…", "Excluir cercado docs…"])
}

@Test func newPaddockForm() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("collie-form-\(UUID())").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let plain = home.appendingPathComponent("plain"), repo = home.appendingPathComponent("repo"), sub = repo.appendingPathComponent("src")
    for d in [plain, repo.appendingPathComponent(".git"), sub] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    var f = NewPaddockForm()
    #expect(!f.canCreate && !f.worktree)
    f.name = "Meu Cercado"; f.folder = repo.path
    #expect(f.isGit && f.worktree && f.canCreate && f.slug == "meu-cercado")   // a git folder: isolated by default
    f.isolate = false
    #expect(!f.worktree)
    f.isolate = true; f.folder = plain.path
    #expect(!f.isGit && !f.worktree && f.canCreate)   // never a worktree off a non-git folder
    try fm.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)   // a dotfiles repo at home
    #expect(!NewPaddockForm.isGit(plain.path, home: home.path) && NewPaddockForm.isGit(sub.path, home: home.path))
}
