import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI
import WebKit

/// Serves `collie-diagram://app/<path>` from the draw.io embed build, plus `host.html`: the page that holds the editor in
/// an iframe (embed mode talks to `window.parent`) and bridges its JSON messages to `collieDiagram` / `collieSend(s)`.
final class DiagramSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "collie-diagram"
    /// Never `enableSW`, `dev` or `test`: offline, stealth and no service worker keep draw.io from phoning home.
    static let editorQuery = "embed=1&proto=json&offline=1&stealth=1&pwa=0&plugins=0&lang=pt-br&dark=auto&spin=1&noExitBtn=1&noSaveBtn=1&saveAndExit=0"
    static let host = """
        <!doctype html><html><head><meta charset="utf-8"><title>Diagrama</title>
        <style>html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;display:block;overflow:hidden}</style></head>
        <body><iframe id="f" src="index.html?\(editorQuery)"></iframe><script>
        const f = document.getElementById('f');
        window.addEventListener('message', e => { if (e.source === f.contentWindow && typeof e.data === 'string')
          window.webkit.messageHandlers.collieDiagram.postMessage(e.data) });
        window.collieSend = s => f.contentWindow.postMessage(s, '*');
        </script></body></html>
        """
    let files: DesignSchemeHandler
    init(root: URL) { files = DesignSchemeHandler(root: root) }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let (status, type, data) = url.host == "app" && url.path == "/host.html" ? (200, "text/html; charset=utf-8", Data(Self.host.utf8))
            : files.serve(task.request)
        guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"]) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered synchronously in `start`
}

/// The Diagram plug-in's view: draw.io (embed mode, offline) on the panel's `.drawio` file in its project
/// (`state["file"]`, default `docs/diagrams/<name>.drawio`, under `state["root"]`). The file is the document: user edits
/// are written to it at once (autosave), and a change on disk from anyone else is merged into the editor.
@MainActor public final class DiagramPanel: NSObject, PluginPanelView {
    let panel: Panel
    let host: PanelHostContext
    private(set) var webView: WKWebView?
    private let box = Box()
    private let webRoot: URL?
    private var started = false
    /// The panel's file, once resolved.
    private(set) var file: URL?
    /// The bytes last written by the panel or loaded into the editor: a file event with these is our own.
    private var known: Data?
    /// The last autosave that came from the user (Task 3: an agent's `diagram.set` yields to it, `DiagramFile.mayOverwrite`).
    var lastUserEditAt: Date?
    /// A load or merge sent and not answered yet: its autosave is draw.io's, not the user's. Bounded (5 s): a reply that
    /// never comes must not stop the user's edits from being saved.
    private var programmaticUntil: Date?
    private var closed = false
    /// The draw.io events received, in order (tests, and Task 3's replies).
    private(set) var seen: [String] = []
    private var watcher: FileWatch?
    /// The merge sent because the disk changed under a user autosave: its autosave (disk + the user's edit) is saved.
    private var keepMergeAutosave = false
    /// The editor has loaded the file (agent commands that need it wait for this).
    private(set) var editorReady = false
    /// Why the panel can't open (shown in it, and the error of the commands that need the editor).
    private(set) var failure: String?
    /// The page on screen (index), from draw.io's replies.
    private(set) var currentPage = 0
    /// The last command's task: commands run one at a time.
    var queue: Task<Void, Never>?
    /// How long a JS call into the editor may take (R13: 15 s); then the editor is restarted.
    var jsTimeout: Double = 15
    private var waiters: [Waiter] = []

    public var view: NSView { box }

    /// The draw.io embed build: the app's Resources, then the repo's vendor dir (`swift run`, debug builds only).
    static let webDirectory: URL? = {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("drawio/web")) }
        #if DEBUG
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/drawio/web"))
        #endif
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }()

    public required convenience init(panel: Panel, host: PanelHostContext) { self.init(panel: panel, host: host, webRoot: Self.webDirectory) }

    init(panel: Panel, host: PanelHostContext, webRoot: URL?) {
        self.panel = panel; self.host = host; self.webRoot = webRoot
        super.init()
        box.owner = self
    }

    /// The project root and the requested file, from the panel's state.
    var projectRoot: URL? { if case .string(let r)? = panel.state["root"], !r.isEmpty { URL(fileURLWithPath: r) } else { nil } }
    var requestedFile: String? { if case .string(let f)? = panel.state["file"] { f } else { nil } }

    /// The panel's exports and screenshots go with it; the `.drawio` file stays (it belongs to the project).
    public static func panelRemoved(_ panel: Panel, host: PanelHostContext) {
        let dir = host.root.appendingPathComponent("screens", isDirectory: true), prefix = panel.id.uuidString + "-"
        Task.detached {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    /// A reply from draw.io (`export`, `merge`…) to a message just sent; nil after `timeout` seconds.
    func next(_ event: String, timeout: Double) async -> [String: JSONValue]? {
        let w = Waiter(event)
        waiters.append(w)
        return await withCheckedContinuation { c in
            w.c = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                w.finish(nil); self?.waiters.removeAll { $0 === w }
            }
        }
    }
    @MainActor private final class Waiter {
        let event: String
        var c: CheckedContinuation<[String: JSONValue]?, Never>?
        init(_ e: String) { event = e }
        func finish(_ v: [String: JSONValue]?) { c?.resume(returning: v); c = nil }
    }

    /// An agent command on a panel that was never shown starts the editor (the view works off screen too).
    func startIfNeeded() { if !started, !closed { start() } }
    /// A JS call that never returned (R13): a fresh editor, so the panel's later commands aren't stuck behind it.
    func resetEditor() { stopWatching(); dropWebView(); started = false; startIfNeeded() }

    public func close() {
        closed = true
        stopWatching()
        dropWebView()
    }
    private func dropWebView() {
        editorReady = false
        for w in waiters { w.finish(nil) }
        waiters = []
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        box.web = nil
        webView = nil
    }

    fileprivate func windowChanged() { if box.window != nil, !started, !closed { start() } }

    fileprivate func start() {
        started = true
        failure = nil
        guard let dir = webRoot else { return fail("Editor de diagramas indisponível\nRode scripts/build-drawio.sh", retry: false) }
        guard let root = projectRoot else { return fail("Painel sem pasta de projeto: abra-o de novo", retry: false) }
        let url: URL, xml: String
        do throws(ProtocolError) {
            url = try DiagramFile.resolve(requestedFile, panelName: panel.name, projectRoot: root)
            if let x = try DiagramFile.read(url, root: root) { xml = x } else {
                xml = DiagramFile.empty
                try DiagramFile.write(xml, to: url, root: root)
            }
            try DiagramFile.validate(xml: xml)
        } catch { return fail(error.message, retry: true) }
        file = url; known = Data(xml.utf8)
        let rel = String(url.path.dropFirst(DiagramFile.real(root).path.count + 1))
        box.setHeader(file: rel)
        box.status("Abrindo…", retry: false)
        watch()
        Task { [weak self] in
            let rules = try? await HTMLSnapshotter.ruleList()
            guard let self, !self.closed else { return }
            guard let rules else { return self.fail("Não consegui bloquear a rede do editor", retry: true) }
            self.makeWebView(dir: dir, rules: rules)
        }
    }

    private func fail(_ m: String, retry: Bool) { failure = m; box.status(m, retry: retry) }

    private func makeWebView(dir: URL, rules: WKContentRuleList) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        WebLockdown.harden(config)   // WebRTC off: ICE gets past the rule list
        config.setURLSchemeHandler(DiagramSchemeHandler(root: dir), forURLScheme: DiagramSchemeHandler.scheme)
        config.userContentController.add(rules)
        config.userContentController.add(Bridge(self), name: "collieDiagram")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web; box.web = web
        box.card.addSubview(web); box.needsLayout = true
        Task { [weak self] in   // fail closed: the WebRTC switch is private, check it took before loading
            guard let self, !self.closed, self.webView === web else { return }
            guard await WebLockdown.peerConnectionsOff(web) else { return self.fail("Não consegui bloquear a rede do editor", retry: false) }
            guard !self.closed, self.webView === web else { return }
            web.load(URLRequest(url: URL(string: "\(DiagramSchemeHandler.scheme)://app/host.html")!))
        }
    }

    /// Weak: the user content controller keeps its handlers alive.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: DiagramPanel?
        init(_ o: DiagramPanel) { owner = o }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let s = m.body as? String, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
            owner?.received(o)
        }
    }

    /// One message from draw.io (`event`: init, load, merge, autosave, export…).
    func received(_ m: [String: Any]) {
        let event = m["event"] as? String
        if let event { seen.append(event) }
        if let p = m["currentPage"] as? Int { currentPage = p }
        if let i = waiters.firstIndex(where: { $0.event == event }) {
            let w = waiters.remove(at: i)
            let v = (try? JSONSerialization.data(withJSONObject: m)).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
            w.finish(v ?? [:])
        }
        switch event {
        case "init":
            guard let xml = (try? readFile()) ?? nil else { return }
            known = Data(xml.utf8)
            send(["action": "load", "xml": xml, "autosave": 1, "noExitBtn": 1, "noSaveBtn": 1, "saveAndExit": 0])
        case "load":
            programmaticUntil = nil; editorReady = true
            box.status(nil, retry: false)
        case "merge":
            programmaticUntil = nil; keepMergeAutosave = false
            if m["error"] != nil, let xml = (try? readFile()) ?? nil { send(["action": "load", "xml": xml, "autosave": 1]) }
        case "autosave":
            let programmatic = programmaticUntil.map { Date() < $0 } ?? false
            guard !programmatic || keepMergeAutosave, let xml = m["xml"] as? String, (try? DiagramFile.validate(xml: xml)) != nil else { return }
            keepMergeAutosave = false
            lastUserEditAt = Date()
            // R12: the file changed on disk since the panel last read or wrote it (an in-place write not seen yet): never
            // overwrite it. Merge it into the editor, which keeps the user's edit, and save what the merge gives.
            if let disk = (try? readFile()) ?? nil, Data(disk.utf8) != known, (try? DiagramFile.validate(xml: disk)) != nil {
                known = Data(disk.utf8)
                send(["action": "merge", "xml": disk])
                keepMergeAutosave = true
                return
            }
            do throws(ProtocolError) { try writeFile(xml) }
            catch { fail(error.message, retry: true) }
        default: break
        }
    }

    /// Sends a protocol message to the editor; a load or merge marks its autosave as not the user's.
    func send(_ msg: [String: Any]) {
        if let a = msg["action"] as? String, a == "load" || a == "merge" { programmaticUntil = Date().addingTimeInterval(5) }
        guard let json = try? JSONSerialization.data(withJSONObject: msg), let s = String(data: json, encoding: .utf8),
              let lit = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
              let literal = String(data: lit, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("collieSend(\(literal))")
    }

    /// The panel's file through DiagramFile's no-follow access from the project root; nil when missing.
    func readFile() throws(ProtocolError) -> String? {
        guard let file, let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem arquivo") }
        return try DiagramFile.read(file, root: root)
    }
    /// `at`: the file an agent command resolved, before the view ever started (`file` is still nil then).
    func writeFile(_ xml: String, at url: URL? = nil) throws(ProtocolError) {
        guard let file = url ?? file, let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem arquivo") }
        try DiagramFile.write(xml, to: file, root: root)
        known = Data(xml.utf8)
        watcher?.rearm()   // the rename replaced the inode the file watch had
    }

    private func watch() {
        stopWatching()
        guard let file, let root = projectRoot else { return }
        watcher = FileWatch(file: file, root: root) { [weak self] in self?.fileChanged() }
    }
    private func stopWatching() { watcher?.stop(); watcher = nil }

    /// The file differs from what the panel knows: merge it in. A missing or malformed file is left alone (the editor
    /// keeps the last good version; the user's next edit writes it back).
    func fileChanged() {
        guard let xml = (try? readFile()) ?? nil, Data(xml.utf8) != known,
              (try? DiagramFile.validate(xml: xml)) != nil else { return }
        known = Data(xml.utf8)
        send(["action": "merge", "xml": xml])
    }

    /// The header (Diagrama + the file, relative to the project), then the web view inside a card; the status overlay
    /// (label + **Tentar de novo**) over the card.
    final class Box: NSView {
        weak var owner: DiagramPanel?
        var web: WKWebView?
        let card = NSView()
        private var header: NSView?
        private let label = NSTextField(wrappingLabelWithString: "")
        private let retry = NSButton(title: "Tentar de novo", target: nil, action: nil)
        private let overlay = NSStackView()
        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            card.wantsLayer = true
            card.layer?.cornerRadius = 14; card.layer?.borderWidth = 1; card.layer?.masksToBounds = true
            addSubview(card)
            applyChrome()
            label.alignment = .center; label.textColor = CollieColor.muted
            retry.target = self; retry.action = #selector(again)
            overlay.orientation = .vertical; overlay.alignment = .centerX
            overlay.addArrangedSubview(label); overlay.addArrangedSubview(retry)
            addSubview(overlay)
            setHeader(file: nil)
            status("Abrindo…", retry: false)
        }
        required init?(coder: NSCoder) { fatalError() }

        func setHeader(file: String?) {
            header?.removeFromSuperview()
            let h = NSHostingView(rootView: PanelHeader("Diagrama", subtitle: file) { EmptyView() }.background(Color.collieSidebar))
            addSubview(h); header = h
            needsLayout = true
        }

        private func applyChrome() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = CollieColor.background.cgColor
                card.layer?.backgroundColor = CollieColor.sunken.cgColor
                card.layer?.borderColor = CollieColor.border.cgColor
            }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyChrome() }

        func status(_ text: String?, retry showRetry: Bool) {
            overlay.isHidden = text == nil
            web?.isHidden = text != nil
            label.stringValue = text ?? ""
            retry.isHidden = !showRetry
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let top = header.map { h in h.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h.fittingSize.height); return h.frame.maxY } ?? 0
            card.frame = CGRect(x: 12, y: top + 12, width: max(0, bounds.width - 24), height: max(0, bounds.height - top - 24))
            web?.frame = card.bounds
            let w = max(0, min(card.frame.width - 24, 360)), h = overlay.fittingSize.height
            overlay.frame = CGRect(x: card.frame.minX + (card.frame.width - w) / 2, y: card.frame.minY + (card.frame.height - h) / 2, width: w, height: h)
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.windowChanged() }
        @objc private func again() { owner?.restart() }
    }

    fileprivate func restart() {
        guard webView == nil, !closed else { return box.status(nil, retry: false) }
        started = false; windowChanged()
    }
}

extension DiagramPanel: WKNavigationDelegate, WKUIDelegate {
    /// Only the panel's own scheme, in any frame; draw.io's links to its sites, help and the like go nowhere.
    nonisolated static func allows(_ url: URL?) -> Bool {
        let s = url?.scheme?.lowercased()
        return s == DiagramSchemeHandler.scheme || url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc"
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
    }
    /// `window.open` and `target=_blank`: never a new window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { fail("Editor de diagramas indisponível", retry: true) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { fail("Editor de diagramas indisponível", retry: true) }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopWatching(); dropWebView()
        started = false; fail("O editor de diagramas parou", retry: true)
    }
}
