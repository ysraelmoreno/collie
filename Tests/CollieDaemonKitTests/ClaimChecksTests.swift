import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct ClaimChecksTests {
    struct Fake: GitFacts {
        var branches: [String: BranchState] = [:]
        var commits: Set<String> = []
        var paths: Set<String> = []
        func branch(_ name: String) async -> BranchState { branches[name] ?? .missing }
        func commitExists(_ sha: String) async -> Bool { commits.contains(sha) }
        func pathExists(_ rel: String) -> Bool { paths.contains(rel) }
    }
    func rec(_ body: String, path: String? = nil) -> MemoryRecord {
        MemoryRecord(kind: .decision, subject: "s", title: "t", body: body, path: path, createdAt: Date())
    }

    @Test func mergedBranchWithNegatedBodyFails() async {
        let f = await ClaimChecks.check(rec("fix/x não foi mergeado ainda"), facts: Fake(branches: ["fix/x": .merged]))
        #expect(f == [ClaimFailure(kind: .branchMerged, detail: "fix/x")])
    }
    @Test func missingBranchWithNegationFails() async {
        let f = await ClaimChecks.check(rec("fix/x pending"), facts: Fake())
        #expect(f == [ClaimFailure(kind: .branchMissing, detail: "fix/x")])
    }
    @Test func mergedBranchWithoutNegationPasses() async {
        let f = await ClaimChecks.check(rec("a branch fix/x resolveu isso"), facts: Fake(branches: ["fix/x": .merged]))
        #expect(f.isEmpty)
    }
    @Test func openBranchPasses() async {
        let f = await ClaimChecks.check(rec("fix/x pendente"), facts: Fake(branches: ["fix/x": .open]))
        #expect(f.isEmpty)
    }
    @Test func negationWordsPtAndEn() async {
        for w in ["não mergeado", "não foi mergeado", "pendente", "ainda não", "not merged", "PENDING"] {
            let f = await ClaimChecks.check(rec("feat/a \(w)"), facts: Fake(branches: ["feat/a": .merged]))
            #expect(f.count == 1, "\(w)")
        }
    }
    @Test func unknownShaFails() async {
        let f = await ClaimChecks.check(rec("veja o commit abc1234"), facts: Fake())
        #expect(f == [ClaimFailure(kind: .commitMissing, detail: "abc1234")])
        let ok = await ClaimChecks.check(rec("veja o commit abc1234"), facts: Fake(commits: ["abc1234"]))
        #expect(ok.isEmpty)
    }
    @Test func shortHexWordNotASha() async {
        for body in ["abc123 curto", "deadbeef só letras", "1234567 só dígitos", "id 0a1b2c3d-1111-2222 uuid", "face-b00c1234"] {
            #expect(await ClaimChecks.check(rec(body), facts: Fake()).isEmpty, "\(body)")
        }
    }
    @Test func missingPathFails() async {
        let f = await ClaimChecks.check(rec("x", path: "Sources/Gone.swift"), facts: Fake())
        #expect(f == [ClaimFailure(kind: .pathMissing, detail: "Sources/Gone.swift")])
        #expect(await ClaimChecks.check(rec("x", path: "a.swift"), facts: Fake(paths: ["a.swift"])).isEmpty)
    }
    @Test func dedupes() async {
        let f = await ClaimChecks.check(rec("abc1234 e de novo abc1234"), facts: Fake())
        #expect(f.count == 1)
    }
    @Test func noClaimsNoFailures() async {
        #expect(await ClaimChecks.check(rec("nada a verificar"), facts: Fake()).isEmpty)
    }

    @Test func liveRepo() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-claims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        func git(_ a: String...) async throws -> String {
            let r = try await GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@t"] + a, in: d)
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git("init", "-q", "-b", "main")
        try "a".write(to: d.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git("add", "a.txt"); _ = try await git("commit", "-q", "-m", "one")
        let sha = try await git("rev-parse", "HEAD")
        _ = try await git("branch", "fix/merged")
        _ = try await git("checkout", "-q", "-b", "fix/open")
        try "b".write(to: d.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await git("add", "b.txt"); _ = try await git("commit", "-q", "-m", "two")
        let live = GitFactsLive(root: d)
        #expect(await live.branch("fix/merged") == .merged)
        #expect(await live.branch("fix/open") == .open)
        #expect(await live.branch("fix/nope") == .missing)
        #expect(await live.commitExists(sha))
        #expect(await live.commitExists("1234567") == false)
        #expect(live.pathExists("a.txt")); #expect(!live.pathExists("zzz"))
    }
}
