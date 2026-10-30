import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct NetworkMitmTests {
    @Test func versionParses() {
        #expect(MitmTool.parseVersion("Mitmproxy: 12.3.1 binary\nPython:    3.15.1\nOpenSSL:   OpenSSL 3.5\n") == "12.3.1")
        #expect(MitmTool.parseVersion("Mitmproxy: 11.0.0\n") == "11.0.0")
        #expect(MitmTool.parseVersion("command not found") == nil)
    }

    @Test func locatePrefersOverrideThenCandidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-mitm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func exe(_ n: String) throws -> String {
            let f = dir.appendingPathComponent(n)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            return f.path
        }
        let a = try exe("brew-arm"), b = try exe("brew-intel"), o = try exe("override")
        #expect(MitmTool.locate(env: ["COLLIE_MITMDUMP": o], candidates: [a, b])?.path == o)
        #expect(MitmTool.locate(env: [:], candidates: ["/nonexistent", b])?.path == b)
        #expect(MitmTool.locate(env: ["COLLIE_MITMDUMP": "/nonexistent"], candidates: [a])?.path == a)
        #expect(MitmTool.locate(env: [:], candidates: ["/nonexistent"]) == nil)
        #expect(MitmTool.missing.message.contains("brew install --cask mitmproxy"))
    }

    @Test func argsAreLoopbackHttp1() {
        let args = MitmProcess.args(port: 51234, confdir: URL(fileURLWithPath: "/c/network/mitm"), addon: URL(fileURLWithPath: "/r/network/addon.py"))
        #expect(args == ["--listen-host", "127.0.0.1", "-p", "51234", "--set", "confdir=/c/network/mitm", "--set", "http2=false",
                         "-q", "-s", "/r/network/addon.py"])
    }

    @Test func freePortIsFree() throws {
        let p = try MitmProcess.freePort()
        #expect(p > 0 && p < 65536)
        #expect(!MitmProcess.listening(port: p))
    }

    @Test func confdirIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-conf-\(UUID().uuidString)/network/mitm")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        try MitmProcess.prepareConfdir(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try MitmProcess.prepareConfdir(dir)   // a loosened one is tightened again
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    /// Runs the real mitmdump when installed (`COLLIE_E2E_MITM=1`): starts, has a CA and a listener, echoes the addon's lines, stops.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_E2E_MITM"] != nil
                   && MitmTool.locate(env: ProcessInfo.processInfo.environment) != nil))
    func realMitmdumpStartsAndStops() async throws {
        let tool = MitmTool(url: MitmTool.locate(env: ProcessInfo.processInfo.environment)!)
        #expect(try await tool.version().split(separator: ".").count >= 2)
        let base = URL(fileURLWithPath: "/tmp/collie-mitm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let run = base.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run.appendingPathComponent("terminals"), withIntermediateDirectories: true)
        let addon = "print('collie-addon-ready', flush=True)\n"
        let m = try await MitmProcess.start(tool: tool, addonSource: addon, confdir: base.appendingPathComponent("network/mitm"), runDir: run)
        #expect(MitmProcess.listening(port: m.port))
        #expect(FileManager.default.fileExists(atPath: m.caCert.path))
        let key = try FileManager.default.attributesOfItem(atPath: m.confdir.appendingPathComponent("mitmproxy-ca.pem").path)[.posixPermissions] as? Int
        #expect(key == 0o600)
        var it = m.lines.makeAsyncIterator()
        #expect(await it.next() == "collie-addon-ready")
        let r = try await m.restarted()
        #expect(r.port == m.port && MitmProcess.listening(port: r.port))
        r.stop()
        while await it.next() != nil {}   // the first one's stream finished when it exited
        for _ in 0..<30 where MitmProcess.listening(port: r.port) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!MitmProcess.listening(port: r.port))
    }
}
