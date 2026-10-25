import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins
@testable import CollieDaemonKit

/// The Prévia against a temp project (no app): it serves the page and its folder, nothing else, stays offline, reloads on
/// change (once per burst, keeping the scroll), shows artifacts, sets the theme and keeps the page's errors.
@MainActor @Suite(.serialized) struct PreviewPanelTests {
    func project() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("preview-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return DiagramFile.real(u)   // /private/var, as the panel resolves it
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
        #expect(await pollUntil(1.5) { await text(panel) == "dois" })
        // in place (same inode)
        try Data("<body>tres</body>".utf8).write(to: root.appendingPathComponent("p/a.html"))
        #expect(await pollUntil(1.5) { await text(panel) == "tres" })
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

    // MARK: agent commands (Task 3)

    @Test func getReturnsFileAndErrors() async throws {
        let root = try project()
        try put("g/e.html", root, #"<body><script>throw new Error("falhou")</script></body>"#)
        let (panel, w) = mount(root: root, state: ["file": .string("g/e.html")])
        defer { panel.close(); w.close() }
        #expect(await pollUntil(10) { !panel.errors.isEmpty })
        guard case .object(let o) = try await panel.handle("preview.get", [:]) else { Issue.record("not an object"); return }
        #expect(o["file"] == .string("g/e.html") && o["url"] == .string("collie-preview://app/g/e.html"), "\(o)")
        guard case .array(let es)? = o["errors"], case .string(let e)? = es.first else { Issue.record("\(o)"); return }
        #expect(e.contains("falhou"))
    }

    func shot(_ panel: PreviewPanel, _ args: [String: JSONValue]) async throws -> (Data, Double, Double) {
        guard case .object(let o) = try await panel.handle("preview.screenshot", args), case .string(let path)? = o["path"],
              case .number(let width)? = o["width"], case .number(let height)? = o["height"] else { throw ProtocolError(code: .internal, message: "bad reply") }
        #expect(path.contains("/screens/\(panel.panel.id.uuidString)-"))
        return (try Data(contentsOf: URL(fileURLWithPath: path)), width, height)
    }

    @Test func screenshotIsPNG() async throws {
        let root = try project()
        try put("s.html", root, "<body style='background:#c00'>s</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("s.html")])
        defer { panel.close(); w.close() }
        let (png, width, _) = try await shot(panel, [:])
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let web = try #require(panel.webView)
        #expect(abs(width - web.bounds.width * w.backingScaleFactor) < 1, "\(width) vs \(web.bounds.width)")
    }

    @Test func screenshotFullPage() async throws {
        let root = try project()
        try put("f.html", root, #"<body style="margin:0"><div style="height:3000px;background:linear-gradient(#fff,#00f)">f</div></body>"#)
        let (panel, w) = mount(root: root, state: ["file": .string("f.html")])
        defer { panel.close(); w.close() }
        let (_, _, height) = try await shot(panel, ["full-page": .bool(true)])
        #expect(height >= 3000 * w.backingScaleFactor, "\(height)")
    }

    /// `artifact new`'s pages run in a Prévia with no page error, and their script did its part.
    @Test func templatesRunWithoutErrors() async throws {
        let root = try project()
        for kind in ArtifactTemplates.Kind.allCases {
            try put("\(kind.rawValue).html", root, ArtifactTemplates.render(kind, title: "T", tokensCSS: ArtifactTemplates.tokensCSS(variables: nil)))
            let (panel, w) = mount(root: root, state: ["file": .string("\(kind.rawValue).html")])
            defer { panel.close(); w.close() }
            #expect(await pollUntil(10) { panel.loads > 0 }, "\(kind)")
            try await Task.sleep(for: .milliseconds(200))
            #expect(panel.errors.isEmpty, "\(kind): \(panel.errors)")
            let check = switch kind {
            case .deck: "document.getElementById('counter').textContent === '1 / 4'"
            case .dashboard: "document.querySelectorAll('#chart rect').length === 6 && document.querySelectorAll('#rows tr').length === 6"
            case .doc: "document.querySelectorAll('#toc a').length === 5"
            case .prototype: "document.querySelectorAll('#list .item').length === 3"
            }
            #expect(await js(panel, check) as? Bool == true, "\(kind)")
        }
    }

    // MARK: out of the panel (Task 5)

    @Test func saveArgsUsesPageFolder() throws {
        let root = try project()
        try put("docs/pages/d/index.html", root, "<body>x</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("docs/pages/d/index.html")])
        defer { panel.close(); w.close() }
        let a = panel.saveArgs()
        #expect(a["path"] == .string(root.path + "/docs/pages/d/index.html") && a["root"] == .string(root.path + "/docs/pages/d"), "\(a)")
        #expect(a["title"] == .string("index.html"))
    }

    @Test func saveArgsNoRootAtProjectRoot() throws {
        let root = try project()
        try put("a.html", root, "<body>x</body>")
        let (panel, w) = mount(root: root, state: ["file": .string("a.html")])
        defer { panel.close(); w.close() }
        let a = panel.saveArgs()
        #expect(a["path"] == .string(root.path + "/a.html") && a["root"] == nil, "\(a)")
    }

    @Test func saveArgsTitleFromPage() throws {
        let root = try project()
        try put("p/t.html", root, "<html><head><TITLE>  Meu título\n</TITLE></head><body>x</body></html>")
        let (panel, w) = mount(root: root, state: ["file": .string("p/t.html")])
        defer { panel.close(); w.close() }
        #expect(panel.saveArgs()["title"] == .string("Meu título"))
    }

    @Test func artifactModeHidesSaveButtons() throws {
        let root = try project()
        try put("a.html", root, "<body>x</body>")
        let (filePanel, w1) = mount(root: root, state: ["file": .string("a.html")])
        defer { filePanel.close(); w1.close() }
        #expect(filePanel.header.canSave)
        let (artPanel, w2) = mount(root: root, state: ["artifact": .string(UUID().uuidString.lowercased())])
        defer { artPanel.close(); w2.close() }
        #expect(!artPanel.header.canSave)
    }

    /// Salvar como artifact, then Importar no Design reuses that artifact (no second add) and opens a Design panel on
    /// the imported file.
    @Test func saveThenImportOpensDesign() async throws {
        let root = try project()
        try put("v/index.html", root, "<title>Vendas</title><body>x</body>")
        let calls = Calls()
        let (panel, w) = mount(root: root, state: ["file": .string("v/index.html")]) { cmd, args throws(ProtocolError) in
            await calls.add(cmd, args)
            switch cmd {
            case "artifact.add": return .object(["id": .string("a1"), "importing": .bool(true)])
            case "artifact.import": return .object(["artifact": .string("a1"), "file": .string("Vendas"), "warnings": .array([])])
            default: return .object([:])
            }
        }
        defer { panel.close(); w.close() }
        await panel.save()
        #expect(panel.header.note == "Salvo como artifact" && panel.saved == "a1")
        await panel.importToDesign()
        let seen = await calls.all
        #expect(seen.map(\.0) == ["artifact.add", "artifact.import", "panel.open"], "\(seen.map(\.0))")
        #expect(seen.last?.1["plugin"] == .string("design") && seen.last?.1["file"] == .string("Vendas"))
        #expect(panel.header.error == nil && !panel.header.busy)
    }
    actor Calls {
        var all: [(String, [String: JSONValue])] = []
        func add(_ c: String, _ a: [String: JSONValue]) { all.append((c, a)) }
    }
}
