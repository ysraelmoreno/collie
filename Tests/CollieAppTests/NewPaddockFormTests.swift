import Foundation
import Testing
@testable import CollieApp

/// A3: "Cercado fábrica" in the Novo cercado sheet: off by default, only over a git folder.
@Suite(.appPT) struct NewPaddockFormTests {
    private func dirs() throws -> (home: URL, plain: URL, repo: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("collie-form-\(UUID())").resolvingSymlinksInPath()
        let plain = home.appendingPathComponent("plain"), repo = home.appendingPathComponent("repo")
        for d in [plain, repo.appendingPathComponent(".git")] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        return (home, plain, repo)
    }

    @Test func factoryOffByDefault() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.home) }
        #expect(!NewPaddockForm().factory)
        #expect(!NewPaddockForm(folder: d.repo.path).factory)
    }

    @Test func factoryOnlyWithAGitFolder() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.home) }
        var f = NewPaddockForm()
        f.factory = true
        #expect(!f.factory)   // no folder yet
        f.folder = d.plain.path; f.factory = true
        #expect(!f.factory)   // not git
        f.folder = d.repo.path; f.factory = true; f.name = "api"
        #expect(f.factory && f.canCreate)
        f.folder = d.plain.path
        #expect(!f.factory && f.canCreate)   // moved off git: unchecked, still creatable
    }
}
