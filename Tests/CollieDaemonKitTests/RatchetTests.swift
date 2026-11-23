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
private let realHome = URL(fileURLWithPath: NSHomeDirectory())
/// The daemon's half alone (F6a: it never writes).
private func daemon(_ a: FactoryRatchet.Action, _ dir: URL, measured: String, reason: String? = nil, rel: String = "scripts/ci/base.txt",
                    home: URL = realHome) throws -> FactoryRatchet.Outcome {
    try FactoryRatchet.apply(a, name: "lint", root: dir, baselinePath: rel, measured: measured, reason: reason,
                             now: Date(timeIntervalSince1970: 1_795_000_000), home: home, collie: home.appendingPathComponent("Library/Application Support/Collie"))
}
private struct Run: Equatable { var output: String, passed: Bool, wrote: Bool }
/// The daemon's answer, then what the CLI does with it: `BaselineWriter` writes `newBaseline` at `root`/`rel`.
private func apply(_ a: FactoryRatchet.Action, _ dir: URL, measured: String, reason: String? = nil, rel: String = "scripts/ci/base.txt",
                   home: URL = realHome) throws -> Run {
    let o = try daemon(a, dir, measured: measured, reason: reason, rel: rel, home: home)
    if let t = o.newBaseline { try BaselineWriter.write(t, root: o.root, rel: o.rel) }
    return Run(output: o.output, passed: o.passed, wrote: o.newBaseline != nil)
}
private func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

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
            // the fd path: the read goes through the opened folder
            let fd = try FactoryRatchet.openDir(root: dir, rel: "scripts/ci/base.txt")
            defer { close(fd) }
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "")
            try Data("a 1\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "a 1\n")
            // a link as the file itself: the read refuses it
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/ci/l.txt"), withDestinationURL: out.appendingPathComponent("x"))
            #expect(throws: ProtocolError.self) { try FactoryRatchet.read(dir: fd, "l.txt", rel: "l.txt") }
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("x").path))
            // A (round 3): the root itself as a link is refused too
            #expect(throws: ProtocolError.self) { try FactoryRatchet.openDir(root: dir.appendingPathComponent("dentro"), rel: "base.txt") }
        }
    }

    @Test func raiseLogKeepsItsLast100Lines() throws {   // nit: the log never grows past what `read` takes
        try project { dir in
            let old = (1...150).map { "# 2026-01-01: k \($0) -> \($0 + 1): r\($0)\n" }.joined() + "k 1\n"
            try Data(old.utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try apply(.raise, dir, measured: "k 2\n", reason: "mais um").wrote)
            let logs = (file(dir, "scripts/ci/base.txt") ?? "").split(separator: "\n").filter { $0.hasPrefix("#") }
            #expect(logs.count == 100 && logs.first == "# 2026-01-01: k 52 -> 53: r52" && logs.last?.hasSuffix("k 1 -> 2: mais um") == true)
            #expect(try apply(.update, dir, measured: "k 1\n").wrote)
            #expect((file(dir, "scripts/ci/base.txt") ?? "").split(separator: "\n").filter { $0.hasPrefix("#") } == logs)
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

    /// F5a (N1, round 2 blocker): the daemon writes unsandboxed, so a root at the home or above it, or a baseline where the
    /// strict profile denies writes, is refused and nothing is written; a common root inside the home still works.
    @Test func homeRootAndDeniedPlacesRefused() throws {
        try project { base in
            let home = base.appendingPathComponent("Users/eu")
            for d in [".ssh", "Library/LaunchAgents", ".config/git", "code/proj"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            let rels = [".zshenv", ".ssh/authorized_keys", "Library/LaunchAgents/x"]
            for root in [home, base.appendingPathComponent("Users"), base] {   // the home and its ancestors
                for rel in rels {
                    #expect(throws: ProtocolError.self, "\(root.path) \(rel)") { try apply(.raise, root, measured: "a 1\n", reason: "r", rel: rel, home: home) }
                }
            }
            // a root under a denied place: everything below it is denied too
            for (root, rel) in [(".ssh", "authorized_keys"), ("Library/LaunchAgents", "x.plist"), (".config/git", "config")] {
                #expect(throws: ProtocolError.self, "\(root)/\(rel)") { try apply(.raise, home.appendingPathComponent(root), measured: "a 1\n", reason: "r", rel: rel, home: home) }
            }
            for rel in rels { #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(rel).path), "\(rel)") }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/git/config").path))
            // a common project root inside the home keeps working, even with a dotfile name
            let proj = home.appendingPathComponent("code/proj")
            #expect(try apply(.raise, proj, measured: "a 1\n", reason: "r", rel: ".zshenv", home: home).wrote)
            #expect(file(proj, ".zshenv") == "# 2026-11-18: a 0 -> 1: r\na 1\n")
        }
    }

    /// F5a (N6): the rewritten baseline keeps the old file's mode; a first one is 0644.
    @Test func rewriteKeepsTheMode() throws {
        try project { dir in
            func mode(_ rel: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(rel).path)[.posixPermissions] as? Int) ?? -1 }
            #expect(try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: "scripts/ci/new.txt").wrote)
            #expect(try mode("scripts/ci/new.txt") == 0o644)
            try Data("a 2\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: dir.appendingPathComponent("scripts/ci/base.txt").path)
            #expect(try apply(.update, dir, measured: "a 1\n").wrote)
            #expect(try mode("scripts/ci/base.txt") == 0o640)
        }
    }

    /// F5a (N6): the parser and `target` refuse the same paths (one function): `~x` and `$x` too.
    @Test func parserAndTargetAgree() throws {
        try project { dir in
            for rel in ["~x", "$x", "~/x", "$HOME/x", "/x", "a/../b", "scripts/ci/base.txt", "a..b/c.txt"] {
                let parser = FactoryProfile.confinedPath(rel)
                let target = (try? FactoryRatchet.target(root: dir, rel: rel)) != nil
                #expect(parser == target, "\(rel)")
            }
            #expect(!FactoryProfile.confinedPath("~x") && !FactoryProfile.confinedPath("$x"))
        }
    }

    /// F5a (N2): the router's wiring: with `sandboxHome` set, a free terminal's `factory ratchet` answers `.unavailable` and
    /// runs nothing (no baseline, no marker). No real `sandbox-exec`.
    @Test func routerRefusesAFreeTerminalWhenSandboxed() async throws {
        let home = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("ratchet-home-\(UUID().uuidString.prefix(8))")
        let proj = home.appendingPathComponent("code/proj")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = proj.appendingPathComponent("ran").path
        let work = #"{"factory": {"version": 1, "static": {"ratchets": [{"name": "lint", "measure": "touch \#(marker); echo a 1", "baseline": "base.txt"}]}}}"#
        try Data(work.utf8).write(to: proj.appendingPathComponent("collie-work.json"))
        try await withDaemon(configure: { $0.sandboxHome = home }) { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                              args: ["name": .string("F"), "preset": .string("shell"), "cwd": .string(proj.path), "sandbox": .string("free")]))
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let token = try await tokenOf(d, id)
            for a in ["check", "raise"] {
                let res = try await send(p, Request(id: "c", terminalId: id, token: token, command: "factory.ratchet.\(a)",
                                                    args: ["name": .string("lint"), "reason": .string("r")]))
                #expect(res.error?.code == .unavailable, "\(a): \(res)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(!FileManager.default.fileExists(atPath: proj.appendingPathComponent("base.txt").path))
    }

    /// F6a: the daemon never creates nor changes the baseline file: `update`/`raise` hand back the whole text and the
    /// resolved path, `check` hands back no text.
    @Test func daemonNeverWrites() throws {
        try project { dir in
            let base = dir.appendingPathComponent("scripts/ci/base.txt")
            try Data("# 2026-01-01: velho\nr a 2\n".utf8).write(to: base)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: base.path)
            let before = mtime(base.path)
            let up = try daemon(.update, dir, measured: "r a 1\n")
            #expect(up.passed && up.newBaseline == "# 2026-01-01: velho\nr a 1\n" && up.root == dir.path && up.rel == "scripts/ci/base.txt")
            let raised = try daemon(.raise, dir, measured: "r a 5\n", reason: "novo módulo")
            #expect(raised.newBaseline == "# 2026-01-01: velho\n# 2026-11-18: r a 2 -> 5: novo módulo\nr a 5\n" && raised.root == dir.path)
            #expect(try daemon(.check, dir, measured: "r a 1\n").newBaseline == nil)
            #expect(try daemon(.check, dir, measured: "r a 2\n").newBaseline == nil)
            #expect(try daemon(.update, dir, measured: "r a 2\n").newBaseline == nil)   // nothing to write
            #expect(try daemon(.update, dir, measured: "r a 3\n").newBaseline == nil)   // worse: refused
            #expect(file(dir, "scripts/ci/base.txt") == "# 2026-01-01: velho\nr a 2\n" && mtime(base.path) == before)
            // a first baseline: the daemon hands it over, the file is still absent
            let first = try daemon(.raise, dir, measured: "x 1\n", reason: "início", rel: "scripts/ci/new.txt")
            #expect(first.newBaseline == "# 2026-11-18: x 0 -> 1: início\nx 1\n" && first.rel == "scripts/ci/new.txt")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts/ci").path) == ["base.txt"])
        }
    }

    /// F6a: the CLI's writer: atomic (no temporary left), 0644 for a new file or the old mode, refuses a link, a folder or a
    /// FIFO as destination and leaves their target untouched.
    @Test func writerIsAtomicAndRefusesLinks() throws {
        try project { dir in
            let ci = dir.appendingPathComponent("scripts/ci")
            func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? -1 }
            let new = ci.appendingPathComponent("new.txt").path
            func w(_ t: String, _ n: String) throws { try BaselineWriter.write(t, root: dir.path, rel: "scripts/ci/\(n)") }
            try w("a 1\n", "new.txt")
            #expect(file(ci, "new.txt") == "a 1\n" && mode(new) == 0o644)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: new)
            try w("a 0\n", "new.txt")
            #expect(file(ci, "new.txt") == "a 0\n" && mode(new) == 0o640)
            let outside = dir.deletingLastPathComponent().appendingPathComponent("ratchet-w-\(UUID().uuidString.prefix(6)).txt")
            try Data("intocado\n".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: ci.appendingPathComponent("l.txt"), withDestinationURL: outside)
            try FileManager.default.createDirectory(at: ci.appendingPathComponent("pasta"), withIntermediateDirectories: false)
            #expect(mkfifo(ci.appendingPathComponent("fifo").path, 0o644) == 0)
            for n in ["l.txt", "pasta", "fifo"] {
                #expect(throws: BaselineWriter.Failure.self, "\(n)") { try w("a 1\n", n) }
            }
            #expect(throws: BaselineWriter.Failure.self) { try BaselineWriter.write("a 1\n", root: "relativo", rel: "base.txt") }
            #expect(throws: BaselineWriter.Failure.self) { try w("a 1\n", "nao/existe.txt") }
            #expect(throws: BaselineWriter.Failure.self) { try w(String(repeating: "a", count: BaselineWriter.maxBytes + 1), "new.txt") }   // nit 5
            #expect(file(ci, "new.txt") == "a 0\n")
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
            // the fd path: the read goes through the opened folder
            let fd = try FactoryRatchet.openDir(root: dir, rel: "scripts/ci/base.txt")
            defer { close(fd) }
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "")
            try Data("a 1\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try FactoryRatchet.read(dir: fd, "base.txt", rel: "scripts/ci/base.txt") == "a 1\n")
            // a link as the file itself: the read refuses it
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("scripts/ci/l.txt"), withDestinationURL: out.appendingPathComponent("x"))
            #expect(throws: ProtocolError.self) { try FactoryRatchet.read(dir: fd, "l.txt", rel: "l.txt") }
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("x").path))
            // A (round 3): the root itself as a link is refused too
            #expect(throws: ProtocolError.self) { try FactoryRatchet.openDir(root: dir.appendingPathComponent("dentro"), rel: "base.txt") }
        }
    }

    @Test func raiseLogKeepsItsLast100Lines() throws {   // nit: the log never grows past what `read` takes
        try project { dir in
            let old = (1...150).map { "# 2026-01-01: k \($0) -> \($0 + 1): r\($0)\n" }.joined() + "k 1\n"
            try Data(old.utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try apply(.raise, dir, measured: "k 2\n", reason: "mais um").wrote)
            let logs = (file(dir, "scripts/ci/base.txt") ?? "").split(separator: "\n").filter { $0.hasPrefix("#") }
            #expect(logs.count == 100 && logs.first == "# 2026-01-01: k 52 -> 53: r52" && logs.last?.hasSuffix("k 1 -> 2: mais um") == true)
            #expect(try apply(.update, dir, measured: "k 1\n").wrote)
            #expect((file(dir, "scripts/ci/base.txt") ?? "").split(separator: "\n").filter { $0.hasPrefix("#") } == logs)
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

    /// F5a (N1, round 2 blocker): the daemon writes unsandboxed, so a root at the home or above it, or a baseline where the
    /// strict profile denies writes, is refused and nothing is written; a common root inside the home still works.
    @Test func homeRootAndDeniedPlacesRefused() throws {
        try project { base in
            let home = base.appendingPathComponent("Users/eu")
            for d in [".ssh", "Library/LaunchAgents", ".config/git", "code/proj"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            let rels = [".zshenv", ".ssh/authorized_keys", "Library/LaunchAgents/x"]
            for root in [home, base.appendingPathComponent("Users"), base] {   // the home and its ancestors
                for rel in rels {
                    #expect(throws: ProtocolError.self, "\(root.path) \(rel)") { try apply(.raise, root, measured: "a 1\n", reason: "r", rel: rel, home: home) }
                }
            }
            // a root under a denied place: everything below it is denied too
            for (root, rel) in [(".ssh", "authorized_keys"), ("Library/LaunchAgents", "x.plist"), (".config/git", "config")] {
                #expect(throws: ProtocolError.self, "\(root)/\(rel)") { try apply(.raise, home.appendingPathComponent(root), measured: "a 1\n", reason: "r", rel: rel, home: home) }
            }
            for rel in rels { #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(rel).path), "\(rel)") }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/git/config").path))
            // a common project root inside the home keeps working, even with a dotfile name
            let proj = home.appendingPathComponent("code/proj")
            #expect(try apply(.raise, proj, measured: "a 1\n", reason: "r", rel: ".zshenv", home: home).wrote)
            #expect(file(proj, ".zshenv") == "# 2026-11-18: a 0 -> 1: r\na 1\n")
        }
    }

    /// F5a (N6): the rewritten baseline keeps the old file's mode; a first one is 0644.
    @Test func rewriteKeepsTheMode() throws {
        try project { dir in
            func mode(_ rel: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(rel).path)[.posixPermissions] as? Int) ?? -1 }
            #expect(try apply(.raise, dir, measured: "a 1\n", reason: "r", rel: "scripts/ci/new.txt").wrote)
            #expect(try mode("scripts/ci/new.txt") == 0o644)
            try Data("a 2\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: dir.appendingPathComponent("scripts/ci/base.txt").path)
            #expect(try apply(.update, dir, measured: "a 1\n").wrote)
            #expect(try mode("scripts/ci/base.txt") == 0o640)
        }
    }

    /// F5a (N6): the parser and `target` refuse the same paths (one function): `~x` and `$x` too.
    @Test func parserAndTargetAgree() throws {
        try project { dir in
            for rel in ["~x", "$x", "~/x", "$HOME/x", "/x", "a/../b", "scripts/ci/base.txt", "a..b/c.txt"] {
                let parser = FactoryProfile.confinedPath(rel)
                let target = (try? FactoryRatchet.target(root: dir, rel: rel)) != nil
                #expect(parser == target, "\(rel)")
            }
            #expect(!FactoryProfile.confinedPath("~x") && !FactoryProfile.confinedPath("$x"))
        }
    }

    /// F5a (N2): the router's wiring: with `sandboxHome` set, a free terminal's `factory ratchet` answers `.unavailable` and
    /// runs nothing (no baseline, no marker). No real `sandbox-exec`.
    @Test func routerRefusesAFreeTerminalWhenSandboxed() async throws {
        let home = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("ratchet-home-\(UUID().uuidString.prefix(8))")
        let proj = home.appendingPathComponent("code/proj")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = proj.appendingPathComponent("ran").path
        let work = #"{"factory": {"version": 1, "static": {"ratchets": [{"name": "lint", "measure": "touch \#(marker); echo a 1", "baseline": "base.txt"}]}}}"#
        try Data(work.utf8).write(to: proj.appendingPathComponent("collie-work.json"))
        try await withDaemon(configure: { $0.sandboxHome = home }) { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                              args: ["name": .string("F"), "preset": .string("shell"), "cwd": .string(proj.path), "sandbox": .string("free")]))
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let token = try await tokenOf(d, id)
            for a in ["check", "raise"] {
                let res = try await send(p, Request(id: "c", terminalId: id, token: token, command: "factory.ratchet.\(a)",
                                                    args: ["name": .string("lint"), "reason": .string("r")]))
                #expect(res.error?.code == .unavailable, "\(a): \(res)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(!FileManager.default.fileExists(atPath: proj.appendingPathComponent("base.txt").path))
    }

    /// F6a: the daemon never creates nor changes the baseline file: `update`/`raise` hand back the whole text and the
    /// resolved path, `check` hands back no text.
    @Test func daemonNeverWrites() throws {
        try project { dir in
            let base = dir.appendingPathComponent("scripts/ci/base.txt")
            try Data("# 2026-01-01: velho\nr a 2\n".utf8).write(to: base)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: base.path)
            let before = mtime(base.path)
            let up = try daemon(.update, dir, measured: "r a 1\n")
            #expect(up.passed && up.newBaseline == "# 2026-01-01: velho\nr a 1\n" && up.root == dir.path && up.rel == "scripts/ci/base.txt")
            let raised = try daemon(.raise, dir, measured: "r a 5\n", reason: "novo módulo")
            #expect(raised.newBaseline == "# 2026-01-01: velho\n# 2026-11-18: r a 2 -> 5: novo módulo\nr a 5\n" && raised.root == dir.path)
            #expect(try daemon(.check, dir, measured: "r a 1\n").newBaseline == nil)
            #expect(try daemon(.check, dir, measured: "r a 2\n").newBaseline == nil)
            #expect(try daemon(.update, dir, measured: "r a 2\n").newBaseline == nil)   // nothing to write
            #expect(try daemon(.update, dir, measured: "r a 3\n").newBaseline == nil)   // worse: refused
            #expect(file(dir, "scripts/ci/base.txt") == "# 2026-01-01: velho\nr a 2\n" && mtime(base.path) == before)
            // a first baseline: the daemon hands it over, the file is still absent
            let first = try daemon(.raise, dir, measured: "x 1\n", reason: "início", rel: "scripts/ci/new.txt")
            #expect(first.newBaseline == "# 2026-11-18: x 0 -> 1: início\nx 1\n" && first.rel == "scripts/ci/new.txt")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scripts/ci").path) == ["base.txt"])
        }
    }

    /// F6a: the CLI's writer: atomic (no temporary left), 0644 for a new file or the old mode, refuses a link, a folder or a
    /// FIFO as destination and leaves their target untouched.
    @Test func writerIsAtomicAndRefusesLinks() throws {
        try project { dir in
            let ci = dir.appendingPathComponent("scripts/ci")
            func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? -1 }
            let new = ci.appendingPathComponent("new.txt").path
            try BaselineWriter.write("a 1\n", to: new)
            #expect(file(ci, "new.txt") == "a 1\n" && mode(new) == 0o644)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: new)
            try BaselineWriter.write("a 0\n", to: new)
            #expect(file(ci, "new.txt") == "a 0\n" && mode(new) == 0o640)
            let outside = dir.deletingLastPathComponent().appendingPathComponent("ratchet-w-\(UUID().uuidString.prefix(6)).txt")
            try Data("intocado\n".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: ci.appendingPathComponent("l.txt"), withDestinationURL: outside)
            try FileManager.default.createDirectory(at: ci.appendingPathComponent("pasta"), withIntermediateDirectories: false)
            #expect(mkfifo(ci.appendingPathComponent("fifo").path, 0o644) == 0)
            for n in ["l.txt", "pasta", "fifo"] {
                #expect(throws: BaselineWriter.Failure.self, "\(n)") { try BaselineWriter.write("a 1\n", to: ci.appendingPathComponent(n).path) }
            }
            #expect(throws: BaselineWriter.Failure.self) { try BaselineWriter.write("a 1\n", to: "relativo.txt") }
            #expect(throws: BaselineWriter.Failure.self) { try BaselineWriter.write("a 1\n", to: ci.appendingPathComponent("nao/existe.txt").path) }
            #expect(try String(contentsOf: outside, encoding: .utf8) == "intocado\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: ci.path).sorted() == ["fifo", "l.txt", "new.txt", "pasta"])
        }
    }

    /// B (round 3): `mayWrite` and `place` compare without case: `~/.config/FISH/...` is `~/.config/fish/...` on macOS.
    /// F7a: the writer walks from the root by fd: a link as a middle folder (or as the root) is an error and its target is
    /// left untouched; `rel` is confined again in the writer.
    @Test func writerRefusesMiddleLinkAndBadRel() throws {
        try project { dir in
            let out = dir.deletingLastPathComponent().appendingPathComponent("ratchet-m-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: out.appendingPathComponent("ci"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            try Data("intocado\n".utf8).write(to: out.appendingPathComponent("ci/base.txt"))
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("metrics"), withDestinationURL: out)
            #expect(throws: BaselineWriter.Failure.self) { try BaselineWriter.write("a 1\n", root: dir.path, rel: "metrics/ci/base.txt") }
            #expect(throws: BaselineWriter.Failure.self) { try BaselineWriter.write("a 1\n", root: dir.appendingPathComponent("metrics").path, rel: "ci/base.txt") }
            #expect(try String(contentsOf: out.appendingPathComponent("ci/base.txt"), encoding: .utf8) == "intocado\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("ci").path) == ["base.txt"])
            for rel in ["../x.txt", "scripts/../../x.txt", "/etc/x.txt", ".git/x", "a/.collie/x", "collie-work.json", "~/x"] {
                #expect(throws: BaselineWriter.Failure.self, "\(rel)") { try BaselineWriter.write("a 1\n", root: dir.path, rel: rel) }
            }
        }
    }

    /// nit 4: a `#` line of the old baseline with a control character is dropped from the new one.
    @Test func headerControlLineDropped() throws {
        try project { dir in
            try Data("# ok\n# mau\u{1b}[2J\nr a 2\n".utf8).write(to: dir.appendingPathComponent("scripts/ci/base.txt"))
            #expect(try daemon(.update, dir, measured: "r a 1\n").newBaseline == "# ok\nr a 1\n")
        }
    }

    /// F7a: the CLI's half (`RatchetCLI.handleRatchet`): writes only `update`/`raise` with a non-null `newBaseline`, after
    /// confining `rel` again and checking `root` is its own cwd's project root; a writer error exits 1 printing nothing.
    @Test func cliHandlesTheDaemonAnswer() throws {
        try project { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: false)
            let cwd = dir.appendingPathComponent("scripts").path   // below the root: the root is found by `.git`
            var errs: [String] = []
            func run(_ cmd: String, _ o: [String: JSONValue], args: [String: JSONValue] = [:],
                     write: ((String, String, String) throws -> Void)? = nil) -> (JSONValue, Int32) {
                let r = JSONValue.object(o)
                if let write { return RatchetCLI.handleRatchet(r, command: "factory.ratchet.\(cmd)", args: args, cwd: cwd, err: { errs.append($0) }, write: write) }
                return RatchetCLI.handleRatchet(r, command: "factory.ratchet.\(cmd)", args: args, cwd: cwd, err: { errs.append($0) })
            }
            func answer(_ rel: String = "scripts/ci/base.txt", root: String? = nil, text: JSONValue = .string("a 1\n"), passed: Bool = true) -> [String: JSONValue] {
                ["output": .string("ok\n"), "passed": .bool(passed), "wrote": .bool(false), "root": .string(root ?? dir.path), "rel": .string(rel), "newBaseline": text]
            }
            // newBaseline not null: written, wrote true
            let (o, code) = run("update", answer())
            #expect(code == 0 && file(dir, "scripts/ci/base.txt") == "a 1\n")
            if case .object(let m) = o { #expect(m["wrote"] == .bool(true)) } else { Issue.record("no object") }
            // check never writes, even if the daemon handed text
            let (c, cc) = run("check", answer(text: .string("a 9\n"), passed: false))
            #expect(cc == 1 && file(dir, "scripts/ci/base.txt") == "a 1\n")
            if case .object(let m) = c { #expect(m["wrote"] == .bool(false)) }
            // null newBaseline: nothing written, wrote stays false
            let (n, _) = run("update", answer(text: .null))
            if case .object(let m) = n { #expect(m["wrote"] == .bool(false)) }
            // writer error: exit 1, nothing to print, a message on err
            errs = []
            let (e, ec) = run("raise", answer(), write: { _, _, _ in throw BaselineWriter.Failure(message: "disco cheio") })
            #expect(e == .null && ec == 1 && errs.count == 1 && errs[0].contains("disco cheio"))
            // rel refused by the CLI even when the daemon hands it over
            for rel in ["../fora.txt", "/etc/passwd", ".git/config", ".collie/x", "a/x.git/y"] {
                errs = []
                var called = false
                let (r, rc) = run("raise", answer(rel), write: { _, _, _ in called = true })
                #expect(r == .null && rc == 1 && !called && errs.count == 1, "\(rel)")
            }
            // a root other than this cwd's project root
            for root in [dir.appendingPathComponent("scripts").path, NSHomeDirectory(), "/"] {
                var called = false
                let (r, rc) = run("update", answer(root: root), write: { _, _, _ in called = true })
                #expect(r == .null && rc == 1 && !called, "\(root)")
            }
            // --terminal of another terminal: update/raise refused, check still fine
            for cmd in ["update", "raise"] {
                var called = false
                let (r, rc) = run(cmd, answer(), args: ["terminal": .string("A")], write: { _, _, _ in called = true })
                #expect(r == .null && rc == 1 && !called)
                #expect(RatchetCLI.refusal("factory.ratchet.\(cmd)", ["terminal": .string("A")]) != nil)
            }
            #expect(RatchetCLI.refusal("factory.ratchet.check", ["terminal": .string("A")]) == nil)
            #expect(RatchetCLI.refusal("factory.ratchet.update", [:]) == nil)
            #expect(run("check", answer(text: .null), args: ["terminal": .string("A")]).1 == 0)
        }
    }

    @Test func mayWriteIgnoresCase() throws {
        try project { base in
            let home = base.appendingPathComponent("Users/eu"), collie = home.appendingPathComponent("Library/Application Support/Collie")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/fish/conf.d"), withIntermediateDirectories: true)
            let root = home.appendingPathComponent(".config")
            for rel in ["fish/conf.d/x.fish", "FISH/conf.d/x.fish", "Fish/CONF.D/x.fish"] {
                #expect(!SandboxGrantStore.mayWrite(root.appendingPathComponent(rel).path, root: root.path, grants: [], home: home, collie: collie, app: nil, closed: []), "\(rel)")
                #expect(throws: ProtocolError.self, "\(rel)") { try daemon(.raise, root, measured: "a 1\n", reason: "r", rel: rel, home: home) }
            }
            #expect(!SandboxGrantStore.mayWrite(home.appendingPathComponent(".ZSHENV").path, root: home.path, grants: [], home: home, collie: collie, app: nil, closed: []))
            #expect(SandboxGrantStore.mayWrite(root.appendingPathComponent("outro/x").path, root: root.path, grants: [], home: home, collie: collie, app: nil, closed: []))
            #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".config/fish/conf.d").path).isEmpty)
        }
    }

    @Test func commandIsRegistered() throws {
        for a in ["check", "update", "raise"] { #expect(Commands.spec("factory.ratchet.\(a)") != nil) }
        let r = try ArgvParser.parse(["factory", "ratchet", "raise", "lint", "--reason", "porque sim"])
        #expect(r.command == "factory.ratchet.raise" && r.args["name"] == .string("lint") && r.args["reason"] == .string("porque sim"))
        #expect(try ArgvParser.parse(["factory", "ratchet", "check", "lint"]).command == "factory.ratchet.check")
    }
}
