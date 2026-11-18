import Testing
import Foundation
@testable import CollieDaemonKit

/// Item 7 of spec 2026-11-17-memory-stage-rules: a map's file changed past a threshold since its anchor commit.
@Suite struct MapDriftTests {
    // MARK: thresholds (pure)

    @Test func fileThresholdIsFortyLinesOrFortyPercent() {
        let small = PathExtent(isDir: false, lines: 50, files: nil)
        #expect(!MapDrift.exceeds(PathChange(added: 20, deleted: 19, files: 1), small))   // 39 < 40
        #expect(MapDrift.exceeds(PathChange(added: 20, deleted: 20, files: 1), small))    // 40
        let big = PathExtent(isDir: false, lines: 1000, files: nil)
        #expect(!MapDrift.exceeds(PathChange(added: 200, deleted: 199, files: 1), big))   // 399 < 400
        #expect(MapDrift.exceeds(PathChange(added: 200, deleted: 200, files: 1), big))
        let unknownSize = PathExtent(isDir: false, lines: nil, files: nil)
        #expect(MapDrift.exceeds(PathChange(added: 40, deleted: 0, files: 1), unknownSize))
    }

    @Test func dirThresholdIsFiveFilesOrThirtyPercent() {
        let few = PathExtent(isDir: true, lines: nil, files: 10)
        #expect(!MapDrift.exceeds(PathChange(added: 900, deleted: 0, files: 4), few))     // lines don't count for a dir
        #expect(MapDrift.exceeds(PathChange(added: 1, deleted: 0, files: 5), few))
        let many = PathExtent(isDir: true, lines: nil, files: 100)
        #expect(!MapDrift.exceeds(PathChange(added: 1, deleted: 0, files: 29), many))
        #expect(MapDrift.exceeds(PathChange(added: 1, deleted: 0, files: 30), many))
    }

    @Test func nothingChangedNeverExceeds() {
        #expect(!MapDrift.exceeds(PathChange(), PathExtent(isDir: false, lines: 0, files: nil)))
        #expect(!MapDrift.exceeds(PathChange(), PathExtent(isDir: true, lines: nil, files: 0)))
    }

    // MARK: live git

    private func repo() async throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-drift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let real = d.resolvingSymlinksInPath()
        _ = try await git(["init", "-q", "-b", "main"], real)
        return real
    }
    @discardableResult
    private func git(_ a: [String], _ d: URL) async throws -> String {
        let r = try await GitRunner.run(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a, in: d)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ rel: String, lines: Range<Int>, tag: String = "l", in d: URL) throws {
        let u = d.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.map { "\(tag)\($0)\n" }.joined().write(to: u, atomically: true, encoding: .utf8)
    }
    private func commitAll(_ m: String, _ d: URL) async throws -> String {
        try await git(["add", "-A"], d); try await git(["commit", "-q", "-m", m], d)
        return try await git(["rev-parse", "HEAD"], d)
    }

    @Test func measuresFileAndDirChangesBetweenCommits() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try write("a.swift", lines: 0..<100, in: d)
        for i in 0..<6 { try write("Dir/f\(i).swift", lines: 0..<3, in: d) }
        try Data([0, 1, 2, 3]).write(to: d.appendingPathComponent("Dir/blob.bin"))
        let anchor = try await commitAll("one", d)
        try write("a.swift", lines: 0..<100, tag: "x", in: d)   // 100 lines replaced: +100 −100
        for i in 0..<2 { try write("Dir/f\(i).swift", lines: 0..<4, in: d) }
        try Data([9, 9, 0, 9]).write(to: d.appendingPathComponent("Dir/blob.bin"))   // binary: ignored
        let head = try await commitAll("two: reescreve a", d)
        let live = GitFactsLive(root: d)
        #expect(await live.head() == head)
        let got = await live.changes(from: anchor, to: head, paths: ["a.swift", "Dir", "untouched.swift"])
        #expect(got == .changes(["a.swift": PathChange(added: 100, deleted: 100, files: 1),
                                 "Dir": PathChange(added: 2, deleted: 0, files: 2)]))
        #expect(await live.extent("a.swift") == PathExtent(isDir: false, lines: 100, files: nil))
        #expect(await live.extent("Dir") == PathExtent(isDir: true, lines: nil, files: 7))
        #expect(await live.subjects(from: anchor, to: head, path: "a.swift") == ["two: reescreve a"])
        #expect(await live.subjects(from: anchor, to: head, path: "untouched.swift").isEmpty)
    }

    /// The repo is the user's (an agent may have planted config): no diff driver, textconv or external diff ever runs.
    @Test func plantedDiffDriverTextconvAndExternalDiffNeverRun() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        let marker = d.appendingPathComponent("PWNED")
        let evil = "sh -c 'touch \(marker.path)'"
        try await git(["config", "diff.evil.command", evil], d)
        try await git(["config", "diff.evil.textconv", "sh -c 'touch \(marker.path); cat \"$0\"'"], d)
        try await git(["config", "diff.external", evil], d)
        try await git(["config", "log.showSignature", "true"], d)
        try await git(["config", "gpg.program", evil], d)
        try "*.swift diff=evil\n".write(to: d.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try write("a.swift", lines: 0..<10, in: d)
        let anchor = try await commitAll("one", d)
        try write("a.swift", lines: 0..<60, tag: "y", in: d)
        let head = try await commitAll("two", d)
        let live = GitFactsLive(root: d)
        #expect(await live.changes(from: anchor, to: head, paths: ["a.swift"]) == .changes(["a.swift": PathChange(added: 60, deleted: 10, files: 1)]))
        _ = await live.subjects(from: anchor, to: head, path: "a.swift")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A pathspec magic or glob in a map's path is a literal name, never a pattern.
    @Test func pathIsLiteralNotAPattern() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try write("a.swift", lines: 0..<5, in: d)
        let anchor = try await commitAll("one", d)
        try write("a.swift", lines: 0..<50, tag: "z", in: d)
        let head = try await commitAll("two", d)
        let live = GitFactsLive(root: d)
        #expect(await live.changes(from: anchor, to: head, paths: ["*.swift", ":(glob)**"]) == .changes([:]))
    }

    @Test func goneAnchorAndNonRepoAndBadAnchor() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try write("a.swift", lines: 0..<5, in: d)
        let head = try await commitAll("one", d)
        let live = GitFactsLive(root: d)
        #expect(await live.changes(from: String(repeating: "ab", count: 20), to: head, paths: ["a.swift"]) == .anchorGone)
        #expect(await live.changes(from: "--output=/tmp/x", to: head, paths: ["a.swift"]) == .unknown)   // not a SHA
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("collie-drift-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let none = GitFactsLive(root: plain)
        #expect(await none.head() == nil)
        #expect(await none.changes(from: head, to: head, paths: ["a.swift"]) == .unknown)
    }

    /// A symlinked map path is never read through (it could point anywhere).
    @Test func symlinkHasNoExtent() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        #expect(await GitFactsLive(root: d).extent("link") == nil)
        #expect(await GitFactsLive(root: d).extent("../escape") == nil)
    }

    /// Review finding 4: special files are never read, nor through a symlink inside the repo (a FIFO would block the pass,
    /// `/dev/zero` would fill memory). One open (O_NOFOLLOW|O_NONBLOCK), then fstat: no window between check and read.
    /// ponytail: the check-then-read race itself can't be staged in a test; these cases guard the single-open path.
    @Test func specialFilesAndSymlinksHaveNoExtent() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(mkfifo(d.appendingPathComponent("fifo").path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("tofifo").path, withDestinationPath: "fifo")
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("zero").path, withDestinationPath: "/dev/zero")
        try write("real.txt", lines: 0..<3, in: d)
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("toreal").path, withDestinationPath: "real.txt")
        let live = GitFactsLive(root: d)
        for p in ["fifo", "tofifo", "zero", "toreal"] { #expect(await live.extent(p) == nil, "\(p)") }
        #expect(await live.extent("real.txt") == PathExtent(isDir: false, lines: 3, files: nil))
    }

    /// Over the read cap: the size is unknown (only the absolute threshold applies), never read whole.
    @Test func bigFileHasNoLineCount() async throws {
        let d = try await repo()
        defer { try? FileManager.default.removeItem(at: d) }
        try Data(repeating: 0x0A, count: MapDrift.maxReadBytes + 1).write(to: d.appendingPathComponent("big.txt"))
        #expect(await GitFactsLive(root: d).extent("big.txt") == PathExtent(isDir: false, lines: nil, files: nil))
    }
}
