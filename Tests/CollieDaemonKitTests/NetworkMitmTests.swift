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
        let withRules = MitmProcess.args(port: 1, confdir: URL(fileURLWithPath: "/c"), addon: URL(fileURLWithPath: "/a.py"),
                                         rules: URL(fileURLWithPath: "/r/network/rules.json"))
        #expect(withRules.suffix(2) == ["--set", "collie_rules=/r/network/rules.json"])
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

    @Test func argsWithUpstreamCA() {
        let a = MitmProcess.args(port: 1, confdir: URL(fileURLWithPath: "/c"), addon: URL(fileURLWithPath: "/a.py"),
                                 upstreamCA: URL(fileURLWithPath: "/c/up.pem"))
        #expect(Array(a.suffix(2)) == ["--set", "ssl_verify_upstream_trusted_ca=/c/up.pem"])
        #expect(!a.contains { $0.contains("ssl_insecure") })
        #expect(!MitmProcess.args(port: 1, confdir: URL(fileURLWithPath: "/c"), addon: URL(fileURLWithPath: "/a.py"))
            .contains { $0.contains("ssl_verify_upstream") })
    }

    /// Every start attempt (attach, its one retry, and `restarted`) asks for the bundle again: a mitmdump that exits at
    /// once (/usr/bin/false) makes `start` retry on another port, so the closure runs twice.
    @Test func everyStartAttemptResolves() async throws {
        let base = URL(fileURLWithPath: "/tmp/collie-mitm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let run = base.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run.appendingPathComponent("terminals"), withIntermediateDirectories: true)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: ProtocolError.self) {
            _ = try await MitmProcess.start(tool: MitmTool(url: URL(fileURLWithPath: "/usr/bin/false")), addonSource: "",
                                            confdir: base.appendingPathComponent("network/mitm"), runDir: run,
                                            upstreamCA: { calls.withLock { $0 += 1 }; return .none })
        }
        #expect(calls.withLock { $0 } == 2)
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

    // MARK: map rules, through the real mitmdump and addon (COLLIE_E2E_MITM=1)

    static let realMitm = ProcessInfo.processInfo.environment["COLLIE_E2E_MITM"] != nil
        && MitmTool.locate(env: ProcessInfo.processInfo.environment) != nil

    private static func local(_ status: Int, _ body: String, id: String = MapRule.makeID(), enabled: Bool = true,
                              method: String? = nil, path: String? = "/x*", query: [String: String] = [:], delayMs: Int = 0) -> MapRule {
        MapRule(id: id, name: nil, enabled: enabled, match: .init(method: method, host: "127.0.0.1", path: path, query: query),
                action: .local(status: status, headers: [Header(name: "X-Mapped", value: "1")], bodyB64: Data(body.utf8).base64EncodedString()),
                delayMs: delayMs)
    }

    @Test(.enabled(if: realMitm)) func localRuleAnswersWithoutReachingServer() async throws {
        try await RealMitm.with([Self.local(418, "oi", id: "r418")]) { h in
            let (code, body, _) = try await h.curl("/x/1")
            #expect(code == 418 && body == "oi" && h.hits == 0)
            let res = try await h.event { if case .response(let r) = $0 { r.mappedBy != nil } else { false } }
            guard case .response(let r) = res else { return }
            #expect(r.mappedBy == "r418" && r.status == 418)
            let req = try await h.event { if case .request(let r) = $0 { r.id == res.id } else { false } }
            guard case .request(let q) = req else { return }
            #expect(q.mappedBy == "r418")
        }
    }

    @Test(.enabled(if: realMitm)) func dropRuleCutsConnection() async throws {
        let drop = MapRule(id: "cut", name: nil, enabled: true, match: .init(path: "/x*"), action: .drop)
        try await RealMitm.with([drop]) { h in
            let (code, _, _) = try await h.curl("/x")
            #expect(code == 0 && h.hits == 0)   // curl got no response at all
            let req = try await h.event { if case .request(let r) = $0 { r.mappedBy == "cut" } else { false } }
            _ = try await h.event { if case .error(let id, _, _) = $0 { id == req.id } else { false } }
        }
    }

    @Test(.enabled(if: realMitm)) func delayRuleWaits() async throws {
        try await RealMitm.with([Self.local(200, "slow", delayMs: 1500)]) { h in
            let (code, body, elapsed) = try await h.curl("/x")
            #expect(code == 200 && body == "slow" && elapsed >= .milliseconds(1500) && h.hits == 0)
        }
    }

    @Test(.enabled(if: realMitm)) func firstEnabledRuleWins() async throws {
        try await RealMitm.with([Self.local(401, "off", enabled: false), Self.local(402, "first"), Self.local(403, "second")]) { h in
            let (code, body, _) = try await h.curl("/x")
            #expect(code == 402 && body == "first")
        }
    }

    @Test(.enabled(if: realMitm)) func badRulesFileKeepsPreviousRules() async throws {
        try await RealMitm.with([Self.local(418, "oi")]) { h in
            #expect(try await h.curl("/x").0 == 418)
            try Data("{\"v\":1,\"rules\":[{\"bro".utf8).write(to: h.rulesFile)   // half a file, in place
            #expect(try await h.curl("/x").0 == 418)
            try Data(#"{"v":99,"rules":[]}"#.utf8).write(to: h.rulesFile)   // unknown version
            #expect(try await h.curl("/x").0 == 418)
            #expect(h.mitm.exited == nil)
        }
    }

    @Test(.enabled(if: realMitm)) func ruleReloadsOnMtimeChange() async throws {
        try await RealMitm.with([]) { h in
            #expect(try await h.curl("/x").0 == 200); #expect(h.hits == 1)
            try h.write([Self.local(418, "oi")])
            #expect(try await h.curl("/x").0 == 418); #expect(h.hits == 1)
            try h.write([])
            #expect(try await h.curl("/x").0 == 200); #expect(h.hits == 2)
        }
    }

    @Test(.enabled(if: realMitm)) func methodAndQueryMatching() async throws {
        try await RealMitm.with([Self.local(418, "oi", method: "get", query: ["a": "1", "b": "2"])]) { h in
            let any = try await h.curl("/x?b=2&c=3&a=1").0, missing = try await h.curl("/x?a=1").0
            let post = try await h.curl("/x?a=1&b=2", method: "POST").0
            #expect(any == 418 && missing == 200 && post == 200)
        }
    }

    @Test(.enabled(if: realMitm)) func unmatchedFlowHasNoMappedBy() async throws {
        try await RealMitm.with([Self.local(418, "oi")]) { h in
            let (code, body, _) = try await h.curl("/y")
            #expect(code == 200 && body == "real" && h.hits == 1)
            let res = try await h.event { if case .response = $0 { true } else { false } }
            guard case .response(let r) = res else { return }
            #expect(r.mappedBy == nil)
        }
    }
}

/// The real mitmdump with Collie's addon and a rules file, a local HTTP server counting its hits, and `curl` through
/// the proxy. Every addon line is decoded and kept.
private final class RealMitm: Sendable {
    let mitm: MitmProcess
    let rulesFile: URL
    let serverPort: Int
    private let count: URL
    private let events = OSAllocatedUnfairLock(initialState: [FlowEvent]())

    var hits: Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").count }

    private init(mitm: MitmProcess, rulesFile: URL, serverPort: Int, count: URL) {
        self.mitm = mitm; self.rulesFile = rulesFile; self.serverPort = serverPort; self.count = count
        Task { [events] in
            for await line in mitm.lines {
                mitm.consumed(line)
                if let e = FlowEvent.decode(line: line) { events.withLock { $0.append(e) } }
            }
        }
    }

    static func with(_ rules: [MapRule], _ body: (RealMitm) async throws -> Void) async throws {
        let base = URL(fileURLWithPath: "/tmp/collie-map-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let run = base.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run.appendingPathComponent("terminals"), withIntermediateDirectories: true)
        let rulesFile = base.appendingPathComponent("rules.json"), count = base.appendingPathComponent("hits")
        try MapRule.activeFile(rules).write(to: rulesFile, options: .atomic)
        let port = try MitmProcess.freePort()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-c", """
            import http.server, sys
            class H(http.server.BaseHTTPRequestHandler):
                def _hit(self):
                    open(sys.argv[2], "a").write("x")
                    b = b"real"; self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
                do_GET = do_POST = _hit
                def log_message(self, *a): pass
            http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
            """, "\(port)", count.path]
        try server.run()
        defer { server.terminate() }
        for _ in 0..<50 where !MitmProcess.listening(port: port) { try await Task.sleep(for: .milliseconds(100)) }
        let tool = MitmTool(url: MitmTool.locate(env: ProcessInfo.processInfo.environment)!)
        let m = try await MitmProcess.start(tool: tool, addonSource: AddonScript.source, confdir: base.appendingPathComponent("mitm"),
                                            runDir: run, rules: rulesFile)
        defer { m.stop() }
        try await body(RealMitm(mitm: m, rulesFile: rulesFile, serverPort: port, count: count))
    }

    func write(_ rules: [MapRule]) throws { try MapRule.activeFile(rules).write(to: rulesFile, options: .atomic) }

    /// (status, body, elapsed); status 0 when curl got no response.
    func curl(_ path: String, method: String = "GET") async throws -> (Int, String, Duration) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--noproxy", "", "-x", "http://127.0.0.1:\(mitm.port)", "-X", method, "--max-time", "10",
                       "-w", "\n%{http_code}", "http://127.0.0.1:\(serverPort)\(path)"]
        p.standardOutput = out
        let start = ContinuousClock.now
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let elapsed = ContinuousClock.now - start
        let text = String(decoding: data, as: UTF8.self)
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().joined(separator: "\n")
        return (Int(text.split(separator: "\n").last ?? "") ?? 0, body, elapsed)
    }

    /// The first addon event matching, waiting up to 5 s.
    func event(_ match: @escaping @Sendable (FlowEvent) -> Bool) async throws -> FlowEvent {
        for _ in 0..<50 {
            if let e = events.withLock({ $0.first(where: match) }) { return e }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("no matching addon event in \(events.withLock { $0 })")
        throw CancellationError()
    }
}
