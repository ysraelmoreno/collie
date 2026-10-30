import Testing
import Foundation
import os
import CollieNetwork
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
        let addon = #"print('{"ready": 1}', flush=True)"# + "\n"   // JSON: other lines are noise, never queued
        let m = try await MitmProcess.start(tool: tool, addonSource: addon, confdir: base.appendingPathComponent("network/mitm"), runDir: run)
        #expect(MitmProcess.listening(port: m.port))
        #expect(FileManager.default.fileExists(atPath: m.caCert.path))
        let key = try FileManager.default.attributesOfItem(atPath: m.confdir.appendingPathComponent("mitmproxy-ca.pem").path)[.posixPermissions] as? Int
        #expect(key == 0o600)
        var it = m.lines.makeAsyncIterator()
        #expect(await it.next() == #"{"ready": 1}"#)
        let r = try await m.restarted()
        #expect(r.port == m.port && MitmProcess.listening(port: r.port))
        r.stop()
        while await it.next() != nil {}   // the first one's stream finished when it exited
        for _ in 0..<30 where MitmProcess.listening(port: r.port) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!MitmProcess.listening(port: r.port))
    }

    // MARK: lines (review 🔴1, 🟡7, 🟢10, 🟢11)

    /// A JSON request line whose body is `n` base64 characters.
    private static func flowLine(_ n: Int) -> String {
        #"{"type":"request","id":"f\#(n)","ts":1.0,"method":"POST","url":"https://x/","httpVersion":"HTTP/1.1","headers":[],"body":{"size":\#(n),"truncated":false,"contentEncoding":null,"data":"\#(String(repeating: "A", count: n))"},"tls":null}"#
    }

    @Test func splitterKeepsBigLinesWhole() {
        var sp = LineSplitter(maxLine: MitmProcess.maxLine)
        let text = Data((Self.flowLine(100_000) + "\n" + Self.flowLine(2_000_000) + "\r\nnoise\n").utf8)
        var lines: [String] = []
        for off in stride(from: 0, to: text.count, by: 65_536) {   // as the pipe hands it over
            let (l, over) = sp.feed(text[off..<min(off + 65_536, text.count)]); lines += l; #expect(over == 0)
        }
        #expect(lines.count == 3 && lines[2] == "noise")
        for (line, n) in zip(lines, [100_000, 2_000_000]) {
            guard case .request(let r)? = FlowEvent.decode(line: line) else { Issue.record("not a flow: \(line.prefix(80))"); continue }
            #expect(r.body?.data.count == n / 4 * 3)
        }
    }

    @Test func splitterDropsOverlongLinesWholeAndCountsThem() {
        var sp = LineSplitter(maxLine: 10)
        var (lines, over) = sp.feed(Data("short\n0123456789ABCDEF".utf8))
        #expect(lines == ["short"] && over == 1)
        (lines, over) = sp.feed(Data("GHIJ\nnext\nlast".utf8))   // the rest of the long one is skipped, not emitted
        #expect(lines == ["next"] && over == 0)
        (lines, over) = sp.finish()
        #expect(lines == ["last"])
        #expect(MitmProcess.maxLine > MitmProcess.bodyCap * 4 / 3)   // a full-size body still fits
    }

    @Test func queueIsBoundedByUnreadBytes() {
        let got = OSAllocatedUnfairLock(initialState: [String]())
        let q = LineQueue(limit: 10, yield: { l in got.withLock { $0.append(l) } })
        q.push("{1234567}")   // 9 bytes
        q.push("{12}")        // over the limit while the first is unread: dropped
        q.push("Traceback: boom")   // not JSON: kept as noise, never queued
        #expect(got.withLock { $0 } == ["{1234567}"] && q.dropped == 1 && q.lastNoise == "Traceback: boom")
        q.consumed(9)
        q.push("{12}")
        #expect(got.withLock { $0.count } == 2)
        q.overlong(2)
        #expect(q.dropped == 3)
    }

    /// A stand-in mitmdump (python3): `ok` writes the CA, listens, prints noise on stderr then two flow lines (100 KB,
    /// 2 MB) on stdout; `fail` complains on stderr and exits, as when its port was taken. Each run appends to `count`.
    private func fakeMitm(_ mode: String, in dir: URL) throws -> (MitmTool, URL) {
        let script = dir.appendingPathComponent("mitmdump-\(mode)"), count = dir.appendingPathComponent("count-\(mode)")
        try """
            #!/usr/bin/env python3
            import json, os, socket, sys, time
            a = sys.argv[1:]
            open("\(count.path)", "a").write("x")
            if "\(mode)" == "fail":
                sys.stderr.write("Error starting proxy server: OSError(48, 'Address already in use')\\n"); sys.exit(1)
            port = int(a[a.index("-p") + 1]); conf = [x for x in a if x.startswith("confdir=")][0][8:]
            open(os.path.join(conf, "mitmproxy-ca-cert.pem"), "w").write("x")
            s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(5)
            sys.stderr.write("noise on stderr\\n"); sys.stderr.flush()
            for n in (100000, 2000000):
                print(json.dumps({"type": "request", "id": "f%d" % n, "ts": 1.0, "method": "POST", "url": "https://x/",
                                  "httpVersion": "HTTP/1.1", "headers": [], "tls": None,
                                  "body": {"size": n, "truncated": False, "contentEncoding": None, "data": "A" * n}}), flush=True)
            time.sleep(60)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (MitmTool(url: script), count)
    }

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/collie-fakemitm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("run/terminals"), withIntermediateDirectories: true)
        return dir
    }

    @Test func bigFlowLinesArriveWholeThroughTheProcess() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tool, _) = try fakeMitm("ok", in: dir)
        let m = try await MitmProcess.start(tool: tool, addonSource: "", confdir: dir.appendingPathComponent("conf"),
                                            runDir: dir.appendingPathComponent("run"), ready: .seconds(10))
        defer { m.stop() }
        var sizes: [Int] = []
        for await line in m.lines {
            m.consumed(line)
            if case .request(let r)? = FlowEvent.decode(line: line) { sizes.append(r.body?.size ?? -1) }
            if sizes.count == 2 { break }
        }
        #expect(sizes == [100_000, 2_000_000])
        #expect(m.dropped == 0 && m.lastNoise == "noise on stderr")   // stderr came through, and stayed out of `lines`
    }

    @Test func exitBeforeListeningSaysWhyAndRetriesOnce() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tool, count) = try fakeMitm("fail", in: dir)
        do {
            _ = try await MitmProcess.start(tool: tool, addonSource: "", confdir: dir.appendingPathComponent("conf"),
                                            runDir: dir.appendingPathComponent("run"), ready: .seconds(10))
            Issue.record("started")
        } catch {
            #expect(error.message.contains("Address already in use"))
        }
        #expect(try String(contentsOf: count, encoding: .utf8) == "xx")   // one retry, on another port
        let addons = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("run/network").path)
        #expect(addons.isEmpty)   // each failed start removed its addon file
    }
}
