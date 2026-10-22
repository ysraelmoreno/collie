import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// Real WKWebView, pages from `loadHTMLString` (no network). Generous waits: the machine running these is loaded.
@MainActor @Suite(.serialized) struct BrowserAutomationTests {
    final class Events: @unchecked Sendable {   // written from emit on the main actor only
        var all: [(String, JSONValue)] = []
    }

    func browser(_ html: String, storage: StorageScope = .global, events: Events = Events(),
                 root: URL = FileManager.default.temporaryDirectory) async throws -> BrowserPanel {
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight,
                          state: ["storage": .string(storage.rawValue)])
        let host = PanelHostContext(panel: panel, root: root, workspaceId: nil, call: { _, _ in .null }) { n, p in
            MainActor.assumeIsolated { events.all.append((n, p)) }
        }
        let b = BrowserPanel(panel: panel, host: host)
        try await b.load(html: html)
        return b
    }

    func run(_ b: BrowserPanel, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        guard case .object(let o) = try await b.handle("browser.\(cmd)", args) else { Issue.record("not an object"); return [:] }
        return o
    }

    func eval(_ b: BrowserPanel, _ js: String) async throws -> JSONValue? { try await run(b, "eval", ["js": .string(js)])["value"] }

    func output(_ o: [String: JSONValue]) -> String { if case .string(let s)? = o["output"] { return s }; return "" }

    /// The ref on the snapshot line containing `needle`.
    func ref(_ snapshot: String, _ needle: String) -> String? {
        guard let line = snapshot.split(separator: "\n").first(where: { $0.contains(needle) }),
              let r = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else { return nil }
        return String(line[r].dropFirst(5).dropLast())
    }

    func until(_ seconds: Double = 30, _ ok: () async throws -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if try await ok() { return true }; try await Task.sleep(for: .milliseconds(100)) }
        return false
    }

    @Test func snapshotListsInteractiveElementsWithRefs() async throws {
        let b = try await browser("""
            <h1>Title</h1><p>Some text</p><button>Go</button><a href="/x">Link here</a>
            <label>Email <input id="e"></label><div style="display:none"><button>Hidden</button></div>
            """)
        defer { b.close() }
        let s1 = output(try await run(b, "snapshot"))
        #expect(s1.contains(#"- heading "Title""#))
        #expect(s1.contains(#"- text "Some text""#))
        #expect(ref(s1, #"- button "Go""#) != nil)
        #expect(ref(s1, #"- link "Link here""#) != nil)
        #expect(ref(s1, #"- textbox "Email""#) != nil)
        #expect(!s1.contains("Hidden"))
        let s2 = output(try await run(b, "snapshot"))
        #expect(s1 == s2)   // same DOM → same refs
    }

    @Test func clickFiresHandler() async throws {
        let b = try await browser(#"<script>window.n = 0</script><button onclick="n++">Inc</button>"#)
        defer { b.close() }
        let r = try #require(ref(output(try await run(b, "snapshot")), "Inc"))
        _ = try await run(b, "click", ["ref": .string(r)])
        _ = try await run(b, "click", ["ref": .string(r)])
        #expect(try await eval(b, "n") == .number(2))
    }

    @Test func fillSetsValueAndFiresInput() async throws {
        let b = try await browser(#"<script>window.seen = []</script><input aria-label="Name" oninput="seen.push('input:' + this.value)" onchange="seen.push('change')">"#)
        defer { b.close() }
        let r = try #require(ref(output(try await run(b, "snapshot")), "Name"))
        _ = try await run(b, "fill", ["ref": .string(r), "text": .string("Ada")])
        #expect(try await eval(b, "document.querySelector('input').value") == .string("Ada"))
        #expect(try await eval(b, "seen") == .array([.string("input:Ada"), .string("change")]))
        #expect(output(try await run(b, "snapshot")).contains(#"value="Ada""#))
    }

    @Test func typeAndKeyEnterSubmitsForm() async throws {
        let b = try await browser(#"<form onsubmit="event.preventDefault(); window.sent = this.q.value"><input name="q" aria-label="Q"></form>"#)
        defer { b.close() }
        let r = try #require(ref(output(try await run(b, "snapshot")), "Q"))
        _ = try await run(b, "fill", ["ref": .string(r), "text": .string("ab")])
        _ = try await run(b, "type", ["text": .string("cd")])
        _ = try await run(b, "key", ["key": .string("Enter")])
        #expect(try await eval(b, "window.sent") == .string("abcd"))
    }

    @Test func waitForTextAppears() async throws {
        let b = try await browser(#"<script>setTimeout(() => document.body.append('Ready now'), 300)</script>"#)
        defer { b.close() }
        let r = try await run(b, "wait", ["text": .string("Ready now"), "timeout": .number(20)])
        #expect(r["found"] == .bool(true))
        do { _ = try await run(b, "wait", ["selector": .string("#never"), "timeout": .number(1)]); Issue.record("expected timeout") }
        catch let e as ProtocolError { #expect(e.code == .timeout) }
    }

    @Test func snapshotIsBounded() async throws {
        let b = try await browser("""
            <body><script>for (let i = 0; i < 50000; i++) { const x = document.createElement('button');
              x.textContent = 'Button number ' + i + ' "quoted" / slashed'; document.body.append(x) }</script>
            """)
        defer { b.close() }
        let raw = try await b.handle("browser.snapshot", [:])
        #expect(try JSONEncoder().encode(raw).count <= 1 << 20)
        guard case .object(let o) = raw else { Issue.record("not an object"); return }
        #expect(o["truncated"] == .bool(true))
        #expect(output(o).hasPrefix("- button"))
    }

    @Test func consoleRingKeepsLast500() async throws {
        let events = Events()
        let b = try await browser("<p>x</p>", events: events)
        defer { b.close() }
        _ = try await eval(b, "for (let i = 0; i < 600; i++) console.log('line', i)")
        #expect(try await until { b.consoleLines.last == "[log] line 599" })
        let lines = output(try await run(b, "console", ["lines": .number(500)])).split(separator: "\n")
        #expect(lines.count == 500)
        #expect(lines.first == "[log] line 100")
        #expect(lines.last == "[log] line 599")
        #expect(output(try await run(b, "console")).split(separator: "\n").count == 100)
        #expect(events.all.filter { $0.0 == "browser.console" }.count <= 10)   // rate limited
    }

    @Test func unknownRefIsNotFound() async throws {
        let b = try await browser("<button>x</button>")
        defer { b.close() }
        do { _ = try await run(b, "click", ["ref": .string("e999")]); Issue.record("expected notFound") }
        catch let e as ProtocolError {
            #expect(e.code == .notFound)
            #expect(e.message == "ref e999 not found (take a new snapshot)")
        }
    }

    @Test func evalResultsAndExceptions() async throws {
        let b = try await browser("<title>T</title>")
        defer { b.close() }
        #expect(try await eval(b, "({a: [1, true, 'x']})") == .object(["a": .array([.number(1), .bool(true), .string("x")])]))
        #expect(try await eval(b, "document.title") == .string("T"))
        #expect(try await eval(b, "undefined") == .null)
        #expect(try await eval(b, "NaN") == .string("nan"))
        #expect(try await eval(b, "-Infinity") == .string("-inf"))
        do { _ = try await eval(b, "throw new Error('boom')"); Issue.record("expected invalidArgs") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains("boom")) }
    }

    @Test func loadedEventAndBadURL() async throws {
        let events = Events()
        let b = try await browser("<title>Hello</title>", events: events)
        defer { b.close() }
        #expect(events.all.contains { $0.0 == "browser.loaded" && $0.1 == .object(["url": .string("https://collie.test/"), "title": .string("Hello")]) })
        do { _ = try await run(b, "navigate", ["url": .string("file:///etc/passwd")]); Issue.record("expected invalidArgs") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs) }
    }

    @Test func deletingPanelRemovesIsolatedStore() async throws {
        let b = try await browser("<p>x</p>", storage: .isolated)
        let id = b.panel.id
        _ = try await eval(b, "localStorage.setItem('k', 'v'); localStorage.getItem('k')")
        #expect(try await until { await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) })
        b.close()
        BrowserPanel.panelRemoved(b.panel, host: b.host)
        #expect(try await until(60) { !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id)) })
    }

    @Test func resizeAndScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-shot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try await browser("<body style='background:red'>x</body>", root: root)
        defer { b.close() }
        let r = try await run(b, "resize", ["width": .number(400), "height": .number(500)])
        #expect(r == ["width": .number(400), "height": .number(500)])
        b.container.layoutSubtreeIfNeeded()
        #expect(b.webView?.frame.size == CGSize(width: 400, height: 500))   // no self-sizing host: fixed viewport
        do { _ = try await run(b, "resize", ["width": .number(100)]); Issue.record("expected invalidArgs") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs) }
        let shot = try await run(b, "screenshot")
        guard case .string(let path)? = shot["path"] else { Issue.record("no path"); return }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasPrefix(root.appendingPathComponent("screens").path))
        let perms = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("screens").path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        if case .number(let w)? = shot["width"] { #expect(w >= 400) } else { Issue.record("no width") }
    }

    @Test func reconcileSweepsOrphanedStoresOnly() async throws {
        let live = try await browser("<p>a</p>", storage: .isolated)
        defer { live.close() }
        let orphan = try await browser("<p>b</p>", storage: .isolated)
        for b in [live, orphan] { _ = try await eval(b, "localStorage.setItem('k', 'v')") }
        #expect(try await until { await WKWebsiteDataStore.allDataStoreIdentifiers.contains(orphan.panel.id) })
        orphan.close()
        let host = PanelHostContext(panel: live.panel, root: URL(fileURLWithPath: "/tmp"), workspaceId: UUID(), call: { _, _ in .null }, emit: { _, _ in })
        BrowserPanel.reconcile(livePanels: [live.panel], host: host)
        #expect(try await until(60) { !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(orphan.panel.id)) })
        #expect(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(live.panel.id))
    }

    @Test func automationIsHiddenFromPageScripts() async throws {
        let b = try await browser(#"<script>window.seen = typeof window.__collie</script><button>Hi</button>"#)
        defer { b.close() }
        #expect(try await eval(b, "window.seen") == .string("undefined"))
        #expect(try await eval(b, "typeof window.__collie") == .string("undefined"))
        #expect(ref(output(try await run(b, "snapshot")), #"- button "Hi""#) != nil)
    }

    final class Flag: @unchecked Sendable { var done = false }

    @Test func supersededNavigationTakesTheNextOutcome() async throws {
        let b = try await browser("<p>start</p>")
        defer { b.close() }
        let flag = Flag()
        let first = Task { @MainActor in try await b.load(html: "<p>A</p>"); flag.done = true }
        for _ in 0..<5 { await Task.yield() }   // A's load starts first (main actor FIFO)
        try await b.load(html: "<title>B</title><p>B</p>")   // supersedes A's navigation
        #expect(try await until(20) { flag.done })
        if flag.done { try await first.value } else { first.cancel(); return }   // never hang the suite
        #expect(try await eval(b, "document.title") == .string("B"))
    }

    @Test func fragmentNavigationDoesNotHang() async throws {
        let b = try await browser("<p id='x' style='margin-top:3000px'>x</p>")
        defer { b.close() }
        let flag = Flag()
        let nav = Task { @MainActor in _ = try await b.handle("browser.navigate", ["url": .string("https://collie.test/#x")]); flag.done = true }
        #expect(try await until(20) { flag.done })
        if flag.done { try await nav.value } else { nav.cancel() }
        #expect(try await eval(b, "location.hash") == .string("#x"))
    }

    @Test func screenshotRetentionKeepsNewest50() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-shots-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("screens")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<55 {
            let u = dir.appendingPathComponent("old-\(i).png")
            try Data().write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + i))], ofItemAtPath: u.path)
        }
        let b = try await browser("<p>x</p>", root: root)
        defer { b.close() }
        _ = try await run(b, "resize", ["width": .number(400), "height": .number(400)])
        b.container.layoutSubtreeIfNeeded()
        guard case .string(let path)? = try await run(b, "screenshot")["path"] else { Issue.record("no path"); return }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.count == 50)
        #expect(left.contains((path as NSString).lastPathComponent))
        #expect(!left.contains("old-0.png") && !left.contains("old-5.png") && left.contains("old-6.png"))
    }

    /// Off screen (other floor, culled, hidden dock tab) the panel has no slot size: the page still has a viewport.
    @Test func screenshotWithoutResizeOrSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-shot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try await browser("<p>x</p>", root: root)
        defer { b.close() }
        let shot = try await run(b, "screenshot")
        guard case .number(let w)? = shot["width"], case .number(let h)? = shot["height"] else { Issue.record("\(shot)"); return }
        #expect(w > 0 && h > 0)
        #expect(try await eval(b, "innerWidth") == .number(1280))
    }

    @Test func screenshotsAreNamedByPanelAndRemovedWithIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-shot-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("screens")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let other = dir.appendingPathComponent("\(UUID().uuidString)-\(UUID().uuidString).png")
        try Data().write(to: other)
        let b = try await browser("<p>x</p>", root: root)
        guard case .string(let path)? = try await run(b, "screenshot")["path"] else { b.close(); Issue.record("no path"); return }
        #expect((path as NSString).lastPathComponent.hasPrefix(b.panel.id.uuidString + "-"))
        b.close()
        BrowserPanel.panelRemoved(b.panel, host: b.host)
        #expect(try await until { !FileManager.default.fileExists(atPath: path) })
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func navigationOutsideWebSchemesIsRefused() {
        for ok in ["https://a.b/", "http://a.b", "about:blank", "data:text/html,x", "blob:https://a.b/1"] {
            #expect(BrowserPanel.allowsNavigation(to: URL(string: ok), from: URL(string: "https://x"), appLoad: nil), "\(ok)")
        }
        for bad in ["file:///etc/passwd", "mailto:a@b.c", "collie://x"] {
            #expect(!BrowserPanel.allowsNavigation(to: URL(string: bad), from: nil, appLoad: URL(string: bad)), "\(bad)")
        }
        #expect(!BrowserPanel.allowsNavigation(to: nil, from: nil, appLoad: nil))
    }

    @Test func navigationRules() throws {
        let art = URL(string: "collie-artifact://app/a/v1/index.html")!
        #expect(!BrowserPanel.allowsNavigation(to: art, from: URL(string: "https://x"), appLoad: nil))
        #expect(BrowserPanel.allowsNavigation(to: art, from: URL(string: "collie-artifact://app/b/v1/index.html"), appLoad: nil))
        #expect(BrowserPanel.allowsNavigation(to: art, from: URL(string: "https://x"), appLoad: art))
        #expect(!BrowserPanel.allowsNavigation(to: art, from: nil, appLoad: nil))
        #expect(!BrowserPanel.allowsNavigation(to: art, from: URL(string: "about:blank"), appLoad: nil))
        #expect(try BrowserPanel.url("collie-artifact://app/a/v1/index.html") == art)
        #expect(throws: ProtocolError.self) { try BrowserPanel.url("file:///etc") }
        #expect(throws: ProtocolError.self) { try BrowserPanel.url("collie-artifact://other/a") }
    }

    @Test func navigateOpensArtifactsButPagesCannot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("artifacts/a/v1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<title>Art</title><p>hi</p>".utf8).write(to: dir.appendingPathComponent("index.html"))
        let dirB = root.appendingPathComponent("artifacts/b/v1")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data("<title>B</title>".utf8).write(to: dirB.appendingPathComponent("index.html"))
        let b = try await browser("<p>web</p>", root: root)   // an https page
        defer { b.close() }
        b.webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true   // window.open without a click
        _ = try await eval(b, "location.href = 'collie-artifact://app/a/v1/index.html'")
        try await Task.sleep(for: .milliseconds(500))
        #expect(b.webView?.url?.scheme == "https")   // refused
        // an about:blank iframe of the web page: a top-level link, and window.open
        _ = try await eval(b, """
            const f = document.createElement('iframe'); document.body.appendChild(f);
            f.contentDocument.body.innerHTML = '<a id=x target=_top href="collie-artifact://app/a/v1/index.html">x</a>';
            f.contentDocument.getElementById('x').click(); f.contentWindow.open('collie-artifact://app/a/v1/index.html'); 1
            """)
        try await Task.sleep(for: .milliseconds(500))
        #expect(b.webView?.url?.scheme == "https")
        _ = try await eval(b, "window.open('collie-artifact://app/a/v1/index.html'); 1")
        try await Task.sleep(for: .milliseconds(500))
        #expect(b.webView?.url?.scheme == "https")
        let o = try await run(b, "navigate", ["url": .string("collie-artifact://app/a/v1/index.html")])
        #expect(o["title"] == .string("Art"))   // main document and its subresource requests on the artifact scheme
        #expect(b.appLoad == nil)   // used once
        // an artifact page may open another one, in place
        _ = try await eval(b, "window.open('collie-artifact://app/b/v1/index.html'); 1")
        #expect(try await until(10) { b.webView?.url?.path == "/b/v1/index.html" })
    }

    @Test func waitTimeoutIsClampedBelowTheCommandTimeout() throws {
        #expect(try BrowserPanel.waitSeconds(["timeout": .number(500)]) == 115)
        #expect(try BrowserPanel.waitSeconds([:]) == 10)
        #expect(try BrowserPanel.waitSeconds(["timeout": .number(0)]) == 1)
        #expect(115 < (PluginRegistry.command("browser.wait")?.1.timeoutSeconds ?? 0))
    }
}

@Suite struct BrowserNormalizeTests {
    @Test func normalizesLegacyArtifactURL() {
        #expect(BrowserPanel.normalize("orq-artifact://app/x/index.html") == "collie-artifact://app/x/index.html")
        #expect(BrowserPanel.normalize("orq-design://app/index.html") == "collie-design://app/index.html")
        #expect(BrowserPanel.normalize("https://a.dev") == "https://a.dev")
    }
}
