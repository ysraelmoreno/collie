import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Denial lines in place of `log stream` (R5: tests never run the real one): each supervised run gets a fresh stream.
final class LineFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: AsyncStream<String>.Continuation?
    private var runs = 0
    var starts: Int { lock.withLock { runs } }
    var source: @Sendable () -> AsyncStream<String> {
        { [self] in
            let (s, c) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
            lock.withLock { cont = c; runs += 1 }
            return s
        }
    }
    func send(_ l: String) { lock.withLock { cont }?.yield(l) }
    func end() { lock.withLock { cont }?.finish() }
}

/// One `log stream --style ndjson` line as Task 1 saw them.
func denialLine(_ tag: UUID, _ op: String, _ path: String, proc: String = "cat(4242)", pid: Int = 0) -> String {
    let msg = "Sandbox: \(proc) deny(1) \(op) \(path)\n\(SandboxProfile.tagPrefix)\(tag.uuidString)"
    let data = try! JSONSerialization.data(withJSONObject: ["eventMessage": msg, "processID": pid, "senderImagePath": "/System/Library/Extensions/Sandbox.kext"])
    return String(decoding: data, as: UTF8.self)
}

private struct Term { var id: UUID; var token: String }

/// A daemon over a fake home (R2) with sandboxed terminals and an injected denial feed.
private final class Rig {
    let f: FakeHome
    let feed = LineFeed()
    let paths: Paths
    let ws = UUID()
    var d: Daemon!
    var proj: URL { f.home.appendingPathComponent("code/proj") }
    var docs: URL { f.home.appendingPathComponent("Documents") }

    init(shell: String? = nil) throws {
        f = try FakeHome(git: false, socket: false)
        paths = Paths(root: f.collie)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        d = try Daemon(config: config(shell: shell))
    }
    func config(shell: String? = nil) -> DaemonConfig {
        var c = testConfig(paths, ws)
        c.sandboxHome = f.home
        c.denialSource = feed.source
        c.denialBackoff = .milliseconds(20)
        if let shell { c.shell = shell }
        return c
    }
    func admin(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(paths, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
    }
    func call(_ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "m", terminalId: t.id.uuidString, token: t.token, command: cmd, args: args, cwd: proj.path),
                                        to: paths.socket, timeoutSeconds: 60)
    }
    func spawn(_ name: String, preset: String = "shell", shepherd: Bool = false, token: Bool = true) async throws -> Term {
        let r = try await admin("admin.spawn", ["name": .string(name), "preset": .string(preset), "cwd": .string(proj.path), "shepherd": .bool(shepherd)])
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"], let u = UUID(uuidString: id) else {
            throw ProtocolError(code: .internal, message: "\(r)")
        }
        return Term(id: u, token: token ? try await tokenOf(d, id) : "")
    }
    func profile(_ id: UUID) -> String { (try? String(contentsOf: SandboxLaunch.profileFile(id, root: paths.root), encoding: .utf8)) ?? "" }
    func grant(_ t: UUID, _ path: URL, access: String = "read", scope: String = "terminal", folder: Bool = false) async throws -> Response {
        try await admin("access.grant", ["terminal": .string(t.uuidString), "path": .string(path.path), "access": .string(access),
                                         "scope": .string(scope), "folder": .bool(folder)])
    }
    func list() async throws -> (grants: [SandboxGrant], cards: [SandboxDenial], detection: Bool?, dropped: Int) {
        let r = try await admin("access.list")
        guard case .object(let o)? = r.result else { throw ProtocolError(code: .internal, message: "\(r)") }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        func v<T: Decodable>(_ k: String) throws -> T { try dec.decode(T.self, from: JSONEncoder().encode(o[k] ?? .array([]))) }
        var det: Bool? = nil
        if case .bool(let b)? = o["detection"] { det = b }
        var dropped = 0
        if case .number(let n)? = o["dropped"] { dropped = Int(n) }
        return (try v("grants"), try v("cards"), det, dropped)
    }
    func run(_ body: (Rig) async throws -> Void) async throws {
        try await d.start()
        do { try await body(self) } catch { await d.stop(); throw error }
        await d.stop()
    }
}

@Suite struct SandboxWatcherTests {
    @Test func parsesTaggedDenial() {
        let id = UUID()
        #expect(SandboxWatcher.parse(denialLine(id, "file-read-data", "/Users/u/Doc é/a b.txt"))
                == .init(terminal: id, op: "read", path: "/Users/u/Doc é/a b.txt", count: 1))
        #expect(SandboxWatcher.parse(denialLine(id, "file-write-create", "/x/y"))?.op == "write")
        #expect(SandboxWatcher.parse(denialLine(id, "file-write-unlink", "/x/y"))?.op == "delete")
        #expect(SandboxWatcher.parse(denialLine(id, "process-exec*", "/bin/launchctl"))?.op == "exec")
        #expect(SandboxWatcher.parse(denialLine(id, "signal", "pgrp [sleep(1)] signum:19")) == nil)   // no card
        #expect(SandboxWatcher.parse(denialLine(id, "file-read-data", "/p", proc: "cat(1) 499 duplicate reports for cat(1)"))?.count == 499)
        #expect(SandboxWatcher.parse(#"{"eventMessage":"Sandbox: cat(1) deny(1) file-read-data /p"}"#) == nil)   // untagged
        #expect(SandboxWatcher.parse("Filtering the log data using \"sender == ...\"") == nil)
        // R28: only the kernel's reports (a userland image named Sandbox can log the same text)
        #expect(SandboxWatcher.parse(denialLine(id, "file-read-data", "/p", pid: 4242)) == nil)
    }

    /// R5: only the final line is the tag; a path carrying `\ncollie-term:<other>` stays a path of the real terminal.
    @Test func tagIsFinalLineOnly() {
        let victim = UUID(), agent = UUID()
        let l = denialLine(agent, "file-read-data", "/x\n\(SandboxProfile.tagPrefix)\(victim.uuidString)\n/y")
        let p = SandboxWatcher.parse(l)
        #expect(p?.terminal == agent && p?.path == "/x\n\(SandboxProfile.tagPrefix)\(victim.uuidString)\n/y")
    }

    /// The `log stream` child is restarted when it ends (backoff), and each end reports detection unavailable.
    @Test func superviseRestartsWithBackoff() async {
        final class Rec: @unchecked Sendable { let l = NSLock(); var s: [Bool] = []; var runs = 0 }
        let rec = Rec()
        let task = Task {
            await SandboxWatcher.supervise(source: {
                rec.l.withLock { rec.runs += 1 }
                return AsyncStream { $0.finish() }   // dies at once, like a `log` that can't start
            }, base: .milliseconds(5), max: .milliseconds(20), state: { ok in rec.l.withLock { rec.s.append(ok) } }, line: { _ in })
        }
        #expect(await waitFor(20) { rec.l.withLock { rec.runs >= 4 } })
        task.cancel(); await task.value
        let s = rec.l.withLock { rec.s }
        #expect(s.starts(with: [true, false, true, false]))
    }

    @Test func cardsDedupedBoundedRateLimited() {
        var c = SandboxCards()
        let t = UUID(), now = Date()
        var sent = 0
        for i in 0..<10_000 { if c.add(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/f\(i)"), now: now) != nil { sent += 1 } }
        #expect(sent == 1 && c.cards.count == 1 && c.all.first?.count == 10_000)
        #expect(c.add(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/g"), now: now + 3) != nil)   // its count, later
        for i in 0..<10_000 { _ = c.add(SandboxDenial(terminal: t, op: "write", path: "/h/d\(i)/f"), now: now) }
        #expect(c.cards.count == SandboxCards.perTerminal && c.dropped == 10_000 - (SandboxCards.perTerminal - 1))
        // R29: a request joins the folder's card without replacing its path, under the same rate limit
        let req = c.add(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/other", requested: true, reason: "r"), now: now + 3.5)
        #expect(req == nil && c.all.first { $0.op == "read" }?.path == "/h/Documents/f0" && c.all.first { $0.op == "read" }?.requested == true)
        let k = SandboxCards.key(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/x"))
        c.deny(k)
        #expect(c.add(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/y"), now: now + 10) == nil)   // Negar: quiet
        c.forget(terminal: t)
        #expect(c.cards.isEmpty && c.add(SandboxDenial(terminal: t, op: "read", path: "/h/Documents/y")) != nil)
    }

    /// R23 + too wide: what no click opens; global agent config is grantable.
    @Test func refusals() throws {
        let f = try FakeHome(git: false, socket: false)
        func no(_ rel: String, op: String = "read") -> Bool {
            SandboxGrantStore.refusal(SignedAppCheck.realPath(f.home.appendingPathComponent(rel)), op: op, home: f.home, collie: f.collie) != nil
        }
        for bad in ["", ".ssh", ".ssh/id_ed25519", ".aws/credentials", ".config/gh/hosts.yml", ".netrc", ".docker/config.json",
                    "Library/Application Support/Google/Chrome/Default", "Library/Application Support/Collie/admin.token",
                    "Library/LaunchAgents/x.plist", "code/repo/.git/hooks/pre-commit", "code/repo/.git/config",
                    "code/repo/.git/info/attributes", "code/repo/.git/commondir", "code/repo/.git/worktrees/p/gitdir",
                    // R27: the folders of .git/HEAD, .git/modules/s/index, .git/worktrees/w/HEAD; bare repos; too wide; never granted
                    "code/repo/.git", "code/repo/.git/modules/s", "code/repo/.git/worktrees/w", "code/srv/bare.git", "code/repo/.git/objects",
                    "Library", "Library/Application Support", "Library/Keychains/login.keychain-db", "Library/Mail/V10",
                    "Library/Messages/chat.db", "Library/Group Containers/x", "Library/Containers/com.x"] {
            #expect(no(bad), "\(bad)")
        }
        #expect(SandboxGrantStore.refusal("/", op: "read", home: f.home, collie: f.collie) != nil)
        #expect(SandboxGrantStore.refusal(f.base.path, op: "read", home: f.home, collie: f.collie) != nil)   // above home
        for ok in ["Documents", "Documents/x", ".claude/settings.json", ".zshrc", "code/repo", ".gitignore", "Library/Application Support/Foo", "Library/Preferences"] {
            #expect(!no(ok), "\(ok)")
        }
        #expect(no("Documents/x", op: "exec"))
    }

    @Test func resumeOnlyForClaude() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-resume-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        func args(_ p: Preset, _ cmd: String? = nil) throws -> String {
            let rec = TerminalRecord(id: UUID(), name: "a", preset: p, command: cmd, cwd: "/tmp", isShepherd: false)
            return try AgentLaunch.launchSpec(for: rec, env: [:], hooksDir: dir, collie: URL(fileURLWithPath: "/tmp/collie"),
                                              shell: "/bin/sh", resume: true).arguments.joined(separator: " ")
        }
        #expect(try args(.claude).hasSuffix(" --continue"))
        // R25: the router asks for it only when Claude has a conversation for that cwd
        let home = dir.appendingPathComponent("home")
        #expect(!AgentLaunch.hasClaudeConversation(cwd: "/Users/u/my.proj", home: home))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-Users-u-my-proj"), withIntermediateDirectories: true)
        #expect(!AgentLaunch.hasClaudeConversation(cwd: "/Users/u/my.proj", home: home))   // empty: none
        try "{}".write(to: home.appendingPathComponent(".claude/projects/-Users-u-my-proj/s.jsonl"), atomically: false, encoding: .utf8)
        #expect(AgentLaunch.hasClaudeConversation(cwd: "/Users/u/my.proj", home: home))
        #expect(try !args(.codex).contains("--continue"))
        #expect(try !args(.shell).contains("--continue"))
        #expect(TerminalRecord(id: UUID(), name: "a", preset: .claude, command: nil, cwd: "/", isShepherd: false).resumesConversation)
        #expect(!TerminalRecord(id: UUID(), name: "a", preset: .codex, command: nil, cwd: "/", isShepherd: false).resumesConversation)
    }

    @Test func grantStoreDefensive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-gs-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = SandboxGrantStore(root: root)
        #expect(s.load().isEmpty)   // missing
        let g = SandboxGrant(path: "/a", access: .write, scope: .lot, owner: UUID())
        try s.save([g])
        #expect(s.load() == [SandboxGrant(id: g.id, path: "/a", access: .write, scope: .lot, owner: g.owner,
                                          createdAt: Date(timeIntervalSince1970: g.createdAt.timeIntervalSince1970.rounded(.down)))])
        #expect(try FileManager.default.attributesOfItem(atPath: s.file.path)[.posixPermissions] as? Int == 0o600)
        var text = try String(contentsOf: s.file, encoding: .utf8)
        text = text.replacingOccurrences(of: "[", with: #"[{"path":"/x","access":"root"},"#)   // a bad entry: skipped
        try text.write(to: s.file, atomically: false, encoding: .utf8)
        #expect(s.load().map(\.id) == [g.id])
        try "garbage".write(to: s.file, atomically: false, encoding: .utf8)
        #expect(s.load().isEmpty)
    }
}

@Suite(.serialized) struct SandboxGrantTests {
    /// Review Focus 4: a denial storm → at most one card per (terminal, op, folder), bounded; the daemon keeps answering.
    @Test func denialRaisesOneCardPerFolder() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(await waitFor(20) { rig.feed.starts >= 1 })
            for i in 0..<10_000 { rig.feed.send(denialLine(a.id, "file-read-data", rig.docs.path + "/f\(i)")) }
            #expect(await waitFor(30) { (try? await rig.list().cards.first?.count) == 10_000 })
            for i in 0..<10_000 { rig.feed.send(denialLine(a.id, "file-read-data", rig.docs.path + "/d\(i)/x")) }
            #expect(try await rig.admin("ui.snapshot").ok)   // responsive mid-storm
            let drained = await waitFor(30) { (try? await rig.list().dropped) == 10_000 - (SandboxCards.perTerminal - 1) }
            let seen = try await rig.list()
            #expect(drained, "dropped \(seen.dropped) cards \(seen.cards.count)")
            let l = try await rig.list()
            #expect(l.cards.count == SandboxCards.perTerminal && l.cards.allSatisfy { $0.terminal == a.id && !$0.requested })
            #expect(l.detection == true)
        }
    }

    @Test func denialForUnknownPidIgnored() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(await waitFor(20) { rig.feed.starts >= 1 })
            let stranger = UUID()
            rig.feed.send(denialLine(stranger, "file-read-data", rig.docs.path + "/x"))
            // a forged tag inside the path names A, but the line is the stranger's (final line only): ignored
            rig.feed.send(denialLine(stranger, "file-read-data", "/y\n\(SandboxProfile.tagPrefix)\(a.id.uuidString)"))
            rig.feed.send(denialLine(a.id, "file-read-data", rig.docs.path + "/mine"))   // the marker: processed after them
            #expect(await waitFor(20) { (try? await rig.list().cards.count) == 1 })
            let l = try await rig.list()
            #expect(l.cards.map(\.path) == [rig.docs.path + "/mine"])
            // startup race: a terminal whose profile is rendered, not yet in the workspace, owns its first denial
            var rec = TerminalRecord(id: UUID(), name: "N", preset: .shell, command: nil, cwd: rig.proj.path, isShepherd: false)
            rec.projectRoot = rig.proj.path
            _ = try await rig.d.router.prepareSandbox(rec)
            await rig.d.router.raise(SandboxDenial(terminal: rec.id, op: "read", path: rig.docs.path + "/early"))
            #expect(try await rig.list().cards.contains { $0.terminal == rec.id })
            // the stream dies: detection unavailable until the restart (backoff), then back
            rig.feed.end()
            #expect(await waitFor(20) { rig.feed.starts >= 2 })
            #expect(await waitFor(20) { (try? await rig.list().detection) == true })
        }
    }

    @Test func requestRaisesCard() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A")
            let r = try await rig.call(a, "access.request", ["path": .string("../../Documents/x"), "read": .bool(true),
                                                            "reason": .string("preciso do README; token=abc123 e \(a.token)")])
            #expect(r.ok, "\(r)")
            #expect(try await rig.call(a, "access.request", ["path": .string("/x")]).error?.code == .invalidArgs)   // --read or --write
            let c = try #require(try await rig.list().cards.first)
            #expect(c.requested && c.op == "read" && c.path == SignedAppCheck.realPath(rig.docs.appendingPathComponent("x")))
            #expect(c.reason?.contains("preciso do README") == true && c.reason?.contains("abc123") == false && c.reason?.contains(a.token) == false)
            #expect(c.refusal == nil && c.folderRefusal == nil)
            _ = try await rig.call(a, "access.request", ["path": .string(rig.f.home.appendingPathComponent(".ssh/id_ed25519").path), "read": .bool(true)])
            let ssh = try #require(try await rig.list().cards.first { $0.path.hasSuffix("id_ed25519") })
            #expect(ssh.refusal != nil)   // the card shows only Negar
            #expect(try await rig.grant(a.id, URL(fileURLWithPath: ssh.path)).error?.message.contains("nunca") == true)
            // Negar: the card goes, the same folder stays quiet
            #expect(try await rig.admin("access.deny", ["terminal": .string(a.id.uuidString), "op": .string("read"), "path": .string(c.path)]).ok)
            _ = try await rig.call(a, "access.request", ["path": .string(c.path), "read": .bool(true)])
            #expect(try await !rig.list().cards.contains { $0.path == c.path })
        }
    }

    @Test func onlyAppGrants() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A")
            for cmd in ["access.grant", "access.deny", "access.revoke"] {
                let r = try await rig.call(a, cmd, ["terminal": .string(a.id.uuidString), "path": .string(rig.docs.path), "access": .string("read"),
                                                    "op": .string("read"), "id": .string(UUID().uuidString)])
                #expect(r.error?.code == .unauthorized, "\(cmd): \(r)")
            }
            // its own token presented as the admin's
            let fake = try await UnixSocketClient.send(Request(id: "x", token: a.token, command: "access.grant",
                                                               args: ["terminal": .string(a.id.uuidString), "path": .string(rig.docs.path), "access": .string("read")]),
                                                       to: rig.paths.socket, timeoutSeconds: 10)
            #expect(fake.error?.code == .unauthorized)
            #expect(try await rig.list().grants.isEmpty)
            #expect(try await rig.grant(a.id, rig.docs).ok)
            // too wide / a free terminal
            #expect(try await rig.grant(a.id, rig.f.home).error?.message.contains("Amplo demais") == true)
            #expect(try await rig.grant(a.id, rig.docs.appendingPathComponent("x"), folder: true).ok)   // the folder: Documents
            #expect(try await rig.grant(a.id, rig.f.home.appendingPathComponent(".zshrc"), folder: true).error?.code == .invalidArgs)   // ~ itself
            let free = try await rig.admin("admin.spawn", ["name": .string("F"), "preset": .string("shell"), "cwd": .string(rig.proj.path), "sandbox": .string("free")])
            guard case .object(let o)? = free.result, case .string(let fid)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(free)") }
            #expect(try await rig.grant(UUID(uuidString: fid)!, rig.docs).error?.message.contains("livre") == true)
            // R26: the card's path exactly; one that is now a link (swapped since the card) is refused, not followed
            let link = rig.f.base.appendingPathComponent("swap")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.docs)
            #expect(try await rig.grant(a.id, link).error?.message.contains("mudou") == true)
            #expect(try await rig.grant(a.id, link.appendingPathComponent("x"), folder: true).error?.message.contains("mudou") == true)
        }
    }

    @Test func grantRerendersAndRestarts() async throws {
        let rig = try Rig(shell: "")
        let sh = rig.f.base.appendingPathComponent("fake-shell")   // stands in for the login shell: never a real claude (R1)
        try "#!/bin/sh\necho \"ARGS: $*\"\nexec /bin/sleep 600\n".write(to: sh, atomically: false, encoding: .utf8)
        chmod(sh.path, 0o755)
        rig.d = try Daemon(config: rig.config(shell: sh.path))
        try await rig.run { rig in
            let a = try await rig.spawn("C", preset: "claude", token: false)
            #expect(await waitFor(20) { await rig.d.scrollbackText(a.id).contains("ARGS:") })
            #expect(!(await rig.d.scrollbackText(a.id)).contains("--continue"))
            #expect(!rig.profile(a.id).contains(rig.docs.path))
            // R25: no earlier conversation → plain relaunch (`--continue` would exit at once)
            let cache = rig.f.home.appendingPathComponent(".cache")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let r0 = try await rig.grant(a.id, cache)
            guard case .object(let o0)? = r0.result else { Issue.record("\(r0)"); return }
            #expect(o0["restarted"] == .bool(true) && o0["resumed"] == .bool(false))
            #expect(await waitFor(20) { await rig.d.scrollbackText(a.id).contains("ARGS:") })
            #expect(!(await rig.d.scrollbackText(a.id)).contains("--continue"))
            let conv = rig.f.home.appendingPathComponent(".claude/projects/" + String(rig.proj.path.map { $0.isLetter || $0.isNumber ? $0 : "-" }))
            try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
            try "{}".write(to: conv.appendingPathComponent("s.jsonl"), atomically: false, encoding: .utf8)
            await rig.d.router.raise(SandboxDenial(terminal: a.id, op: "read", path: rig.docs.path + "/x"))
            let r = try await rig.grant(a.id, rig.docs.appendingPathComponent("x"), folder: true)
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["restarted"] == .bool(true) && o["resumed"] == .bool(true))
            #expect(rig.profile(a.id).contains("(subpath \(SandboxProfile.q(rig.docs.path)))"))
            let resumed = await waitFor(20) { await rig.d.scrollbackText(a.id).contains("--continue") }
            let out = await rig.d.scrollbackText(a.id)
            #expect(resumed, "\(out)")
            #expect(try await rig.list().cards.isEmpty)   // the grant covered the card
            let profile = SandboxLaunch.profileFile(a.id, root: rig.paths.root)
            #expect(try rig.f.ok(profile, "cat \(rig.f.h("Documents/x"))"))
        }
    }

    @Test func lotGrantAppliesToLaterMembers() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(try await rig.admin("lot.create", ["name": .string("L"), "members": .string("A")]).ok)
            #expect(try await rig.grant(a.id, rig.docs, scope: "lot").ok)
            #expect(rig.profile(a.id).contains(rig.docs.path))
            let b = try await rig.spawn("B", token: false)
            #expect(!rig.profile(b.id).contains(rig.docs.path))   // not in the lot
            #expect(try await rig.admin("lot.join", ["lot": .string("L"), "terminal": .string("B")]).ok)
            #expect(try await rig.admin("admin.update", ["name": .string("B"), "restart": .bool(true)]).ok)
            #expect(rig.profile(b.id).contains(rig.docs.path))
            let lotId = try #require(try await rig.list().grants.first).owner
            #expect(try await rig.list().grants.allSatisfy { $0.scope == .lot && $0.owner == lotId && $0.owner != a.id })
        }
    }

    @Test func summonedDoesNotInheritTerminalGrants() async throws {
        try await Rig().run { rig in
            let m0 = try await rig.spawn("M", shepherd: true, token: false)
            #expect(try await rig.grant(m0.id, rig.docs).ok)
            let m = Term(id: m0.id, token: try await tokenOf(rig.d, m0.id.uuidString))   // relaunched: a new token
            let w = try await rig.call(m, "summon", ["name": .string("W"), "preset": .string("shell"), "cwd": .string(rig.proj.path)])
            #expect(w.ok, "\(w)")
            guard case .object(let o)? = w.result, case .string(let wid)? = o["id"] else { Issue.record("\(w)"); return }
            #expect(rig.profile(m.id).contains(rig.docs.path))
            #expect(!rig.profile(UUID(uuidString: wid)!).contains(rig.docs.path))
        }
    }

    @Test func revokeNarrows() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(try await rig.grant(a.id, rig.docs, access: "write").ok)
            let profile = SandboxLaunch.profileFile(a.id, root: rig.paths.root)
            #expect(try rig.f.ok(profile, "cat \(rig.f.h("Documents/x")) && echo y > \(rig.f.h("Documents/y"))"))
            let g = try #require(try await rig.list().grants.first)
            let r = try await rig.admin("access.revoke", ["id": .string(g.id.uuidString)])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["restarted"] == .array([.string("A")]))
            #expect(!rig.profile(a.id).contains(rig.docs.path))
            #expect(try !rig.f.ok(profile, "cat \(rig.f.h("Documents/x"))"))
            #expect(try await rig.list().grants.isEmpty)
        }
    }

    /// Review Focus 3: grants survive a daemon restart and apply at the terminal's next start.
    @Test func grantsSurviveRestart() async throws {
        let rig = try Rig()
        try await rig.run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(try await rig.grant(a.id, rig.docs).ok)
        }
        let file = SandboxGrantStore(root: rig.paths.root).file
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        rig.d = try Daemon(config: rig.config())
        try await rig.run { rig in
            #expect(try await rig.list().grants.map(\.path) == [rig.docs.path])
            #expect(try await rig.admin("admin.restart", ["name": .string("A")]).ok)
            let a = try #require(try await rig.list().grants.first).owner
            #expect(rig.profile(a).contains(rig.docs.path))
            // removing the terminal drops its own grants
            #expect(try await rig.admin("admin.kill", ["target": .string("A")]).ok)
            #expect(try await rig.list().grants.isEmpty)
        }
    }
}

@Suite(.serialized) struct SandboxGrantFixTests {
    /// R26: a grant is rendered literally; a symlink swapped in at its path afterwards opens nothing.
    @Test func symlinkSwapAfterGrantOpensNothing() throws {
        let f = try FakeHome()
        let cache = f.base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let g = SandboxGrant(path: cache.path, access: .write, scope: .terminal, owner: f.id)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: f.home.appendingPathComponent("Documents"))
        let p = try f.profile(f.input(grants: [g]))
        #expect(try String(contentsOf: p, encoding: .utf8).contains("(subpath \(SandboxProfile.q(cache.path)))"))
        #expect(try !f.ok(p, "cat \(AgentLaunch.quote(cache.path))/x"))
        #expect(try !f.ok(p, "echo y > \(AgentLaunch.quote(cache.path))/y"))
    }

    /// R27: a write grant never covers a git dir beneath it; the project's own git keeps working under a covering grant.
    @Test func writeGrantNeverCoversGitDirs() throws {
        let f = try FakeHome()
        let fm = FileManager.default
        for d in ["code/other/.git/modules/s/hooks", "code/other/.git/objects", "code/srv/bare.git/hooks"] {
            try fm.createDirectory(at: f.home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let p = try f.profile(f.input(grants: [SandboxGrant(path: f.home.appendingPathComponent("code").path, access: .write, scope: .terminal, owner: f.id)]))
        for bad in ["code/other/.git/modules/s/hooks/post-checkout", "code/other/.git/HEAD", "code/other/.git/objects/o",
                    "code/srv/bare.git/hooks/update", "code/srv/bare.git/config"] {
            #expect(try !f.ok(p, "echo x > \(f.h(bad))"), "\(bad)")
        }
        #expect(try f.ok(p, "echo x > \(f.h("code/other/y")) && echo x > \(f.h("code/other/.gitignore"))"))
        #expect(try f.ok(p, "echo x > \(f.h("code/repo/.git/objects/o"))"))   // the project's own git dir
        #expect(try !f.ok(p, "echo x > \(f.h("code/repo/.git/hooks/pre-commit"))"))
    }

    /// R29: an id reused on another project loses its terminal grants; relaunched free, its id is no longer known.
    @Test func reusedIdOnOtherProjectDropsGrants() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(try await rig.grant(a.id, rig.docs).ok)
            #expect(try await rig.list().grants.first?.project == rig.proj.path)
            let other = rig.f.home.appendingPathComponent("code/other2")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            #expect(try await rig.admin("admin.update", ["name": .string("A"), "cwd": .string(other.path), "restart": .bool(true)]).ok)
            #expect(!rig.profile(a.id).contains(rig.docs.path))
            #expect(try await rig.list().grants.isEmpty)
            // the shell exits; respawned free in place: no longer a known sandboxed terminal (forged lines raise nothing)
            let pty = try #require(await rig.d.process(a.id))
            try pty.write(Data("exit\n".utf8))
            #expect(await waitFor(20) { await rig.d.process(a.id)?.isRunning != true })
            #expect(try await rig.admin("admin.spawn", ["name": .string("A"), "preset": .string("shell"), "cwd": .string(rig.proj.path),
                                                        "sandbox": .string("free")]).ok)
            #expect(await !rig.d.router.sandboxKnown.contains(a.id))
        }
    }
}

/// The final review's fix wave (I1-I3, M2-M5, the parked Task 4 minors).
@Suite(.serialized) struct SandboxFinalFixTests {
    /// I2/R32: a project that is the home itself reopens none of the never-writable files (rc files, global agent
    /// config, Preferences, LaunchAgents, ~/Applications, Collie data); the rest of the home and agent state stay writable.
    @Test func homeProjectKeepsConfigClosed() throws {
        let f = try FakeHome(git: false), p = try f.profile(f.input(project: f.home))
        #expect(try f.ok(p, "echo a > \(f.h("newfile")) && echo a > \(f.h(".claude/projects/x")) && echo a > \(f.h(".claude.json"))"))
        for bad in [".zshrc", ".zprofile", ".bashrc", ".gitconfig", ".config/git/config", ".claude/settings.json", ".claude/hooks/h.sh",
                    ".claude/skills/s/SKILL.md", ".claude/CLAUDE.md", ".codex/config.toml", "Library/Preferences/x.plist",
                    "Library/LaunchAgents/x.plist", "Applications/X.app/x", "Library/Application Support/Collie/admin.token"] {
            #expect(try !f.ok(p, "mkdir -p \"$(dirname \(f.h(bad)))\" 2>/dev/null; echo a > \(f.h(bad))"), "\(bad)")
        }
        #expect(try !f.ok(p, "mv \(f.h(".claude")) \(f.h("c2"))"))   // nor the agent's dir swapped out
        // a grant doesn't reopen them either
        let g = try f.profile(f.input(grants: [SandboxGrant(path: f.home.appendingPathComponent(".claude").path, access: .write, scope: .terminal, owner: f.id)]))
        #expect(try !f.ok(g, "echo a > \(f.h(".claude/settings.json"))"))
    }

    /// I3: the Collie app bundle is never writable, even under a write grant on its folder; the folder's other files are.
    @Test func appBundleNeverWritable() throws {
        let f = try FakeHome(git: false)
        let apps = f.base.appendingPathComponent("Applications"), app = apps.appendingPathComponent("Collie.app")
        let exe = app.appendingPathComponent("Contents/MacOS/collie")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: exe, atomically: false, encoding: .utf8)
        #expect(SandboxInput.appBundle(of: exe)?.path == app.path)
        #expect(SandboxInput.appBundle(of: URL(fileURLWithPath: "/tmp/collie")) == nil)
        var i = f.input(grants: [SandboxGrant(path: apps.path, access: .write, scope: .terminal, owner: f.id)])
        i.appBundle = SandboxInput.appBundle(of: exe)
        let p = try f.profile(i)
        func q(_ u: URL) -> String { AgentLaunch.quote(u.path) }
        #expect(try f.ok(p, "echo a > \(q(apps.appendingPathComponent("other")))"))
        #expect(try !f.ok(p, "echo a > \(q(exe))"))
        #expect(try !f.ok(p, "echo a > \(q(app.appendingPathComponent("Contents/new")))"))
        #expect(try !f.ok(p, "mv \(q(app)) \(q(apps.appendingPathComponent("y.app")))"))
    }

    /// I3, R32, M3: what a click can't open: the app bundle and its ancestors, the never-writable config (writes only),
    /// a pasture's paddock worktrees (writes only).
    @Test func refusalsAddBundleConfigAndPaddocks() throws {
        let f = try FakeHome(git: false, socket: false)
        let app = URL(fileURLWithPath: "/Applications/Collie.app")
        func no(_ path: String, _ op: String = "write", closed: [URL] = []) -> Bool {
            SandboxGrantStore.refusal(path, op: op, home: f.home, collie: f.collie, app: app, closed: closed) != nil
        }
        #expect(no("/Applications/Collie.app/Contents/MacOS/collied") && no("/Applications/Collie.app") && no("/Applications"))
        #expect(no("/Applications/Collie.app/Contents", "read"))
        #expect(!no("/Applications/Other.app"))
        let h = SignedAppCheck.realPath(f.home)
        for rel in [".zshrc", ".gitconfig", ".claude/settings.json", ".claude/skills", ".codex/config.toml", "Library/Preferences", "Applications/X.app"] {
            #expect(no(h + "/" + rel), "\(rel)")
            #expect(!no(h + "/" + rel, "read"), "\(rel)")
        }
        #expect(!no(h + "/.claude.json") && !no(h + "/Documents"))
        let paddocks = [f.repo.appendingPathComponent(".collie/paddocks")]
        #expect(no(f.repo.path + "/.collie/paddocks/p/src", closed: paddocks))
        #expect(!no(f.repo.path + "/.collie/paddocks/p/src", "read", closed: paddocks))
        #expect(!no(f.repo.path + "/src", closed: paddocks))
    }

    /// Parked T4 minor 1: a write grant under TMP (outside the home) keeps git working there (clone into TMP, R17).
    @Test func tmpWriteGrantKeepsGit() throws {
        let f = try FakeHome(git: false)
        let clone = f.base.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let p = try f.profile(f.input(grants: [SandboxGrant(path: clone.path, access: .write, scope: .terminal, owner: f.id)]))
        #expect(try f.ok(p, "echo a > \(AgentLaunch.quote(clone.path))/.git/HEAD"))
        // under the home, a write grant still never covers a git dir
        let docs = f.home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("r/.git"), withIntermediateDirectories: true)
        let q = try f.profile(f.input(grants: [SandboxGrant(path: docs.path, access: .write, scope: .terminal, owner: f.id)]))
        #expect(try !f.ok(q, "echo a > \(f.h("Documents/r/.git/HEAD"))"))
    }

    /// M4: a command run through `env` (or by path) is still detected as Claude / Codex / Cursor.
    @Test func commandAgentPastEnv() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-m4-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        func args(_ p: Preset, _ cmd: String) throws -> String {
            let rec = TerminalRecord(id: UUID(), name: "a", preset: p, command: cmd, cwd: "/tmp", isShepherd: false)
            return try AgentLaunch.launchSpec(for: rec, env: [:], hooksDir: dir, collie: URL(fileURLWithPath: "/tmp/collie"),
                                              shell: "/bin/sh", innerSandboxOff: true).arguments[1]
        }
        #expect(try args(.claude, "env X=1 claude --model x").hasPrefix("env X=1 claude --model x --settings "))
        #expect(try args(.custom, "/opt/bin/claude").hasPrefix("/opt/bin/claude --settings "))
        #expect(try args(.custom, "env A=1 B=2 codex exec hi") == #"env A=1 B=2 codex -c 'sandbox_mode="danger-full-access"' exec hi"#)
        #expect(try args(.custom, "env X=1 cursor-agent") == "env X=1 cursor-agent --sandbox disabled")
        #expect(try args(.custom, "node claude.js") == "node claude.js")
        #expect(EssentialPaths.agentHome(.custom, command: "/usr/bin/env X=1 cursor-agent").first == ".cursor")
    }

    /// Parked T4 minor 3: CLAUDE_CONFIG_DIR and a long cwd (Claude shortens the dir name) still find the conversation.
    @Test func claudeConversationConfigDirAndLongCwd() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-conv-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home"), conf = dir.appendingPathComponent("conf")
        func session(_ base: URL, _ name: String) throws {
            try FileManager.default.createDirectory(at: base.appendingPathComponent("projects/\(name)"), withIntermediateDirectories: true)
            try "{}".write(to: base.appendingPathComponent("projects/\(name)/s.jsonl"), atomically: false, encoding: .utf8)
        }
        try session(conf, "-Users-u-p")
        #expect(!AgentLaunch.hasClaudeConversation(cwd: "/Users/u/p", home: home))
        #expect(AgentLaunch.hasClaudeConversation(cwd: "/Users/u/p", home: home, env: ["CLAUDE_CONFIG_DIR": conf.path]))
        let long = "/Users/u/" + String(repeating: "a", count: 240)
        let enc = String(long.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        try session(home.appendingPathComponent(".claude"), String(enc.prefix(200)) + "-h4sh")
        #expect(AgentLaunch.hasClaudeConversation(cwd: long, home: home))
        #expect(!AgentLaunch.hasClaudeConversation(cwd: "/Users/u/" + String(repeating: "b", count: 240), home: home))
    }

    /// I1: a Shepherd's paddock repo (git's discovery) must lie within its project: a dotfiles home repo is refused.
    @Test func shepherdPaddockOutsideProjectRefused() async throws {
        let rig = try Rig()
        try FakeHome.git(["init", "-q", "-b", "main"], in: rig.f.home)   // the home is a dotfiles repo
        try FakeHome.git(["commit", "-q", "--allow-empty", "-m", "init"], in: rig.f.home)
        try await rig.run { rig in
            let m = try await rig.spawn("M", shepherd: true)
            let r = try await rig.call(m, "paddock.create", ["name": .string("feat")])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("outside") == true, "\(r)")
            #expect(!FileManager.default.fileExists(atPath: rig.f.home.appendingPathComponent(".collie/paddocks/feat").path))
            let h = try await rig.call(m, "herd.apply", ["id": .string("investigar-bug"), "name": .string("x"), "paddock": .bool(true)])
            #expect(h.error?.message.contains("fora do seu projeto") == true, "\(h)")
            #expect(try await rig.admin("paddock.list").result == .array([]))
        }
    }

    /// M5: deleting a lot drops its grants.
    @Test func lotDeleteDropsLotGrants() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A", token: false)
            #expect(try await rig.admin("lot.create", ["name": .string("L"), "members": .string("A")]).ok)
            #expect(try await rig.grant(a.id, rig.docs, scope: "lot").ok)
            #expect(try await rig.grant(a.id, rig.f.home.appendingPathComponent("code")).ok)   // its own: unrelated
            #expect(try await rig.admin("admin.kill", ["target": .string("A")]).ok)
            #expect(try await rig.admin("lot.delete", ["lot": .string("L")]).ok)
            #expect(try await rig.list().grants.isEmpty)
            let disk = try String(contentsOf: rig.paths.root.appendingPathComponent("sandbox/grants.json"), encoding: .utf8)
            #expect(!disk.contains(rig.docs.path), "\(disk)")
        }
    }

    /// Parked T4 minor 2: a request absorbed into an open card says so.
    @Test func absorbedRequestSaysSo() async throws {
        try await Rig().run { rig in
            let a = try await rig.spawn("A")
            let first = try await rig.call(a, "access.request", ["path": .string(rig.docs.appendingPathComponent("x").path), "read": .bool(true)])
            guard case .object(let o)? = first.result, case .string(let m1)? = o["message"] else { Issue.record("\(first)"); return }
            #expect(m1.contains("mostrado"))
            let again = try await rig.call(a, "access.request", ["path": .string(rig.docs.appendingPathComponent("y").path), "read": .bool(true)])
            guard case .object(let o2)? = again.result, case .string(let m2)? = o2["message"] else { Issue.record("\(again)"); return }
            #expect(m2.contains("Já há um aviso aberto"), "\(m2)")
        }
    }
}
