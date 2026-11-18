import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func tempDir() throws -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-lc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func idOf(_ r: Response) -> String? {
    if case .object(let o)? = r.result, case .string(let s)? = o["id"] { return s }
    return nil
}
/// A stand-in agent (never the real one): records its arguments beside itself, prints the token, then waits.
private func fakeAgent(_ name: String = "claude") throws -> URL {
    let bin = try tempDir().appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let f = bin.appendingPathComponent(name)
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args.$COLLIE_TERMINAL_ID\"\necho \"T=$COLLIE_TOKEN\"\nexec sleep 600\n"
        .write(to: f, atomically: true, encoding: .utf8)
    chmod(f.path, 0o755)
    return f
}
private func args(_ fake: URL, _ id: String) -> [String] {
    (try? String(contentsOfFile: fake.path + ".args." + id, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}
private func spawnAgent(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, fake: URL, free: Bool = false) async throws -> (String, [String]) {
    var a: [String: JSONValue] = ["name": .string(name), "preset": .string("custom"), "command": .string(fake.path), "cwd": .string(cwd.path)]
    if free { a["sandbox"] = .string("free") }
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: a), to: p.socket, timeoutSeconds: 60)
    guard let id = idOf(r) else { throw ProtocolError(code: .internal, message: "\(r)") }
    _ = try await tokenOf(d, id, echo: false)
    return (id, args(fake, id))
}
/// The values that follow each `--plugin-dir`, in order.
private func pluginDirs(_ a: [String]) -> [String] { a.indices.filter { a[$0] == "--plugin-dir" && $0 + 1 < a.count }.map { a[$0 + 1] } }
private func relaunch(_ d: Daemon, _ id: String, fake: URL, resume: Bool) async throws -> [String] {
    try? FileManager.default.removeItem(atPath: fake.path + ".args." + id)
    let rec = try #require(await d.router.ws.terminals.first { $0.id.uuidString == id })
    _ = try await d.router.relaunch(rec, resume: resume)
    _ = await waitFor(20) { !args(fake, id).isEmpty }
    return args(fake, id)
}

@Suite struct LoopCommandUnitTests {
    @Test func rendersAPluginNamedCollieWithTheLoopCommand() throws {
        let root = try tempDir(), dir = LoopCommand.dir(UUID(), root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try LoopCommand.render(into: dir)
        #expect(dir.lastPathComponent == "collie" && dir.deletingLastPathComponent().lastPathComponent == "plugin")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: String]
        #expect(manifest?["name"] == "collie")
        let md = try String(contentsOf: dir.appendingPathComponent("commands/loop.md"), encoding: .utf8)
        #expect(md == LoopCommand.markdown(arguments: true))
        #expect(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("commands/loop.md").path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        try LoopCommand.render(into: dir)   // a second render swaps it in, no leftover beside it
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path) == ["collie"])
    }

    @Test func theTextIsStaticAndTeachesTheRules() {
        let md = LoopCommand.markdown(arguments: true)
        #expect(md.hasPrefix("---\ndescription: "))
        #expect(md.components(separatedBy: "$ARGUMENTS").count == 2)          // once
        #expect(!LoopCommand.markdown(arguments: false).contains("$ARGUMENTS"))
        #expect(LoopCommand.markdown(arguments: false).contains("The owner's request follows this command."))
        #expect(!md.contains("`"))                                              // no inline shell (`!`cmd``) can hide in it
        for must in ["Only a Shepherd inside a paddock", "Wait for the answer", "collie work run --max", "Permitir", "Never land or push",
                     "Answer in the owner's language.", "a paddock that is a shared folder does not qualify",
                     "goes once in the loop's gate, --gate '<command>'", "collie work run --max <n> [--gate '<command>']",
                     "the gate word for word"] {
            #expect(md.contains(must))
        }
    }

    @Test func refusesASymlinkedDir() throws {
        let root = try tempDir(), dir = LoopCommand.dir(UUID(), root: root), elsewhere = root.appendingPathComponent("elsewhere")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.deletingLastPathComponent(), withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try LoopCommand.render(into: dir) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}

@Suite(.serialized) struct LoopCommandTests {
    @Test func aClaudeTerminalLaunchesWithBothPlugins() async throws {
        let repo = try await makeRepo(), fake = try fakeAgent()
        try await withDaemon(configure: { $0.claudePluginDir = { _ in true } }) { d, p in
            let (id, a) = try await spawnAgent(d, p, "A", cwd: repo, fake: fake)
            let uuid = try #require(UUID(uuidString: id))
            #expect(pluginDirs(a) == [ProcedureSkills.dir(uuid, root: p.root).path, LoopCommand.dir(uuid, root: p.root).path], "\(a)")
            let md = try String(contentsOf: LoopCommand.dir(uuid, root: p.root).appendingPathComponent("commands/loop.md"), encoding: .utf8)
            #expect(md == LoopCommand.markdown(arguments: true))
            #expect(md.contains("--gate") && !md.contains("`") && !md.contains(id) && !md.contains(p.root.path))   // teaches the gate, still static
        }
    }

    @Test func withoutPluginDirSupportNothingIsRenderedOrPassed() async throws {
        let repo = try await makeRepo(), fake = try fakeAgent()
        try await withDaemon(configure: { $0.claudePluginDir = { _ in false } }) { d, p in
            let (id, a) = try await spawnAgent(d, p, "A", cwd: repo, fake: fake)
            #expect(a.contains("--settings") && !a.contains("--plugin-dir"), "\(a)")
            #expect(!FileManager.default.fileExists(atPath: LoopCommand.dir(try #require(UUID(uuidString: id)), root: p.root).path))
        }
    }

    @Test func aShellOrCodexTerminalGetsNoCommand() async throws {
        let repo = try await makeRepo(), codex = try fakeAgent("codex")
        try await withDaemon(configure: { $0.claudePluginDir = { _ in true } }) { d, p in
            let (c, a) = try await spawnAgent(d, p, "C", cwd: repo, fake: codex)
            #expect(!a.contains("--plugin-dir"), "\(a)")
            let s = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
                "name": .string("S"), "preset": .string("shell"), "cwd": .string(repo.path)]), to: p.socket, timeoutSeconds: 60)
            for id in [c, try #require(idOf(s))] {
                #expect(!FileManager.default.fileExists(atPath: LoopCommand.dir(try #require(UUID(uuidString: id)), root: p.root).path))
            }
        }
    }

    @Test func theCommandDirGoesWithTheTerminal() async throws {
        let repo = try await makeRepo(), fake = try fakeAgent()
        try await withDaemon(configure: { $0.claudePluginDir = { _ in true } }) { d, p in
            let (id, _) = try await spawnAgent(d, p, "A", cwd: repo, fake: fake)
            let dir = LoopCommand.dir(try #require(UUID(uuidString: id)), root: p.root)
            #expect(FileManager.default.fileExists(atPath: dir.path))
            #expect(try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.kill", args: ["target": .string("A")]),
                                                    to: p.socket, timeoutSeconds: 60).ok)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    /// Review Focus 2: relaunched after a sandbox grant, the command dir is rendered again; both flags come before `--continue`.
    @Test func aRelaunchRendersItAgainBeforeContinue() async throws {
        let repo = try await makeRepo(), fake = try fakeAgent(), home = try tempDir()
        let conv = home.appendingPathComponent(".claude/projects/" + String(repo.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }))
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        try "{}".write(to: conv.appendingPathComponent("s.jsonl"), atomically: false, encoding: .utf8)
        try await withDaemon(configure: { $0.claudePluginDir = { _ in true }; $0.sandboxHome = home }) { d, p in
            let (id, _) = try await spawnAgent(d, p, "A", cwd: repo, fake: fake, free: true)
            let uuid = try #require(UUID(uuidString: id)), dir = LoopCommand.dir(uuid, root: p.root)
            try FileManager.default.removeItem(at: dir)
            let a = try await relaunch(d, id, fake: fake, resume: true)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("commands/loop.md").path))
            let procs = ProcedureSkills.dir(uuid, root: p.root).path
            #expect(Array(a.suffix(5)) == ["--plugin-dir", procs, "--plugin-dir", dir.path, "--continue"], "\(a)")
        }
    }

    /// Review Focus 1: the command can't be rendered (a symlink where it goes): the terminal still runs, with no flag for it.
    @Test func aFailedRenderStillLaunches() async throws {
        let repo = try await makeRepo(), fake = try fakeAgent(), elsewhere = try tempDir()
        try await withDaemon(configure: { $0.claudePluginDir = { _ in true } }) { d, p in
            let (id, _) = try await spawnAgent(d, p, "A", cwd: repo, fake: fake)
            let uuid = try #require(UUID(uuidString: id)), dir = LoopCommand.dir(uuid, root: p.root)
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: elsewhere)
            let a = try await relaunch(d, id, fake: fake, resume: false)
            #expect(a.contains("--settings"), "\(a)")   // it ran
            #expect(pluginDirs(a) == [ProcedureSkills.dir(uuid, root: p.root).path], "\(a)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }
}
