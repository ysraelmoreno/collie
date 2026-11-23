import Testing
import Foundation
@testable import CollieDaemonKit

/// The daemon runs git outside any sandbox on repos an agent can write (`.git/config` included).
@Suite struct GitRunnerSafetyTests {
    /// A planted promisor remote (partial clone, `ext::` transport) runs its command on a lazy fetch of a missing object:
    /// `rev-parse <anchor>^{commit}` of an orphaned anchor, or `commitExists` of a SHA named in a memory.
    @Test func plantedPromisorRemoteNeverRunsOnAMissingObject() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-lazy-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let sentinel = d.appendingPathComponent("SENT")
        func git(_ a: String...) async throws { _ = try await GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@t"] + a, in: d) }
        try await git("init", "-q", "-b", "main")
        try await git("commit", "-q", "--allow-empty", "-m", "one")
        let head = try await GitRunner.run(["rev-parse", "HEAD"], in: d).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git("config", "core.repositoryformatversion", "1")
        try await git("config", "extensions.partialClone", "origin")
        try await git("config", "remote.origin.promisor", "true")
        try await git("config", "remote.origin.url", "ext::sh -c touch% \(sentinel.path)")
        try await git("config", "protocol.ext.allow", "always")
        let missing = String(repeating: "ab", count: 20)
        let live = GitFactsLive(root: d)
        #expect(await live.changes(from: missing, to: head, paths: ["a"]) == .anchorGone)
        _ = await live.commitExists("abcdef1234567")
        _ = await live.commitExists(missing)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}

/// F2 U2 (reviewNoReplace): no git of the daemon reads a replacement object.
@Suite struct GitRunnerTests {
    @Test func replaceObjectsAreIgnored() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-replace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        func git(_ a: String...) async throws -> String {
            try await GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@t"] + a, in: d).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git("init", "-q", "-b", "main")
        try "real\n".write(to: d.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = try await git("add", "f"); _ = try await git("commit", "-qm", "real")
        let real = try await git("rev-parse", "HEAD")
        try "fake\n".write(to: d.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = try await git("commit", "-qam", "fake")
        let fake = try await git("rev-parse", "HEAD")
        _ = try await git("replace", real, fake)
        _ = try await git("commit-graph", "write", "--reachable")
        #expect(try await git("show", "\(real):f") == "real")
        #expect(try await git("log", "-1", "--format=%s", real) == "real")
    }
}
