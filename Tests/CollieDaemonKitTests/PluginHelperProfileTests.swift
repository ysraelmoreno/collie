import Testing
import Foundation
@testable import CollieDaemonKit

private let nested: Comment = "already inside a sandbox: sandbox-exec can't nest"

private struct Fixture {
    let base: URL, input: PluginHelperInput, outside: URL
    init(script: String) throws {
        let fm = FileManager.default
        base = URL(fileURLWithPath: SignedAppCheck.realPath(fm.temporaryDirectory))
            .appendingPathComponent("collie-helper-\(UUID().uuidString.prefix(8))")
        let plugin = base.appendingPathComponent("plugin"), project = base.appendingPathComponent("project")
        let data = base.appendingPathComponent("data"), out = base.appendingPathComponent("outside")
        for d in [plugin, project, data, out] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try "projeto".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "segredo".write(to: out.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let helper = plugin.appendingPathComponent("helper")
        try ("#!/bin/sh\n" + script).write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        outside = out
        input = PluginHelperInput(helper: helper, pluginDir: plugin, project: project, dataDir: data)
    }
    func run() throws -> (status: Int32, out: String) {
        let c = PluginHelperProfile.command(input, profile: PluginHelperProfile.render(input))
        let p = Process(), pipe = Pipe()
        p.executableURL = c.executable; p.arguments = c.args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite struct PluginHelperProfileTests {
    @Test func profileText() throws {
        let f = try Fixture(script: "")
        defer { f.cleanup() }
        let p = PluginHelperProfile.render(f.input)
        #expect(p.split(separator: "\n").prefix(2) == ["(version 1)", "(deny default)"])
        #expect(!p.contains("(allow default)") && !p.contains("network") && !p.contains("AF_") && !p.contains("unix-socket"))
        let writes = p.split(separator: "\n").filter { $0.hasPrefix("(allow file-write") }
        #expect(writes == ["(allow file-write* (subpath \"\(f.input.dataDir.path)\"))", "(allow file-write* (literal \"/dev/null\"))"])
        #expect(p.contains("(allow file-read* (subpath \"\(f.input.project.path)\"))"))
        #expect(!p.contains(f.outside.path))
        let c = PluginHelperProfile.command(f.input, profile: p)
        #expect(c.executable.path == "/usr/bin/sandbox-exec" && c.args == ["-p", p, f.input.helper.path])
    }

    @Test(.enabled(if: canSandbox, nested)) func readsProjectWritesData() throws {
        let f = try Fixture(script: "")
        defer { f.cleanup() }
        try rewrite(f, "cat '\(f.input.project.path)/a.txt'; echo x > '\(f.input.dataDir.path)/out' && echo wrote")
        let r = try f.run()
        #expect(r.out == "projetowrote\n", "\(r)")
        #expect(FileManager.default.fileExists(atPath: f.input.dataDir.appendingPathComponent("out").path))
    }

    @Test(.enabled(if: canSandbox, nested)) func cannotWriteProject() throws {
        let f = try Fixture(script: "")
        defer { f.cleanup() }
        try rewrite(f, "echo x > '\(f.input.project.path)/new' && echo wrote; echo done")
        let r = try f.run()
        #expect(r.out == "done\n" && !FileManager.default.fileExists(atPath: f.input.project.appendingPathComponent("new").path))
    }

    @Test(.enabled(if: canSandbox, nested)) func cannotReadOutside() throws {
        let f = try Fixture(script: "")
        defer { f.cleanup() }
        try rewrite(f, "cat '\(f.outside.path)/s.txt' && echo leaked; echo done")
        #expect(try f.run().out == "done\n")
    }

    @Test(.enabled(if: canSandbox, nested)) func noNetwork() throws {
        let f = try Fixture(script: "")
        defer { f.cleanup() }
        // a listener the helper could reach if the network were open
        let srv = Process()
        srv.executableURL = URL(fileURLWithPath: "/usr/bin/nc"); srv.arguments = ["-l", "127.0.0.1", "47931"]
        srv.standardOutput = FileHandle.nullDevice; srv.standardError = FileHandle.nullDevice
        try srv.run()
        defer { srv.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        try rewrite(f, "/usr/bin/nc -z -w 2 127.0.0.1 47931 && echo connected; echo done")
        #expect(try f.run().out == "done\n")
    }

    private func rewrite(_ f: Fixture, _ body: String) throws {
        try ("#!/bin/sh\n" + body + "\n").write(to: f.input.helper, atomically: true, encoding: .utf8)
    }
}
