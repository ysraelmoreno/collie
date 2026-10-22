import AppKit
import Foundation
import Testing
import WebKit
import OrqCore
import OrqProtocol
@testable import OrqPlugins

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
        let t = serve(root, "orq-design://app/a_bg.wasm")
        #expect(t.response?.statusCode == 200)
        #expect(t.response?.value(forHTTPHeaderField: "Content-Type") == "application/wasm")
        #expect(t.body == Data([0, 0x61, 0x73, 0x6D]) && t.finished)
        let i = serve(root, "orq-design://app/index.html?webgl")
        #expect(i.response?.statusCode == 200 && i.response?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
    }

    @Test func schemeRejectsTraversal() throws {
        let root = try webRoot()
        for u in ["orq-design://app/../secret.txt", "orq-design://app/../../etc/passwd", "orq-design://app/%2e%2e/secret.txt",
                  "orq-design://app/%2E%2E%2Fsecret.txt", "orq-design://app/missing.js", "orq-design://other/index.html"] {
            let t = serve(root, u)
            #expect(t.response?.statusCode == 404, "\(u)")
            #expect(!String(decoding: t.body, as: UTF8.self).contains("secret"), "\(u)")
        }
    }

    @Test func schemeOnlyGet() throws {
        let root = try webRoot()
        for m in ["POST", "PUT", "DELETE"] {
            let t = serve(root, "orq-design://app/index.html", method: m)
            #expect(t.response?.statusCode == 405, "\(m)")
            #expect(t.body.isEmpty)
        }
    }

    @Test func designURLEncodesLink() throws {
        let link = "figcraft://join?host=127.0.0.1:47900&file=ab=c&token=x#y%z"
        let u = designURL(editLink: link)
        #expect(u.absoluteString.hasPrefix("orq-design://app/index.html?webgl#orq=1&join="))
        #expect(u.query == "webgl")
        #expect(designURL(editLink: link, webGPU: true).query == nil)
        let f = try #require(u.fragment(percentEncoded: true))
        let escaped = try #require(f.split(separator: "join=", maxSplits: 1).last)
        #expect(!escaped.contains("&") && !escaped.contains("#"))
        #expect(String(escaped).removingPercentEncoding == link)
    }

    /// `orq=1` before `join=` (the link takes the rest of the fragment): the page joins without its dialog.
    @Test func designPanelURLRequestsAutoJoin() throws {
        let f = try #require(designURL(editLink: "figcraft://join?host=h&orq=0").fragment(percentEncoded: true))
        #expect(f.hasPrefix("orq=1&join=figcraft%3A%2F%2Fjoin%3Fhost%3Dh%26orq%3D0"))
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

    /// Diagnostics, gated by `ORQ_GPU_MEASURE=1`: prints the probe outcome and figcraft's backend line with and without `?webgl`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORQ_GPU_MEASURE"] == "1")) func measureBackends() async throws {
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
            cfg.setURLSchemeHandler(DesignSchemeHandler(root: root), forURLScheme: "orq-design")
            cfg.userContentController.add(h, name: "log")
            cfg.userContentController.addUserScript(WKUserScript(source: "for (const k of ['log','info','warn','error']) { const o = console[k]; console[k] = (...a) => { window.webkit.messageHandlers.log.postMessage(a.join(' ')); o.apply(console, a) } }", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
            w.load(URLRequest(url: URL(string: "orq-design://app/index.html\(q)")!))
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
        #expect(GPUProbe.envOverride(["ORQ_DESIGN_GPU": "webgl"]) == false)
        #expect(GPUProbe.envOverride(["ORQ_DESIGN_GPU": "webgpu"]) == true)
        #expect(GPUProbe.envOverride(["ORQ_DESIGN_GPU": "x"]) == nil)
        #expect(GPUProbe.envOverride(["ORQ_DESIGN_GPU": " WebGL "]) == false)
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
}
