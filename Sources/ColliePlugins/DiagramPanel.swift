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
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingCheck: Task<Void, Never>?

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

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .unavailable, message: "\(command): ainda não disponível")   // plan 2Q Diagram, Task 3
    }

    public func close() {
        closed = true
        stopWatching()
        dropWebView()
    }
    private func dropWebView() {
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
        guard let dir = webRoot else { return box.status("Editor de diagramas indisponível\nRode scripts/build-drawio.sh", retry: false) }
        guard let root = projectRoot else { return box.status("Painel sem pasta de projeto: abra-o de novo", retry: false) }
        let url: URL, xml: String
        do throws(ProtocolError) {
            url = try DiagramFile.resolve(requestedFile, panelName: panel.name, projectRoot: root)
            if !FileManager.default.fileExists(atPath: url.path) { try DiagramFile.write(DiagramFile.empty, to: url) }
            xml = try DiagramFile.read(url)
            try DiagramFile.validate(xml: xml)
        } catch { return box.status(error.message, retry: true) }
        file = url; known = Data(xml.utf8)
        let rel = String(url.path.dropFirst(DiagramFile.real(root).path.count + 1))
        box.setHeader(file: rel)
        box.status("Abrindo…", retry: false)
        watch(url)
        Task { [weak self] in
            let rules = try? await HTMLSnapshotter.ruleList()
            guard let self, !self.closed else { return }
            guard let rules else { return self.box.status("Não consegui bloquear a rede do editor", retry: true) }
            self.makeWebView(dir: dir, rules: rules)
        }
    }

    private func makeWebView(dir: URL, rules: WKContentRuleList) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DiagramSchemeHandler(root: dir), forURLScheme: DiagramSchemeHandler.scheme)
        config.userContentController.add(rules)
        config.userContentController.add(Bridge(self), name: "collieDiagram")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web; box.web = web
        box.card.addSubview(web); box.needsLayout = true
        web.load(URLRequest(url: URL(string: "\(DiagramSchemeHandler.scheme)://app/host.html")!))
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
        if let e = m["event"] as? String { seen.append(e) }
        switch m["event"] as? String {
        case "init":
            guard let file, let xml = try? DiagramFile.read(file) else { return }
            known = Data(xml.utf8)
            send(["action": "load", "xml": xml, "autosave": 1, "noExitBtn": 1, "noSaveBtn": 1, "saveAndExit": 0])
        case "load":
            programmaticUntil = nil
            box.status(nil, retry: false)
        case "merge":
            programmaticUntil = nil
            if m["error"] != nil, let file, let xml = try? DiagramFile.read(file) { send(["action": "load", "xml": xml, "autosave": 1]) }
        case "autosave":
            guard programmaticUntil.map({ Date() >= $0 }) ?? true, let file, let xml = m["xml"] as? String, (try? DiagramFile.validate(xml: xml)) != nil else { return }
            lastUserEditAt = Date()
            do throws(ProtocolError) { try DiagramFile.write(xml, to: file); known = Data(xml.utf8) }
            catch { box.status(error.message, retry: true) }
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

    /// Watches the file's folder (atomic writes replace the file's inode); a change merges into the editor, which keeps
    /// zoom and scroll. ponytail: one folder watch per panel; fine for the handful of diagram panels a workspace has.
    private func watch(_ url: URL) {
        stopWatching()
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleCheck() } }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }
    private func stopWatching() { watcher?.cancel(); watcher = nil; pendingCheck?.cancel(); pendingCheck = nil }

    /// Coalesces a burst of folder events into one look at the file, 150 ms later (well within the 1 s budget).
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.fileChanged()
        }
    }

    /// The file differs from what the panel knows: merge it in. A missing or malformed file is left alone (the editor
    /// keeps the last good version; the user's next edit writes it back).
    func fileChanged() {
        guard let file, let xml = try? DiagramFile.read(file), Data(xml.utf8) != known,
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
        if !BrowserPanel.isSuperseded(error) { box.status("Editor de diagramas indisponível", retry: true) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { box.status("Editor de diagramas indisponível", retry: true) }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopWatching(); dropWebView()
        box.status("O editor de diagramas parou", retry: true)
    }
}
