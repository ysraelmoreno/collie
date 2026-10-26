import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

@MainActor @Suite(.serialized) struct DesignPanelTests {
    /// What the handler sends back for one request.
    final class FakeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: HTTPURLResponse?
        var body = Data()
        var finished = false
        var error: (any Error)?
        init(_ r: URLRequest) { request = r }
        func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
        func didReceive(_ data: Data) { body.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: any Error) { self.error = error }
    }

    /// A web folder with a wasm, an index, and a secret one level above it.
    func webRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("design-\(UUID().uuidString)")
        let web = base.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data([0, 0x61, 0x73, 0x6D]).write(to: web.appendingPathComponent("a_bg.wasm"))
        try Data("<html></html>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: base.appendingPathComponent("secret.txt"))
        return web
    }

    func serve(_ root: URL, _ url: String, method: String = "GET") -> FakeTask {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        let t = FakeTask(r)
        DesignSchemeHandler(root: root).webView(WKWebView(), start: t)
        return t
    }

    @Test func schemeServesWasmWithMime() throws {
        let root = try webRoot()
        let t = serve(root, "collie-design://app/a_bg.wasm")
        #expect(t.response?.statusCode == 200)
        #expect(t.response?.value(forHTTPHeaderField: "Content-Type") == "application/wasm")
        #expect(t.body == Data([0, 0x61, 0x73, 0x6D]) && t.finished)
        let i = serve(root, "collie-design://app/index.html?webgl")
        #expect(i.response?.statusCode == 200 && i.response?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
    }

    @Test func schemeRejectsTraversal() throws {
        let root = try webRoot()
        for u in ["collie-design://app/../secret.txt", "collie-design://app/../../etc/passwd", "collie-design://app/%2e%2e/secret.txt",
                  "collie-design://app/%2E%2E%2Fsecret.txt", "collie-design://app/missing.js", "collie-design://other/index.html"] {
            let t = serve(root, u)
            #expect(t.response?.statusCode == 404, "\(u)")
            #expect(!String(decoding: t.body, as: UTF8.self).contains("secret"), "\(u)")
        }
    }

    @Test func schemeOnlyGet() throws {
        let root = try webRoot()
        for m in ["POST", "PUT", "DELETE"] {
            let t = serve(root, "collie-design://app/index.html", method: m)
            #expect(t.response?.statusCode == 405, "\(m)")
            #expect(t.body.isEmpty)
        }
    }

    @Test func designURLEncodesLink() throws {
        let link = "figcraft://join?host=127.0.0.1:47900&file=ab=c&token=x#y%z"
        let u = designURL(editLink: link)
        #expect(u.absoluteString.hasPrefix("collie-design://app/index.html?webgl#collie=1&join="))
        #expect(u.query == "webgl")
        #expect(designURL(editLink: link, webGPU: true).query == nil)
        let f = try #require(u.fragment(percentEncoded: true))
        let escaped = try #require(f.split(separator: "join=", maxSplits: 1).last)
        #expect(!escaped.contains("&") && !escaped.contains("#"))
        #expect(String(escaped).removingPercentEncoding == link)
    }

    /// `collie=1` before `join=` (the link takes the rest of the fragment): the page joins without its dialog.
    @Test func designPanelURLRequestsAutoJoin() throws {
        let f = try #require(designURL(editLink: "figcraft://join?host=h&collie=0").fragment(percentEncoded: true))
        #expect(f.hasPrefix("collie=1&join=figcraft%3A%2F%2Fjoin%3Fhost%3Dh%26collie%3D0"))
    }

    @Test func panelRegistersAndRefusesCommands() async throws {
        PluginViews.register("design", DesignPanel.self)
        let panel = Panel(id: UUID(), name: "d", pluginId: "design", placement: .canvas, state: ["file": .string("f")])
        let host = PanelHostContext(panel: panel, root: URL(fileURLWithPath: NSTemporaryDirectory()), workspaceId: nil,
                                    call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let v = try #require(PluginViews.make(panel, host: host))
        #expect(v is DesignPanel)
        do { _ = try await v.handle("design.run", [:]); Issue.record("no throw") } catch { #expect(error.code == .unavailable) }
        v.close()
        #expect((v as? DesignPanel)?.webView == nil)
    }

    @Test func probeReturnsQuickly() async {
        let t = ContinuousClock().now
        _ = await GPUProbe.probe(deadline: .seconds(2))
        #expect(ContinuousClock().now - t <= .milliseconds(2500))
    }

    /// Two concurrent first calls share one probe.
    @Test func concurrentCallsShareOneProbe() async {
        guard GPUProbe.envOverride() == nil else { return }
        let saved = GPUProbe.task; defer { GPUProbe.task = saved }
        GPUProbe.task = nil
        let n = GPUProbe.probes
        async let a = GPUProbe.webGPUAvailable()
        async let b = GPUProbe.webGPUAvailable()
        let r = await (a, b)
        #expect(r.0 == r.1 && GPUProbe.probes == n + 1)
    }

    /// Diagnostics, gated by `COLLIE_GPU_MEASURE=1`: prints the probe outcome and figcraft's backend line with and without `?webgl`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_GPU_MEASURE"] == "1")) func measureBackends() async throws {
        let p = await GPUProbe.probe(deadline: .seconds(2))
        print("MEASURE probe ok=\(p.ok) outcome=\(p.outcome)")
        final class H: NSObject, WKScriptMessageHandler {
            var lines: [String] = []
            func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { lines.append("\(m.body)") }
        }
        let root = URL(fileURLWithPath: "vendor/figcraft/web")
        for q in ["", "?webgl"] {
            let h = H(), cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            cfg.setURLSchemeHandler(DesignSchemeHandler(root: root), forURLScheme: "collie-design")
            cfg.userContentController.add(h, name: "log")
            cfg.userContentController.addUserScript(WKUserScript(source: "for (const k of ['log','info','warn','error']) { const o = console[k]; console[k] = (...a) => { window.webkit.messageHandlers.log.postMessage(a.join(' ')); o.apply(console, a) } }", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
            w.load(URLRequest(url: URL(string: "collie-design://app/index.html\(q)")!))
            for _ in 0..<160 where !h.lines.contains(where: { $0.contains("wgpu backend") }) { try await Task.sleep(for: .milliseconds(100)) }
            print("MEASURE query[\(q)]:", h.lines.filter { $0.contains("wgpu backend") })
        }
    }

    @Test func probeFallsBackToWebGL() async throws {
        let saved = GPUProbe.task; defer { GPUProbe.task = saved }
        GPUProbe.memoize(false)
        if GPUProbe.envOverride() == nil { #expect(await GPUProbe.webGPUAvailable() == false) }
        #expect(designURL(editLink: "figcraft://join?x=1", webGPU: false).query == "webgl")
    }

    @Test func envOverride() {
        #expect(GPUProbe.envOverride(["COLLIE_DESIGN_GPU": "webgl"]) == false)
        #expect(GPUProbe.envOverride(["COLLIE_DESIGN_GPU": "webgpu"]) == true)
        #expect(GPUProbe.envOverride(["COLLIE_DESIGN_GPU": "x"]) == nil)
        #expect(GPUProbe.envOverride(["COLLIE_DESIGN_GPU": " WebGL "]) == false)
        #expect(GPUProbe.envOverride([:]) == nil)
    }

    /// A page without `?webgl` that writes the failure text reloads once with `?webgl` and memoizes `false`.
    @Test func startFailureReloadsWithWebGL() async throws {
        let root = try webRoot()
        try Data("""
            <html><body><div id="loading"></div><script>
            if (!location.search.includes("webgl")) setTimeout(() => { document.getElementById("loading").innerHTML = "<p>FigCraft failed to start: x</p>" }, 50)
            </script></body></html>
            """.utf8).write(to: root.appendingPathComponent("index.html"))
        let saved = GPUProbe.task
        defer { GPUProbe.task = saved }
        GPUProbe.memoize(true)
        let panel = Panel(id: UUID(), name: "d", pluginId: "design", placement: .canvas, state: ["file": .string("f")])
        let host = PanelHostContext(panel: panel, root: root, workspaceId: nil, call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let v = DesignPanel(panel: panel, host: host, webRoot: root)
        let web = try #require(v.webView)
        web.load(URLRequest(url: designURL(editLink: "figcraft://join?x=1", webGPU: true)))
        for _ in 0..<100 where web.url?.query != "webgl" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(web.url?.query == "webgl")
        #expect(await GPUProbe.task?.value == false)
        v.close()
    }

    /// The downloaded TTFs reach the page's FigCraft (`wasmBindings.collie_add_font`, patch 0005) once it starts, and on
    /// `fonts.changed` only the new ones; never a symlink, a symlinked folder or a file over 20 MiB.
    @Test func pushesDownloadedFontsToTheEditor() async throws {
        let root = try webRoot()
        try Data("""
            <html><body><script>window.got = [];
            setTimeout(() => { window.wasmBindings = { collie_add_font: b => { window.got.push(b.length + ":" + b[0]); return true } };
            dispatchEvent(new CustomEvent("TrunkApplicationStarted")) }, 100)</script></body></html>
            """.utf8).write(to: root.appendingPathComponent("index.html"))
        let collie = root.deletingLastPathComponent().appendingPathComponent("collie")
        let fm = FileManager.default
        let ttf = collie.appendingPathComponent("fonts/Inter/ttf")
        try fm.createDirectory(at: ttf, withIntermediateDirectories: true)
        try Data([7, 1, 2]).write(to: ttf.appendingPathComponent("normal-400-0.ttf"))
        try Data([9]).write(to: root.appendingPathComponent("outside.ttf"))
        try fm.createSymbolicLink(at: ttf.appendingPathComponent("link.ttf"), withDestinationURL: root.appendingPathComponent("outside.ttf"))
        fm.createFile(atPath: ttf.appendingPathComponent("big.ttf").path, contents: nil)
        let h = try FileHandle(forWritingTo: ttf.appendingPathComponent("big.ttf")); try h.truncate(atOffset: UInt64(20 << 20) + 1); try h.close()
        try Data("x".utf8).write(to: ttf.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: collie.appendingPathComponent("fonts/Evil"), withDestinationURL: collie.appendingPathComponent("fonts/Inter"))
        let panel = Panel(id: UUID(), name: "d", pluginId: "design", placement: .canvas, state: ["file": .string("f")])
        let host = PanelHostContext(panel: panel, root: collie, workspaceId: nil, call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let v = DesignPanel(panel: panel, host: host, webRoot: root)
        defer { v.close() }
        let web = try #require(v.webView)
        func got() async -> String { ((try? await web.evaluateJavaScript("window.got ? window.got.join(',') : ''")) as? String) ?? "" }
        web.load(URLRequest(url: URL(string: "collie-design://app/index.html")!))
        for _ in 0..<100 where await got().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await got() == "3:7")
        try Data([5, 5]).write(to: ttf.appendingPathComponent("normal-700-1.ttf"))
        v.receive(event: "fonts.changed", payload: .object([:]))
        for _ in 0..<100 where await got() == "3:7" { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await got() == "3:7,2:5")
    }

    /// A font the editor refused (`collie_add_font` false) is tried once more on the next push, then left alone.
    @Test func retriesARefusedFontOnce() async throws {
        let root = try webRoot()
        try Data("""
            <html><body><script>window.got = [];
            window.wasmBindings = { collie_add_font: b => { window.got.push(b[0]); return b[0] !== 9 } }</script></body></html>
            """.utf8).write(to: root.appendingPathComponent("index.html"))
        let collie = root.deletingLastPathComponent().appendingPathComponent("collie")
        let ttf = collie.appendingPathComponent("fonts/Inter/ttf")
        try FileManager.default.createDirectory(at: ttf, withIntermediateDirectories: true)
        try Data([7]).write(to: ttf.appendingPathComponent("a.ttf"))
        try Data([9]).write(to: ttf.appendingPathComponent("b.ttf"))
        let panel = Panel(id: UUID(), name: "d", pluginId: "design", placement: .canvas, state: ["file": .string("f")])
        let host = PanelHostContext(panel: panel, root: collie, workspaceId: nil, call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let v = DesignPanel(panel: panel, host: host, webRoot: root)
        defer { v.close() }
        let web = try #require(v.webView)
        func got() async -> String { ((try? await web.evaluateJavaScript("window.got ? window.got.join(',') : ''")) as? String) ?? "" }
        web.load(URLRequest(url: URL(string: "collie-design://app/index.html")!))
        for _ in 0..<100 where await got() != "7,9" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await got() == "7,9")
        for _ in 0..<2 {
            v.receive(event: "fonts.changed", payload: .object([:]))
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(await got() == "7,9,9")   // retried once, never again
    }

    /// The figcraft web build exports `collie_add_font` (patch 0005; rebuild with scripts/build-figcraft.sh).
    @Test func webBuildExportsAddFont() throws {
        guard let web = DesignPanel.webDirectory else { return }   // not built here
        let js = try FileManager.default.contentsOfDirectory(atPath: web.path).filter { $0.hasSuffix(".js") }
        #expect(try js.contains { try String(contentsOf: web.appendingPathComponent($0), encoding: .utf8).contains("collie_add_font") }, "\(js)")
    }
}
