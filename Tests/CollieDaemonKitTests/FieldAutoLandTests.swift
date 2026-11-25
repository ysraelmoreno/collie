import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

private extension CommandRouter {
    func autoTestsAdd(_ p: Paddock) { ws.paddocks.append(p) }
    func autoTestsInsert(_ t: TerminalRecord) { ws.terminals.append(t) }
    func autoTestsRecord(_ name: String) -> TerminalRecord? { ws.terminals.first { $0.name == name } }
    func autoTestsSetField(_ id: UUID, _ f: FieldRef?) {
        if let i = ws.terminals.firstIndex(where: { $0.id == id }) { ws.terminals[i].field = f }
    }
    func autoTestsNotices() -> [String] { fieldNoticeLog }
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

/// A daemon that sandboxes no terminal over a fake home, the paddock `p` on record, a Shepherd S (a record the router
/// serves directly) and its agent bob, summoned as always, whose field is cut by the daemon's git.
private final class Rig {
    let f: FakeHome, paths: Paths, paddock: Paddock
    let d: Daemon
    var s: TerminalRecord!, bob: TerminalRecord!

    init() async throws {
        f = try FakeHome(git: true, socket: false)
        paths = Paths(root: f.collie)
        d = try Daemon(config: testConfig(paths))
        paddock = Paddock(id: UUID(), name: "p", repoRoot: f.repo.path, path: f.paddock.path, branch: "collie/p", baseBranch: "main")
        try await d.start()
        await d.router.autoTestsAdd(paddock)
        let path = SignedAppCheck.realPath(f.paddock)
        s = TerminalRecord(id: UUID(), name: "S", preset: .shell, command: nil, cwd: path, isShepherd: true, paddockId: paddock.id, projectRoot: path)
        await d.router.autoTestsInsert(s)
        _ = try await d.router.shepherd(Request(id: "m", terminalId: s.id.uuidString, command: "summon",
                                                args: ["name": .string("bob"), "preset": .string("custom"), "command": .string("/bin/cat")]), from: s.id)
        bob = try #require(await d.router.autoTestsRecord("bob"))
        let base = try await head(f.paddock)
        let lane = try await LaneWorktree.createField(repoRoot: f.repo, base: base, name: "bob", owner: bob.id, host: await d.router.fieldGit(paddock))
        await d.router.autoTestsSetField(bob.id, FieldRef(name: "bob", branch: lane.branch, base: base, path: SignedAppCheck.realPath(lane.path)))
    }
    func stop() async { await d.stop() }

    var dir: URL { f.repo.appendingPathComponent(".collie/paddocks/field-bob") }
    func field() async -> FieldRef? { await d.router.autoTestsRecord("bob")?.field }
    func notices() async -> [String] { await d.router.autoTestsNotices() }
    func head(_ dir: URL) async throws -> String {
        try await GitRunner.run(["rev-parse", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ file: String, _ text: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try FakeHome.git(["add", "."], in: dir)
        try FakeHome.git(["commit", "-qm", file], in: dir)
    }
    func land() async throws -> [String: JSONValue] {
        let r = try await d.router.shepherd(Request(id: "l", terminalId: s.id.uuidString, command: "field.land", args: ["name": .string("bob")]), from: s.id)
        guard case .object(let o) = r else { throw ProtocolError(code: .internal, message: "\(r)") }
        return o
    }
}

private func withRig(_ body: (Rig) async throws -> Void) async throws {
    let r = try await Rig()
    do { try await body(r) } catch { await r.stop(); throw error }
    await r.stop()
}

private let passed = AskCheckReport(status: .passed, tries: 1, tail: "ok")

/// F5: a passing `ask --check` lands the field by itself; a turn's end makes it ready; the field follows the paddock
/// after a land (spec "Volta", answers 4, 5, 9).
@Suite(.serialized, .timeLimit(.minutes(5))) struct FieldAutoLandTests {
    @Test func passedCheckQueuesLand() async throws {
        try await withRig { r in
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            let c = await r.d.router.fieldAfterCheck(r.bob.id, passed)
            #expect(c?.field == FieldNote(land: .queued), "\(String(describing: c))")
            // the ask is over; the land runs after it, then the field is rebased on the paddock's new HEAD
            #expect(await waitFor(30) { exists(r.f.paddock.appendingPathComponent("bob.txt")) })
            #expect(await waitFor(30) { await r.field()?.state == .working })
            let head = try await r.head(r.f.paddock)
            #expect(await r.field()?.base == head)
        }
    }

    /// The committed tree is judged: something uncommitted (untracked and not ignored too) fails the try with the line.
    @Test func dirtyTreeFailsTry() async throws {
        // the ask's own loop: dirty once, clean the second time (`fieldDirtyReadsTheTree`: what dirty is)
        let asks = AskCoordinator(idleQuietSeconds: 15)
        func term(_ name: String, _ preset: Preset) throws -> (UUID, ScrollbackBuffer, TerminalRecord, PTYProcess) {
            let rec = TerminalRecord(id: UUID(), name: name, preset: preset, command: "cat", cwd: "/tmp", isShepherd: false, paddockId: nil, projectRoot: nil)
            let sb = ScrollbackBuffer(spillURL: nil)
            let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf ready; exec cat >/dev/null"], environment: [:], cwd: "/tmp"), scrollback: sb)
            return (rec.id, sb, rec, p)
        }
        let a = try term("A", .claude), b = try term("B", .cursor)
        await asks.attach(a.2, process: a.3, scrollback: a.1); await asks.attach(b.2, process: b.3, scrollback: b.1)
        let dirtyOnce = Counter()
        var g = AskGate(command: "make test", spec: nil, tries: 3, checkTimeout: .seconds(5), dir: URL(fileURLWithPath: "/tmp"))
        g.dirty = { dirtyOnce.next() == 1 }
        let green = ProcessResult(status: 0, stdout: "ok", stderr: "", truncated: false)
        let t = Task { try await asks.askGated(from: a.0, to: b.0, prompt: "faça", raw: false, timeout: .seconds(20), gate: g, run: { _, _, _ in green }) }
        await answer(asks, b.0, "pronto 1")
        #expect(await typed(b.1, "commite antes de encerrar"), "the try was not failed with the line")
        await answer(asks, b.0, "pronto 2")
        let res = try await t.value
        #expect(res.check?.status == .passed && res.check?.tries == 2, "\(String(describing: res.check))")
    }

    @Test func fieldDirtyReadsTheTree() async throws {
        try await withRig { r in
            #expect(!(await CommandRouter.fieldDirty(r.dir)), "clean")
            try "*.log\n".write(to: r.dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try FakeHome.git(["add", ".gitignore"], in: r.dir); try FakeHome.git(["commit", "-qm", "ignore"], in: r.dir)
            try "x\n".write(to: r.dir.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
            #expect(!(await CommandRouter.fieldDirty(r.dir)), "an ignored file is not uncommitted work")
            try "x\n".write(to: r.dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            #expect(await CommandRouter.fieldDirty(r.dir), "untracked, not ignored")
            try FileManager.default.removeItem(at: r.dir.appendingPathComponent("new.txt"))
            try "changed\n".write(to: r.dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            #expect(await CommandRouter.fieldDirty(r.dir), "tracked, modified")
        }
    }

    @Test func failedCheckNoLand() async throws {
        try await withRig { r in
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            let before = try await r.head(r.f.paddock)
            let failed = AskCheckReport(status: .failed, tries: 3, tail: "red")
            #expect(await r.d.router.fieldAfterCheck(r.bob.id, failed) == failed)
            #expect(await r.d.router.fieldAfterCheck(r.bob.id, nil) == nil)
            let now = try await r.head(r.f.paddock), st = await r.field()?.state
            #expect(now == before && st == .working)
        }
    }

    @Test func readyNoticeOnce() async throws {
        try await withRig { r in
            await r.d.router.fieldTurnEnded(r.bob.id)
            #expect(await r.field()?.state == .working, "no commit: not ready")
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            // an ask --check in flight judges it instead
            await r.d.router.fieldCheckBegin(r.bob.id)
            await r.d.router.fieldTurnEnded(r.bob.id)
            #expect(await r.field()?.state == .working)
            await r.d.router.fieldCheckEnd(r.bob.id)
            await r.d.router.fieldTurnEnded(r.bob.id)
            await r.d.router.fieldTurnEnded(r.bob.id)
            #expect(await r.field()?.state == .ready)
            let ready = await r.notices().filter { $0 == "[collie] field bob pronto para integrar: collie field land bob" }
            #expect(ready.count == 1)
        }
    }

    @Test func rebaseAfterLand() async throws {
        try await withRig { r in
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            try r.commit("paddock.txt", "from the paddock\n", in: r.f.paddock)
            let o = try await r.land()
            #expect(o["outcome"] == .string("landed"), "\(o)")
            let head = try await r.head(r.f.paddock), fr = await r.field(), fieldHead = try await r.head(r.dir)
            #expect(fr?.state == .working && fr?.base == head)
            #expect(fieldHead == head, "the field starts again from what went in")
            #expect(exists(r.dir.appendingPathComponent("paddock.txt")))
        }
    }

    @Test func rebaseWaitsWhenBusy() async throws {
        try await withRig { r in
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            try "wip\n".write(to: r.dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)   // the agent mid-edit
            #expect(try await r.land()["outcome"] == .string("landed"))
            #expect(await r.field()?.state == .behind)
            // its next turn's end, the tree clean: the rebase it owed
            try FakeHome.git(["checkout", "--", "README"], in: r.dir)
            await r.d.router.fieldTurnEnded(r.bob.id)
            let head = try await r.head(r.f.paddock), fr = await r.field()
            #expect(fr?.state == .working && fr?.base == head)
        }
    }

    @Test func landNoticeReachesShepherd() async throws {
        try await withRig { r in
            // a conflict: the notice names why and the patch
            try r.commit("f.txt", "from bob\n", in: r.dir)
            try r.commit("f.txt", "from the paddock\n", in: r.f.paddock)
            _ = await r.d.router.fieldAfterCheck(r.bob.id, passed)
            #expect(await waitFor(30) { await r.notices().contains { $0.hasPrefix("[collie] field bob não integrou: ") } })
            let line = try #require(await r.notices().first { $0.hasPrefix("[collie] field bob não integrou: ") })
            #expect(line.contains("patch: ") && line.contains("bob-1.patch"), "\(line)")
            #expect(await r.field()?.state == .conflict)
            // fixed in the field: landed, with its sha
            try FakeHome.git(["merge", "-q", "-X", "theirs", "collie/p", "-m", "sync"], in: r.dir)
            await r.d.router.autoTestsSetField(r.bob.id, await r.field().map { var f = $0; f.state = .working; return f })
            _ = await r.d.router.fieldAfterCheck(r.bob.id, passed)
            #expect(await waitFor(30) { await r.notices().contains { $0.hasPrefix("[collie] field bob integrado em ") } })
            let head = try await r.head(r.f.paddock)
            #expect(await r.notices().contains("[collie] field bob integrado em \(head.prefix(8))"))
        }
    }

    /// (a) no diff, no patch file.
    @Test func emptyPatchNotWritten() async throws {
        try await withRig { r in
            let lane = Lane(repoRoot: r.f.repo, path: r.dir, branch: "collie/field/bob", base: try await r.head(r.f.paddock))
            let into = r.f.collie.appendingPathComponent("fields")
            let none = await FieldLand.patch(lane, name: "bob", dir: r.f.paddock, host: await r.d.router.fieldGit(r.paddock), into: into)
            #expect(none == nil && !exists(into.appendingPathComponent("bob-1.patch")))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func next() -> Int { l.withLock { n += 1; return n } }
}

private func answer(_ asks: AskCoordinator, _ target: UUID, _ message: String) async {
    for _ in 0..<400 {
        if (try? await asks.reply(terminal: target, message: message)) != nil { return }
        try? await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("no ask in flight to answer: \(message)")
}

private func typed(_ sb: ScrollbackBuffer, _ needle: String) async -> Bool {
    for _ in 0..<400 {
        if String(decoding: sb.snapshot().data, as: UTF8.self).contains(needle) { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

private extension CommandRouter {
    func autoTestsSetProbe(_ p: (@Sendable (String) async -> Void)?) { fieldProbe = p }
}

/// Review of F5 (fix 3, 4, 5): the land takes what the check judged; the rebase moves only the field's branch and never
/// discards a change.
extension FieldAutoLandTests {
    /// Fix 3: a commit after the check passed is not the judged one: no land.
    @Test func laterCommitIsNotLanded() async throws {
        try await withRig { r in
            try r.commit("a.txt", "judged\n", in: r.dir)
            #expect(!(await r.d.router.fieldJudge(r.bob.id, r.dir)), "clean: judged")
            try r.commit("b.txt", "never judged\n", in: r.dir)
            let c = await r.d.router.fieldAfterCheck(r.bob.id, passed)
            #expect(c?.field?.land == .skipped && c?.field?.reason?.contains("ponta") == true, "\(String(describing: c))")
            try? await Task.sleep(for: .milliseconds(300))
            #expect(!exists(r.f.paddock.appendingPathComponent("b.txt")) && !exists(r.f.paddock.appendingPathComponent("a.txt")))
        }
    }

    /// Fix 4: a field whose HEAD the agent pointed at another branch is never rebased: that branch stays put.
    @Test func rebaseRefusesForeignHead() async throws {
        try await withRig { r in
            try r.commit("paddock.txt", "from the paddock\n", in: r.f.paddock)
            let main = try await r.head(r.f.repo)
            try FakeHome.git(["symbolic-ref", "HEAD", "refs/heads/main"], in: r.dir)   // the agent writes its HEAD
            await r.d.router.rebaseField(r.bob.id, checkBusy: false)
            #expect(try await r.head(r.f.repo) == main, "main moved")
            #expect(await r.field()?.state == .behind)
        }
    }

    /// Fix 5: an edit made while the rebase ran (after its first look) is kept; the field stays `behind`.
    @Test func editDuringRebaseIsKept() async throws {
        try await withRig { r in
            try r.commit("bob.txt", "from bob\n", in: r.dir)
            try r.commit("paddock.txt", "from the paddock\n", in: r.f.paddock)
            let tip = try await r.head(r.dir), dir = r.dir
            await r.d.router.autoTestsSetProbe { stage in
                if stage == "rebase.reset" { try? "the agent's edit\n".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8) }
            }
            await r.d.router.rebaseField(r.bob.id, checkBusy: false)
            #expect(try String(contentsOf: r.dir.appendingPathComponent("README"), encoding: .utf8) == "the agent's edit\n")
            #expect(try await r.head(r.dir) == tip, "the branch did not move")
            #expect(await r.field()?.state == .behind)
            // the next turn's end, the edit committed: rebased, the commit kept
            try FakeHome.git(["commit", "-qam", "edit"], in: r.dir)
            await r.d.router.autoTestsSetProbe(nil)
            await r.d.router.rebaseField(r.bob.id, checkBusy: false)
            #expect(await r.field()?.state == .working)
            #expect(exists(r.dir.appendingPathComponent("paddock.txt")) && exists(r.dir.appendingPathComponent("bob.txt")))
            #expect(try String(contentsOf: r.dir.appendingPathComponent("README"), encoding: .utf8) == "the agent's edit\n")
        }
    }
}
