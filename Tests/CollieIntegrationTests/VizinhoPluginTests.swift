import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
import CollieDaemonKit

// Needs `scripts/build-vizinho-plugin.sh` first (it runs swift build, which can't run inside swift test: SwiftPM lock).
private let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let colliedURL = pkg.appendingPathComponent(".build/debug/collied")
private let pluginDir = pkg.appendingPathComponent(".build/plugins/vizinho")
// The runner never builds the plug-in, so the test skips there instead of failing. To cover it in CI for real,
// add a step running scripts/build-vizinho-plugin.sh to .github/workflows/ci.yml before the test step.
private let pluginBuilt = FileManager.default.isExecutableFile(atPath: pluginDir.appendingPathComponent("bin/vizinho").path)
private let nested: Comment = "already inside a sandbox: sandbox-exec can't nest"
private let canSandbox: Bool = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}()

@Suite struct VizinhoPluginTests {
    @Test(.enabled(if: canSandbox, nested),
          .enabled(if: pluginBuilt, "plug-in do Vizinho não construído (rode scripts/build-vizinho-plugin.sh)"),
          .timeLimit(.minutes(2))) func editGuidesFromSiblingsAndLoneFileIsSilent() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/tmp/collie-viz-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), project = base.appendingPathComponent("project")
        let dir = project.appendingPathComponent("Sources/P"), lone = project.appendingPathComponent("Other")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: lone, withIntermediateDirectories: true)
        for i in 0..<5 { try "import A\nstruct Item\(i)Panel {}\n".write(to: dir.appendingPathComponent("Item\(i)Panel.swift"), atomically: true, encoding: .utf8) }
        try "struct FooPanel {}\n".write(to: dir.appendingPathComponent("FooPanel.swift"), atomically: true, encoding: .utf8)
        try "struct Lone {}\n".write(to: lone.appendingPathComponent("Lone.swift"), atomically: true, encoding: .utf8)

        // a SHELL stub plays the Claude terminal and hands its token over (the real claude is never run)
        let tokFile = base.appendingPathComponent("tok")
        let shell = base.appendingPathComponent("fakeshell")
        try "#!/bin/sh\nprintf '%s' \"$COLLIE_TOKEN\" > '\(tokFile.path)'\nexec sleep 300\n".write(to: shell, atomically: true, encoding: .utf8)
        chmod(shell.path, 0o755)
        let p = Process()
        p.executableURL = colliedURL
        p.arguments = ["--root", root.path, "--no-terminal-sandbox"]
        p.environment = ["PATH": "/usr/bin:/bin", "SHELL": shell.path, "HOME": NSHomeDirectory(), "COLLIE_USER_ENV": "off"]
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGTERM); p.waitUntilExit() } }
        let sock = root.appendingPathComponent("run/collied.sock"), tf = root.appendingPathComponent("admin.token")
        try #require(await waitFor(5) { fm.fileExists(atPath: sock.path) && fm.fileExists(atPath: tf.path) })
        let admin = try String(contentsOf: tf, encoding: .utf8)

        let inst = try await UnixSocketClient.send(Request(id: "i", token: admin, command: "plugin.install",
                                                           args: ["path": .string(pluginDir.path)]), to: sock, timeoutSeconds: 30)
        try #require(inst.ok, "install: \(String(describing: inst.error))")
        let sp = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
            "name": .string("C"), "preset": .string("claude"), "cwd": .string(project.path), "command": .string("claude")]), to: sock, timeoutSeconds: 5)
        guard case .object(let o)? = sp.result, case .string(let id)? = o["id"] else { Issue.record("spawn \(sp)"); return }
        try #require(await waitFor(5) { (try? String(contentsOf: tokFile, encoding: .utf8))?.count ?? 0 > 60 })
        let token = try String(contentsOf: tokFile, encoding: .utf8)

        func edit(_ file: String) async throws -> [String: JSONValue] {
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["tool_name": "Write", "tool_input": ["file_path": file]]), as: UTF8.self)
            let r = try await UnixSocketClient.send(Request(id: "h", terminalId: id, token: token, command: "plugin.hook",
                args: ["event": .string("edit"), "payload": .string(payload)]), to: sock, timeoutSeconds: 10)
            #expect(r.ok)
            guard case .object(let out)? = r.result else { return [:] }
            return out
        }
        let guided = try await edit("Sources/P/FooPanel.swift")
        guard case .string(let guide)? = guided["guide"] else { Issue.record("no guide: \(guided)"); return }
        #expect(guide.hasPrefix("[plug-in vizinho] Sources/P/FooPanel.swift:"))
        #expect(guide.contains("Modelo: Sources/P/Item") && guide.contains("5 de 5 importam A"))
        #expect(try await edit("Other/Lone.swift").isEmpty)
    }
}
