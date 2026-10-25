import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// The Prévia against a temp project (no app): it serves the page and its folder, nothing else, stays offline, reloads on
/// change (once per burst, keeping the scroll), shows artifacts, sets the theme and keeps the page's errors.
@MainActor @Suite(.serialized) struct PreviewPanelTests {
    func project() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("preview-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }
    func put(_ rel: String, _ root: URL, _ text: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u, options: .atomic)
    }
    func mount(root: URL, state extra: [String: JSONValue], dataRoot: URL? = nil,
               call: @escaping PanelHostContext.Call = { _, _ throws(ProtocolError) in .null }) -> (PreviewPanel, NSWindow) {
        var state: [String: JSONValue] = ["root": .string(root.path)]
        state.merge(extra) { _, b in b }
        let p = Panel(id: UUID(), name: "previa", pluginId: "preview", placement: .canvas, state: state)
        let host = PanelHostContext(panel: p, root: dataRoot ?? root, workspaceId: nil, call: call, emit: { _, _ in })
        let panel = PreviewPanel(panel: p, host: host)
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        panel.view.frame = w.contentView!.bounds
        w.contentView!.addSubview(panel.view)
        return (panel, w)
    }
    func js(_ panel: PreviewPanel, _ expr: String) async -> Any? {
        try? await panel.webView?.callAsyncJavaScript("return \(expr)", contentWorld: .page)
    }
    func text(_ panel: PreviewPanel) async -> String { (await js(panel, "document.body ? document.body.innerText : ''") as? String) ?? "" }

    @Test func servesPageAndSiblings() async throws {
        let root = try project()
        try put("docs/pages/d/index.html", root, #"<link rel="stylesheet" href="app.css"><body><p>oi</p></body>"#)
        try put("docs/pages/d/app.css", root, "body { color: rgb(1, 2, 3) }")
        let (panel, w) = mount(root: root, state: ["file": .string("docs/pages/d/index.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { await js(panel, "getComputedStyle(document.body).color") as? String == "rgb(1, 2, 3)" })
        let h = PreviewSchemeHandler(root: root)
        let t = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-preview://app/docs/pages/d/app.css")!))
        h.webView(WKWebView(), start: t)
        #expect(t.response?.statusCode == 200 && t.response?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/css") == true)
        #expect(String(decoding: t.body, as: UTF8.self).contains("rgb(1, 2, 3)"))
    }

    @Test func dotPathIs404() throws {
        let root = try project()
        try put(".env", root, "SECRET=1"); try put(".git/config", root, "x"); try put("a.html", root, "ok")
        let h = PreviewSchemeHandler(root: root)
        for path in [".env", ".git/config", "%2e%2e/%2e%2e/etc/hosts", "missing.html"] {
            let t = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-preview://app/\(path)")!))
            h.webView(WKWebView(), start: t)
            #expect(t.response?.statusCode == 404 && t.body.isEmpty, "\(path)")
        }
        let other = DesignPanelTests.FakeTask(URLRequest(url: URL(string: "collie-preview://elsewhere/a.html")!))
        h.webView(WKWebView(), start: other)
        #expect(other.response?.statusCode == 404)
    }

    @Test func noNetwork() async throws {
        let root = try project()
        try put("n.html", root, """
            <body><img src="http://example.com/x.png"><script>
            window.net = Promise.all([
              fetch("https://example.com", {mode: "no-cors"}).then(() => "open fetch", () => "blocked fetch"),
              new Promise(r => { const s = new WebSocket("wss://example.com"); s.onopen = () => r("open ws"); s.onerror = () => r("blocked ws") }),
              Promise.resolve(typeof RTCPeerConnection === "undefined" && typeof webkitRTCPeerConnection === "undefined" ? "blocked rtc" : "open rtc"),
            ]);
            </script></body>
            """)
        let (panel, w) = mount(root: root, state: ["file": .string("n.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { panel.loads > 0 })
        let r = try await panel.webView?.callAsyncJavaScript("return await window.net", contentWorld: .page) as? [String]
        #expect(r == ["blocked fetch", "blocked ws", "blocked rtc"], "\(String(describing: r))")
    }

    @Test func reloadsOnWriteWithin1s() async throws {
        let root = try project()
        try put("p/a.html", root, "<body>um</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("p/a.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { await text(panel) == "um" })
        try put("p/a.html", root, "<body>dois</body>")
        #expect(await pollUntil(1) { await text(panel) == "dois" })
        // in place (same inode)
        try Data("<body>tres</body>".utf8).write(to: root.appendingPathComponent("p/a.html"))
        #expect(await pollUntil(1) { await text(panel) == "tres" })
    }

    @Test func burstReloadsOnceKeepsScroll() async throws {
        let root = try project()
        func page(_ n: Int) -> String { #"<body style="margin:0"><div style="height:3000px">v\#(n)</div></body>"# }
        try put("b.html", root, page(0))
        let (panel, w) = mount(root: root, state: ["file": .string("b.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { panel.loads == 1 })
        _ = await js(panel, "(window.scrollTo(0, 500), window.scrollY)")
        #expect(await pollUntil(2) { await js(panel, "window.scrollY") as? Double == 500 })
        for i in 1...5 {
            if i == 3 { try Data("<body>parcial".utf8).write(to: root.appendingPathComponent("b.html")) }   // a partial file in between
            try put("b.html", root, page(i))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await pollUntil(1.5) { await text(panel) == "v5" })
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.loads == 2)
        #expect(await pollUntil(1) { await js(panel, "window.scrollY") as? Double == 500 })
    }

    @Test func deletedThenRecreated() async throws {
        let root = try project()
        try put("d/x.html", root, "<body>antes</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("d/x.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { await text(panel) == "antes" })
        try FileManager.default.removeItem(at: root.appendingPathComponent("d/x.html"))
        #expect(await pollUntil(1.5) { panel.status == "Arquivo removido" })
        #expect(await text(panel) == "antes")   // the last render stays
        try put("d/x.html", root, "<body>depois</body>")
        #expect(await pollUntil(1.5) { await text(panel) == "depois" })
        #expect(panel.status == nil)
    }

    @Test func artifactModeLoadsCollieArtifact() async throws {
        let root = try project(), data = try project(), id = UUID().uuidString.lowercased()
        try put("artifacts/\(id)/source.html", data, "<body>artefato</body>")
        let (panel, w) = mount(root: root, state: ["artifact": .string(id)], dataRoot: data) { cmd, args throws(ProtocolError) in
            guard cmd == "artifact.get", args["id"] == .string(id) else { throw ProtocolError(code: .notFound, message: cmd) }
            return .object(["id": .string(id), "url": .string("collie-artifact://app/\(id)/source.html")])
        }
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { await text(panel) == "artefato" })
        #expect(panel.webView?.url?.scheme == "collie-artifact")
    }

    @Test func themeToggleSetsDataTheme() async throws {
        let root = try project()
        try put("t.html", root, "<body>t</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("t.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { panel.loads == 1 })
        panel.setTheme("dark")
        #expect(await pollUntil(2) { await js(panel, "document.documentElement.dataset.theme") as? String == "dark" })
        panel.reload(keepScroll: true)
        #expect(await pollUntil(5) { panel.loads == 2 })
        #expect(await pollUntil(2) { await js(panel, "document.documentElement.dataset.theme") as? String == "dark" })
        panel.setTheme(nil)
        #expect(await pollUntil(2) { await js(panel, "document.documentElement.hasAttribute('data-theme')") as? Bool == false })
    }

    @Test func errorsCaptured() async throws {
        let root = try project()
        try put("e.html", root, #"<body><script>Promise.reject(new Error("rejeitado")); throw new Error("boom")</script></body>"#)
        let (panel, w) = mount(root: root, state: ["file": .string("e.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { panel.errors.contains { $0.contains("boom") } && panel.errors.contains { $0.contains("rejeitado") } }, "\(panel.errors)")
    }
}
