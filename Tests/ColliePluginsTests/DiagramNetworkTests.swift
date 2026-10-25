import AppKit
import Foundation
import Testing
import WebKit
@testable import ColliePlugins

/// The Diagram panel never reaches the network: the hosts draw.io knows (fonts, its sites, GitHub, the M365 redirect)
/// are blocked as loads and cancelled as navigations or new windows. No request leaves the machine in these tests.
@MainActor @Suite(.serialized) struct DiagramNetworkTests {
    static let phoneHome = [
        "https://fonts.googleapis.com/css?family=Inter", "https://fonts.gstatic.com/s/inter/v1/a.woff2",
        "https://app.diagrams.net/", "https://viewer.diagrams.net/#M", "https://convert.diagrams.net/node/export",
        "https://api.github.com/repos/jgraph/drawio", "https://github.com/jgraph/drawio", "https://www.drawio.com/doc",
        "http://example.com/", "wss://app.diagrams.net/cache",
    ]

    final class Probe: NSObject, WKScriptMessageHandler {
        var result: [String]?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { result = m.body as? [String] }
    }

    @Test func editorURLStaysOffline() {
        let q = DiagramSchemeHandler.editorQuery
        #expect(q.contains("offline=1") && q.contains("stealth=1") && q.contains("pwa=0") && q.contains("embed=1") && q.contains("proto=json"))
        for p in ["enableSW", "dev=", "test="] { #expect(!q.contains(p), "\(p)") }
    }

    @Test func navigationsAndWindowsOnlyOnOwnScheme() {
        for u in Self.phoneHome + ["file:///etc/passwd", "data:text/html,x", "javascript:alert(1)"] {
            #expect(!DiagramPanel.allows(URL(string: u)), "\(u)")
        }
        #expect(DiagramPanel.allows(URL(string: "collie-diagram://app/index.html?embed=1")))
        #expect(DiagramPanel.allows(URL(string: "about:blank")))
    }

    @Test func pageRequestsToPhoneHomeHostsAreBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try String(data: JSONSerialization.data(withJSONObject: Self.phoneHome), encoding: .utf8)!
        // no-cors: an allowed request would resolve (opaque); only a blocked one rejects
        try Data("""
            <script>Promise.all(\(urls).map(u => u.startsWith('ws')
              ? new Promise(r => { const s = new WebSocket(u); s.onopen = () => r('open ' + u); s.onerror = () => r('blocked ' + u) })
              : fetch(u, {mode: 'no-cors'}).then(() => 'open ' + u, () => 'blocked ' + u)))
              .then(r => webkit.messageHandlers.probe.postMessage(r))</script>
            """.utf8).write(to: root.appendingPathComponent("probe.html"))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DiagramSchemeHandler(root: root), forURLScheme: DiagramSchemeHandler.scheme)
        config.userContentController.add(try await HTMLSnapshotter.ruleList())
        let probe = Probe()
        config.userContentController.add(probe, name: "probe")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        web.load(URLRequest(url: URL(string: "collie-diagram://app/probe.html")!))
        #expect(await pollUntil(15) { probe.result != nil })
        for line in probe.result ?? [] { #expect(line.hasPrefix("blocked "), "\(line)") }
        #expect(probe.result?.count == Self.phoneHome.count)
        config.userContentController.removeAllScriptMessageHandlers()
    }

    @Test func schemeServesHostPageAndBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        let h = DiagramSchemeHandler(root: root)
        let host = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-diagram://app/host.html")!))
        h.webView(WKWebView(), start: host)
        #expect(host.response?.statusCode == 200 && String(decoding: host.body, as: UTF8.self).contains("index.html?\(DiagramSchemeHandler.editorQuery)"))
        let idx = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-diagram://app/index.html")!))
        h.webView(WKWebView(), start: idx)
        #expect(idx.response?.statusCode == 200 && idx.body == Data("<html></html>".utf8))
        let out = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-diagram://app/../x")!))
        h.webView(WKWebView(), start: out)
        #expect(out.response?.statusCode == 404)
    }
}
