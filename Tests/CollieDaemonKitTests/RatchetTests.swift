import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private typealias R = Ratchet
private func b(_ text: String) throws -> R.Baseline { try R.Baseline.parse(text) }

/// A project folder the test removes at the end.
private func project(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory))
        .appendingPathComponent("ratchet-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts/ci"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}
private func file(_ dir: URL, _ rel: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
private func apply(_ a: FactoryRatchet.Action, _ dir: URL, measured: String, reason: String? = nil, rel: String = "scripts/ci/base.txt") throws -> FactoryRatchet.Outcome {
    try FactoryRatchet.apply(a, name: "lint", root: dir, baselinePath: rel, measured: measured, reason: reason,
                             now: Date(timeIntervalSince1970: 1_795_000_000))
}

@Suite struct RatchetTests {
    @Test func parseRenderRoundTrips() throws {
        let text = "# comentário\n\nsleep Sources/B.swift 2\nforce  Sources/A.swift\t1\nzero x 0\n"
        let x = try b(text)
        #expect(x.counts == ["sleep Sources/B.swift": 2, "force Sources/A.swift": 1])
        #expect(x.render() == "force Sources/A.swift 1\nsleep Sources/B.swift 2\n")
        #expect(try b(x.render()) == x)
        #expect(throws: R.Refusal.badLine(1, "sem-numero")) { try b("sem-numero") }
        #expect(throws: R.Refusal.badLine(1, "k -1")) { try b("k -1") }
        #expect(throws: R.Refusal.duplicate("a b")) { try b("a b 1\na b 2") }
    }

    @Test func compareVerdicts() throws {
        let base = try b("r a 2\nr b 1\n")
        #expect(R.compare(baseline: base, current: try b("r b 1\nr a 2")) == .same)
        #expect(R.compare(baseline: base, current: try b("r a 1\n")) ==
                .improved([.init(key: "r a", before: 2, after: 1), .init(key: "r b", before: 1, after: 0)]))
        #expect(R.compare(baseline: base, current: try b("r a 3\nr b 1")) == .worse([.init(key: "r a", before: 2, after: 3)]))
        #expect(R.compare(baseline: base, current: try b("r a 2\nr b 1\nr c 1")) == .worse([.init(key: "r c", before: 0, after: 1)]))
        // both at once: worse wins and lists only what went up
        #expect(R.compare(baseline: base, current: try b("r a 1\nr c 4")) == .worse([.init(key: "r c", before: 0, after: 4)]))
    }

    @Test func loweredOnlyWhenNothingWentUp() throws {
        let base = try b("r a 2\nr b 1\n")
        #expect(R.lowered(baseline: base, current: try b("r a 1")) == (try b("r a 1")))
        #expect(R.lowered(baseline: base, current: try b("r a 1\nr c 1")) == nil)
        #expect(R.lowered(baseline: base, current: base) == base)
    }

    @Test func raiseNeedsAReason() throws {
        let base = try b("r a 1"), cur = try b("r a 3\nr b 1"), day = Date(timeIntervalSince1970: 1_795_000_000)
        for bad in ["", "   ", String(repeating: "x", count: 201), "a\u{7}b"] {
            #expect(throws: R.Refusal.badReason) { try R.raise(baseline: base, to: cur, reason: bad, date: day) }
        }
        let up = try R.raise(baseline: base, to: cur, reason: "migração do parser", date: day)
        #expect(up.baseline == cur)
        #expect(up.log == ["# 2026-11-18: r a 1 -> 3: migração do parser", "# 2026-11-18: r b 0 -> 1: migração do parser"])
    }

    @Test func listOnlyShrinks() {
        #expect(R.compareList(baseline: ["A", "B"], current: ["B", "A"]) == .same)
        #expect(R.compareList(baseline: ["A", "B"], current: ["A"]) == .improved([.init(key: "B", before: 1, after: 0)]))
        #expect(R.compareList(baseline: ["A"], current: ["B"]) == .worse([.init(key: "B", before: 0, after: 1)]))
    }

    /// Parity with scripts/ci/lint.sh on the three cases of test-lint.sh (the same fixture, its counts as lint.sh measures them):
    /// exact baseline passes; a new sleep in a.swift goes over; b.swift without the @unchecked goes under (lint: --update-baseline).
    @Test func sameVerdictAsLintSh() throws {
        let base = try b("force Sources/A/a.swift 1\nsleep Sources/A/a.swift 1\nunsafe-concurrency Sources/A/b.swift 1\n")
        #expect(R.compare(baseline: base, current: base) == .same)                                     // lint ok, rc 0
        #expect(R.compare(baseline: base, current: try b("force Sources/A/a.swift 1\nsleep Sources/A/a.swift 2\nunsafe-concurrency Sources/A/b.swift 1"))
                == .worse([.init(key: "sleep Sources/A/a.swift", before: 1, after: 2)]))            // "passou do baseline", rc 1
        #expect(R.compare(baseline: base, current: try b("force Sources/A/a.swift 1\nsleep Sources/A/a.swift 1"))
                == .improved([.init(key: "unsafe-concurrency Sources/A/b.swift", before: 1, after: 0)]))   // "menos ocorrências", rc 1
        #expect(try b("force Sources/A/a.swift 1\nsleep Sources/A/a.swift 1").render() == "force Sources/A/a.swift 1\nsleep Sources/A/a.swift 1\n")
    }

    @Test func commandChecksUpdatesAndRaises() throws {
        try project { dir in
            try Data("# 2026-01-01: velho\nr a 2\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try apply(.check, dir, measured: "r a 2\n") == .init(output: "catraca lint: igual ao baseline\n", passed: true, wrote: false))
            let better = try apply(.check, dir, measured: "r a 1\n")
            #expect(!better.passed && better.output.contains("collie factory ratchet update lint"))
            // update refuses to raise and leaves the file as it was
            let worse = try apply(.update, dir, measured: "r a 3\n")
            #expect(!worse.passed && !worse.wrote && file(dir, "scripts/ci/base.txt") == "# 2026-01-01: velho\nr a 2\n")
            #expect(try apply(.update, dir, measured: "r a 1\n").wrote)
            #expect(file(dir, "scripts/ci/base.txt") == "# 2026-01-01: velho\nr a 1\n")
            #expect(throws: ProtocolError.self) { try apply(.raise, dir, measured: "r a 5\n", reason: " ") }
            #expect(try apply(.raise, dir, measured: "r a 5\n", reason: "novo módulo").wrote)
            #expect(file(dir, "scripts/ci/base.txt") == "# 2026-01-01: velho\n# 2026-11-18: r a 1 -> 5: novo módulo\nr a 5\n")
            // atomic: no temporary file left next to it
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts/ci").path)
            #expect(left == ["base.txt"])
            // a first baseline: absent file is empty
            #expect(try apply(.raise, dir, measured: "x 1\n", reason: "início", rel: "scripts/ci/new.txt").wrote)
            #expect(file(dir, "scripts/ci/new.txt") == "# 2026-11-18: x 0 -> 1: início\nx 1\n")
        }
    }

    @Test func baselineConfinedToTheProject() throws {
        try project { dir in
            for rel in ["../fora.txt", "scripts/../../fora.txt", "/tmp/fora.txt", "scripts//base.txt", "nao/existe/base.txt"] {
                #expect(throws: ProtocolError.self) { try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: rel) }
            }
            // a symlink as destination is refused, and what it points to stays untouched
            let outside = dir.deletingLastPathComponent().appendingPathComponent("ratchet-alvo-\(UUID().uuidString.prefix(6)).txt")
            try Data("intocado\n".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/ci/link.txt"), withDestinationURL: outside)
            #expect(throws: ProtocolError.self) { try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: "scripts/ci/link.txt") }
            #expect(try String(contentsOf: outside, encoding: .utf8) == "intocado\n")
            // a symlinked folder on the way leads out: refused
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("saida"), withDestinationURL: dir.deletingLastPathComponent())
            #expect(throws: ProtocolError.self) { try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: "saida/base.txt") }
        }
    }

    /// F1 (blocker 2): the command refuses what the parser refuses, folder present or not, and writes nothing.
    @Test func dangerousBaselinesRefused() throws {
        try project { dir in
            for d in ["dir/.git", "x.git", ".collie", "scripts/.git"] {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            let bad = ["dir/.git", "dir/.git/config", "x.git/y", ".collie/b", ".git", "scripts/.git/HEAD", "collie-work.json",
                       "scripts/collie-work.json", "scripts/./base.txt", "./base.txt", "scripts/ci/", "SCRIPTS/.GIT/x"]
            for rel in bad {
                #expect(!FactoryProfile.confinedPath(rel), "\(rel)")
                #expect(throws: ProtocolError.self, "\(rel)") { try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: rel) }
            }
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.git/y").path))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("collie-work.json").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".collie").path).isEmpty)
        }
    }

    /// F1 (major 2): the folder is walked by fd without following links: a link on the way, even to a folder inside the
    /// project, is refused; nothing lands at the link's target and no temporary file is left.
    @Test func symlinkedFolderRefusedByFd() throws {
        try project { dir in
            let out = dir.deletingLastPathComponent().appendingPathComponent("ratchet-fora-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/fora"), withDestinationURL: out)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dentro"), withDestinationURL: dir.appendingPathComponent("scripts/ci"))
            for rel in ["scripts/fora/base.txt", "dentro/base.txt"] {
                #expect(throws: ProtocolError.self, "\(rel)") { try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: rel) }
                #expect(throws: ProtocolError.self, "\(rel)") { try FactoryRatchet.openDir(root: dir, rel: rel) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts/ci").path).isEmpty)
            // the fd path: read and write go through the opened folder
            let fd = try FactoryRatchet.openDir(root: dir, rel: "scripts/ci/base.txt")
            defer { close(fd) }
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "")
            try FactoryRatchet.write("a 1\n", dir: fd, "base.txt", rel: "scripts/ci/base.txt")
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "a 1\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts/ci").path) == ["base.txt"])
            // a link as the file itself: read and write refuse it
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/ci/l.txt"), withDestinationURL: out.appendingPathComponent("x"))
            #expect(throws: ProtocolError.self) { try FactoryRatchet.read(dir: fd, "l.txt", rel: "l.txt") }
            #expect(throws: ProtocolError.self) { try FactoryRatchet.write("a 1\n", dir: fd, "l.txt", rel: "l.txt") }
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("x").path))
        }
    }

    /// F1 (minor 6): an empty measurement over a non-empty baseline is refused by update and flagged by check.
    @Test func emptyMeasurementRefused() throws {
        try project { dir in
            try Data("r a 2\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(throws: ProtocolError.self) { try apply(.update, dir, measured: "") }
            #expect(file(dir, "scripts/ci/base.txt") == "r a 2\n")
            let c = try apply(.check, dir, measured: "\n")
            #expect(!c.passed && c.output.contains("vazia (0 chaves)"))
            // empty over empty is just equal
            #expect(try apply(.update, dir, measured: "", rel: "scripts/ci/new.txt").passed)
        }
    }

    /// F1 (blocker 1): with `sandboxHome` the measure gets the terminal's profile and the sandbox's HOME; without a profile it
    /// is refused and nothing runs; without `sandboxHome` it runs unsandboxed. No real `sandbox-exec` (it does not nest).
    @Test func measureRunsSandboxed() async throws {
        let collie = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("ratchet-sb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: collie.appendingPathComponent("sandbox"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: collie) }
        let id = UUID(), home = collie.appendingPathComponent("home"), root = collie.appendingPathComponent("proj")
        final class Calls: @unchecked Sendable { var list: [(URL?, [String: String])] = [] }
        let calls = Calls()
        func run(sandboxHome: URL?, sandboxed: Bool) async throws(ProtocolError) -> ProcessResult {
            try await FactoryRatchet.measure("echo a 1", in: root, sandboxHome: sandboxHome, terminal: id, sandboxed: sandboxed, collieRoot: collie,
                                             shell: "/bin/zsh", user: ["HOME": "/Users/real", "PATH": "/usr/bin:/bin"]) { (_, _, p, e) async throws(ProtocolError) in
                calls.list.append((p, e)); return ProcessResult(status: 0, stdout: "a 1\n", stderr: "", truncated: false)
            }
        }
        // no profile file yet: refused, nothing run (sandboxed terminal or not)
        await #expect(throws: ProtocolError.self) { try await run(sandboxHome: home, sandboxed: true) }
        try Data("(version 1)".utf8).write(to: SandboxLaunch.profileFile(id, root: collie))
        await #expect(throws: ProtocolError.self) { try await run(sandboxHome: home, sandboxed: false) }
        #expect(calls.list.isEmpty)
        _ = try await run(sandboxHome: home, sandboxed: true)
        #expect(calls.list.count == 1 && calls.list[0].0 == SandboxLaunch.profileFile(id, root: collie) && calls.list[0].1["HOME"] == home.path)
        _ = try await run(sandboxHome: nil, sandboxed: false)
        #expect(calls.list.count == 2 && calls.list[1].0 == nil && calls.list[1].1["HOME"] == "/Users/real")
    }

    @Test func commandIsRegistered() throws {
        for a in ["check", "update", "raise"] { #expect(Commands.spec("factory.ratchet.\(a)") != nil) }
        let r = try ArgvParser.parse(["factory", "ratchet", "raise", "lint", "--reason", "porque sim"])
        #expect(r.command == "factory.ratchet.raise" && r.args["name"] == .string("lint") && r.args["reason"] == .string("porque sim"))
        #expect(try ArgvParser.parse(["factory", "ratchet", "check", "lint"]).command == "factory.ratchet.check")
    }
}
