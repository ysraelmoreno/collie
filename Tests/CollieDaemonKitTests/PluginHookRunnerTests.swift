import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let nested: Comment = "already inside a sandbox: sandbox-exec can't nest"
private var fm: FileManager { .default }

/// A temp world: a plug-in store, a project, a data root; helpers are `sh` scripts installed through the store.
private struct World {
    let base: URL, root: URL, project: URL, dataRoot: URL, store: PluginStore
    init() throws {
        base = URL(fileURLWithPath: SignedAppCheck.realPath(fm.temporaryDirectory)).appendingPathComponent("collie-hook-\(UUID().uuidString.prefix(8))")
        root = base.appendingPathComponent("root"); project = base.appendingPathComponent("project")
        dataRoot = root.appendingPathComponent("plugins-data")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        store = PluginStore(root: root)
    }
    /// Installs plug-in `id` whose helper is `body` (after `#!/bin/sh`).
    func install(_ id: String, _ body: String, hooks: [String] = ["edit", "stop"]) async throws {
        let src = base.appendingPathComponent("src-\(id)")
        try fm.createDirectory(at: src.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "<html></html>".write(to: src.appendingPathComponent("ui/index.html"), atomically: true, encoding: .utf8)
        try "MIT".write(to: src.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        let helper = src.appendingPathComponent("bin/h")
        try ("#!/bin/sh\n" + body + "\n").write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let manifest: [String: Any] = [
            "apiVersion": 1, "id": id, "name": id, "version": "0.1.0", "author": "t", "license": "MIT",
            "placements": ["dock.right"], "defaultPlacement": "dock.right", "ui": "ui/index.html",
            "helper": "bin/h", "hooks": hooks, "permissions": ["project": "read"],
            "commands": [Any](), "events": [String](), "stateKeys": [String]()]
        try JSONSerialization.data(withJSONObject: manifest).write(to: src.appendingPathComponent("collie-plugin.json"))
        _ = try await store.install(from: src)
    }
    func run(_ event: PluginHooks.Event = .edit, files: [String] = ["a.swift"]) async -> PluginHooks.Verdict {
        await PluginHookRunner.run(event: event, files: files, project: project, agent: "claude", paddock: "p",
                                   plugins: await PluginHookRunner.candidates(store, event: event), dataRoot: dataRoot)
    }
    func marker(_ id: String) -> Bool { fm.fileExists(atPath: dataRoot.appendingPathComponent("\(id)/marker").path) }
    func cleanup() { PluginStore.removeTree(base) }
}

private let say = #"cat >/dev/null; echo '{"guide":"olhe os irmãos"}'"#
private let touchMarker = #"cat >/dev/null; : > "$COLLIE_PLUGIN_DATA/marker"; echo '{"guide":"rodou"}'"#

@Suite struct PluginHookRunnerTests {
    @Test(.enabled(if: canSandbox, nested)) func guideGetsThePluginPrefix() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("vizinho", say)
        #expect(await w.run() == PluginHooks.Verdict(guide: "[plug-in vizinho] olhe os irmãos"))
    }

    @Test(.enabled(if: canSandbox, nested)) func helperReadsTheEventOnStdin() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("eco", #"cat > "$COLLIE_PLUGIN_DATA/in.json"; echo '{}'"#)
        _ = await w.run(files: ["x/Y.swift"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: w.dataRoot.appendingPathComponent("eco/in.json"))) as? [String: Any]
        #expect(json?["event"] as? String == "edit" && json?["files"] as? [String] == ["x/Y.swift"] && json?["paddock"] as? String == "p")
        #expect(try fm.attributesOfItem(atPath: w.dataRoot.appendingPathComponent("eco").path)[.posixPermissions] as? Int == 0o700)
    }

    @Test(.enabled(if: canSandbox, nested)) func twoPluginsMergeById() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("zeta", #"cat >/dev/null; echo '{"guide":"z"}'"#)
        try await w.install("alfa", #"cat >/dev/null; echo '{"guide":"a"}'"#)
        #expect(await w.run().guide == "[plug-in alfa] a\n[plug-in zeta] z")
    }

    @Test(.enabled(if: canSandbox, nested)) func slowHelperIsKilledAndIgnored() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("lento", "cat >/dev/null; sleep 10; echo '{\"guide\":\"tarde\"}'")
        let t0 = Date()
        let v = await w.run()
        #expect(v == PluginHooks.Verdict())
        // 3 s of deadline, then up to 1.1 s for SIGTERM to take: under the hook client's 5 s
        #expect(Date().timeIntervalSince(t0) < 5)
        let left = Process(); left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); left.arguments = ["-f", w.root.path]
        let out = Pipe(); left.standardOutput = out
        try left.run(); left.waitUntilExit()
        #expect(left.terminationStatus != 0, "o helper sobreviveu")
    }

    @Test(.enabled(if: canSandbox, nested)) func failingHelpersAreSilent() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("sai1", "cat >/dev/null; echo '{\"guide\":\"x\"}'; exit 1")
        try await w.install("lixo", "cat >/dev/null; echo 'isto não é json'")
        try await w.install("vazio", "cat >/dev/null")
        #expect(await w.run() == PluginHooks.Verdict())
    }

    @Test(.enabled(if: canSandbox, nested)) func disabledOrUndeclaredDoesNotRun() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("desligado", touchMarker)
        try await w.install("so-stop", touchMarker, hooks: ["stop"])
        try await w.store.setEnabled("desligado", false)
        #expect(await w.run(.edit) == PluginHooks.Verdict())
        #expect(!w.marker("desligado") && !w.marker("so-stop"))
        _ = await w.run(.stop)   // a stop verdict carries no guide: the marker is the proof it ran
        #expect(w.marker("so-stop") && !w.marker("desligado"))
    }

    @Test(.enabled(if: canSandbox, nested)) func noFilesNoProcess() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("quieto", touchMarker)
        // a file outside the project is no edited file at all
        let outside = try JSONSerialization.data(withJSONObject: ["tool_name": "Write", "tool_input": ["file_path": "/etc/hosts"]])
        let files = PluginHooks.editedFiles(toolPayload: outside, project: w.project)
        #expect(files.isEmpty)
        #expect(await w.run(files: files) == PluginHooks.Verdict() && !w.marker("quieto"))
        #expect(await w.run(.stop, files: []) == PluginHooks.Verdict() && !w.marker("quieto"))
    }

    @Test(.enabled(if: canSandbox, nested)) func helperCannotWriteTheProject() async throws {
        let w = try World(); defer { w.cleanup() }
        try await w.install("fuxico", "cat >/dev/null; echo x > '\(w.project.path)/marker'; echo '{\"guide\":\"escreveu\"}'")
        _ = await w.run()
        #expect(!fm.fileExists(atPath: w.project.appendingPathComponent("marker").path))
    }

    @Test func turnFilesComeOnceThenReset() {
        var t = PluginTurn(); let a = UUID(), b = UUID()
        t.add(["x"], to: a); t.add(["y", "x"], to: a); t.add(["z"], to: b)
        #expect(t.take(a) == ["x", "y"] && t.take(a) == [] && t.take(b) == ["z"])
        t.add(["x"], to: a); t.drop(a)
        #expect(t.take(a) == [])
        t.add((0..<300).map { "f\($0)" }, to: a)
        #expect(t.take(a).count == PluginTurn.maxFiles)
    }

    @Test func continuedStopIsRecognised() {
        #expect(PluginTurn.isContinued(Data(#"{"stop_hook_active":true}"#.utf8)))
        #expect(!PluginTurn.isContinued(Data(#"{"stop_hook_active":false}"#.utf8)))
        #expect(!PluginTurn.isContinued(Data("lixo".utf8)) && !PluginTurn.isContinued(Data("{}".utf8)))
    }
}
