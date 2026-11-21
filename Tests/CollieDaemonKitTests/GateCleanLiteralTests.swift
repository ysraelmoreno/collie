import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func write(_ text: String, _ file: String, in dir: URL) {
    do {
        let u = dir.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    } catch { Issue.record("write \(file): \(error)") }
}
private func read(_ file: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) }
private func exists(_ file: String, in dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) }

/// A real temporary repo, a fake host (real git, real gate) and the integrator.
private struct Rig {
    let repo: URL, host: LoopFakeHost, integ: LaneIntegrator, base: String, work = UUID()
    init() async throws {
        repo = try await makeRepo(); host = LoopFakeHost(dir: repo)
        integ = LaneIntegrator(host: host, dir: repo)
        base = try await git(repo, "rev-parse", "HEAD")
    }
    /// A lane that adds `file`, integrated under `gate`.
    func go(_ task: String, gate: String) async throws -> LaneIntegrator.Result {
        let l = try await LaneWorktree.create(repoRoot: repo, base: base, work: work, task: task, host: host)
        try await commit("\(task).txt", "\(task)\n", in: l.path)
        return try await integ.integrate(l, title: "T \(task)", attempt: 1, tries: 3, gate: gate, gateTimeout: .seconds(60))
    }
    var box: URL { repo.appendingPathComponent(".git/\(LaneIntegrator.quarantineDir)") }
    func quarantined(_ file: String, _ n: Int = 1) -> String? { read("\(n)/\(file)", in: box) }
    /// The sweep `n`'s box, as git names it (`/private/var` and `/var` are the same folder).
    func isBox(_ path: String?, _ n: Int) -> Bool {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == box.appendingPathComponent("\(n)").resolvingSymlinksInPath().path } ?? false
    }
}

/// M6.3: the gate's leftovers are taken by literal name and moved into a quarantine in the git dir, never removed.
@Suite(.timeLimit(.minutes(3))) struct GateCleanLiteralTests {
    @Test func aGlobNameIsThatFileAndTheOwnersSurvive() async throws {
        let rig = try await Rig()
        for f in ["pages/i.js", "pages/d.js", "keep.txt", "x"] { write("owner \(f)\n", f, in: rig.repo) }
        let r = try await rig.go("a", gate: "echo gate > 'pages/[id].js'")
        #expect(r.outcome == .integrated, "\(r.outcome)")
        #expect(r.left == ["pages/[id].js"], "\(r.left)")
        let s = await rig.integ.sweep()
        #expect(s.moved == ["pages/[id].js"] && s.spared.isEmpty, "\(s)")
        for f in ["pages/i.js", "pages/d.js", "keep.txt", "x"] { #expect(read(f, in: rig.repo) == "owner \(f)\n", "\(f)") }
        #expect(!exists("pages/[id].js", in: rig.repo))
        #expect(rig.quarantined("pages/[id].js") == "gate\n")
    }

    @Test func magicDashSpaceAndNewlineNamesAreLiteral() async throws {
        let rig = try await Rig()
        write("mine\n", "keep.txt", in: rig.repo)
        write("mine\n", "sub/x", in: rig.repo)
        let names = ["*", ":(top)x", "-rf", "a b.txt", " lead.txt", "new\nline.txt", "?"]
        let r = try await rig.go("a", gate: "echo g > '*'; echo g > ':(top)x'; echo g > ./-rf; echo g > 'a b.txt'; echo g > ' lead.txt'; "
            + "echo g > \"$(printf 'new\\nline.txt')\"; echo g > '?'")
        #expect(r.outcome == .integrated, "\(r.outcome)")
        #expect(Set(r.left) == Set(names), "\(r.left)")
        let s = await rig.integ.sweep()
        #expect(Set(s.moved) == Set(names) && s.spared.isEmpty, "\(s)")
        for n in names {
            #expect(!exists(n, in: rig.repo), "\(n)")
            #expect(rig.quarantined(n) == "g\n", "\(n)")
        }
        #expect(read("keep.txt", in: rig.repo) == "mine\n" && read("sub/x", in: rig.repo) == "mine\n")
        // every git given or listing file names runs literal, and nothing is removed by git
        let gits = await rig.host.gits
        #expect(!gits.contains { $0.contains("clean") }, "\(gits)")
        for g in gits where g.contains(where: { ["hash-object", "ls-files", "status", "diff"].contains($0) }) {
            #expect(g.first == "--literal-pathspecs", "\(g)")
        }
    }

    @Test func aFileTheOwnerMadeDuringTheGateIsMovedNeverLost() async throws {
        let rig = try await Rig()
        // the gate stands in for the owner writing a file while it ran: the integrator cannot tell them apart
        let r = try await rig.go("a", gate: "echo 'my draft' > draft.md")
        #expect(r.left == ["draft.md"])
        let s = await rig.integ.sweep()
        #expect(s.moved == ["draft.md"])
        #expect(!exists("draft.md", in: rig.repo))
        #expect(rig.quarantined("draft.md") == "my draft\n", "recoverable, as it was")
        #expect(rig.isBox(s.at, 1), "\(s.at ?? "nil")")
        #expect(WorkLoop.movedNote(s.moved, at: s.at ?? "").contains(s.at ?? "?"), "the note says where")
    }

    @Test func theNextMergeMovesItAndTheResultSaysWhere() async throws {
        let rig = try await Rig()
        _ = try await rig.go("a", gate: "echo r > report.txt")
        let rb = try await rig.go("b", gate: "echo r2 > report.txt")
        #expect(rb.moved == ["report.txt"] && rig.isBox(rb.quarantine, 1), "\(rb)")
        let s = await rig.integ.sweep()
        #expect(s.moved == ["report.txt"] && rig.isBox(s.at, 2), "a new box per sweep")
        #expect(rig.quarantined("report.txt", 1) == "r\n" && rig.quarantined("report.txt", 2) == "r2\n")
    }

    @Test func theQuarantineKeepsItsFileLimit() async throws {
        let rig = try await Rig()
        let n = LaneIntegrator.quarantineFiles + 5
        _ = try await rig.go("a", gate: "mkdir -p out; i=1; while [ $i -le \(n) ]; do echo $i > out/f$(printf %04d $i).txt; i=$((i+1)); done")
        let s = await rig.integ.sweep()
        #expect(s.moved.count == LaneIntegrator.quarantineFiles && s.spared.count == 5, "\(s.moved.count) \(s.spared.count)")
        for f in s.spared { #expect(exists(f, in: rig.repo), "past the limit it stays: \(f)") }
        for f in s.moved { #expect(!exists(f, in: rig.repo) && rig.quarantined(f) != nil, "\(f)") }
    }

    @Test func theQuarantineKeepsItsByteLimit() async throws {
        let rig = try await Rig()
        _ = try await rig.go("a", gate: "head -c \(LaneIntegrator.quarantineBytes + 1) /dev/zero > big.bin; echo s > small.txt")
        let s = await rig.integ.sweep()
        #expect(s.moved == ["small.txt"] && s.spared == ["big.bin"], "\(s)")
        #expect(exists("big.bin", in: rig.repo))
    }

    @Test func aNameTheIntegratorRefusesIsNeverTouched() async throws {
        for bad in ["..", "../x", "/x", ".git/x", "a/.git/b", ".GIT", "a\\b", "a//b", "./a", ""] {
            #expect(!LaneIntegrator.touchable(bad), "\(bad)")
        }
        for ok in ["pages/[id].js", "*", "-rf", ":(top)x", "a b", "new\nline", "..a", "a.git"] {
            #expect(LaneIntegrator.touchable(ok), "\(ok)")
        }
        let rig = try await Rig()
        _ = try await rig.go("a", gate: "echo g > 'a\\b'")
        let s = await rig.integ.sweep()
        #expect(s.moved.isEmpty && s.spared == ["a\\b"], "\(s)")
        #expect(read("a\\b", in: rig.repo) == "g\n")
    }

    @Test func theNextLoopEmptiesTheQuarantine() async throws {
        let rig = try await Rig()
        _ = try await rig.go("a", gate: "echo r > report.txt")
        #expect(await rig.integ.sweep().moved == ["report.txt"])
        #expect(rig.quarantined("report.txt") == "r\n")
        await LaneIntegrator(host: rig.host, dir: rig.repo).clearQuarantine()
        #expect(!FileManager.default.fileExists(atPath: rig.box.path))
    }
}
