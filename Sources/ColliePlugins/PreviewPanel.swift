import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI
import WebKit

/// Serves `collie-preview://app/<path>` from the panel's project: only what `PreviewFile.servable` allows (no dot-path,
/// nothing outside the root, no symlink out), read without following links (`DiagramFile.readData`), at most 8 MiB.
/// Everything else is a 404 with an empty body. The page is agent-written: untrusted.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "collie-preview"
    let root: URL
    init(root: URL) { self.root = root }

    func serve(_ r: URLRequest) -> (Int, String, Data) {
        guard (r.httpMethod ?? "GET") == "GET", let url = r.url, url.host == "app",
              let file = PreviewFile.servable(url.path(percentEncoded: true), projectRoot: root),
              let data = (try? DiagramFile.readData(file, root: root, noun: "página")) ?? nil else { return (404, "text/plain", Data()) }
        return (200, PreviewFile.contentType(file.pathExtension), data)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let (status, type, data) = serve(task.request)
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered synchronously in `start`
}

/// The Prévia plug-in's view: a project page (`state["file"]` under `state["root"]`) live — reloaded within 1 s of a
/// change, keeping the scroll — or an artifact (`state["artifact"]`, its `collie-artifact://` page). Offline like the
/// other web panels: the content rules, WebRTC off (checked before the first load, fail closed), own schemes only.
@MainActor public final class PreviewPanel: NSObject, PluginPanelView {
    let panel: Panel
    let host: PanelHostContext
    private(set) var webView: WKWebView?
    private let box = Box()
    let header = PreviewHeaderModel()
    private var started = false, closed = false
    private var watcher: FileWatch?
    /// The page shown (file mode), once resolved.
    private(set) var file: URL?
    /// The URL loaded (`collie-preview://…` or `collie-artifact://…`).
    private(set) var pageURL: URL?
    /// The last 20 page errors (`error` / `unhandledrejection`), of the page now shown.
    private(set) var errors: [String] = []
    /// Main-frame loads finished (tests).
    private(set) var loads = 0
    /// Over the last render: "Arquivo removido" and the like.
    var status: String? { header.status }
    /// Why the panel can't show the page.
    private(set) var failure: String?
    /// `data-theme` set on the page's `<html>`: light | dark | nil (the page's own).
    private(set) var theme: String?
    private var pendingScroll: Double?
    /// The last command's task: commands run one at a time.
    var queue: Task<Void, Never>?

    /// Errors and theme live in a world of their own: the page can't see, hide or forge them.
    static let world = WKContentWorld.world(name: "collie-preview")
    static let errorScript = """
        (() => {
          const post = m => { try { webkit.messageHandlers.colliePreview.postMessage(String(m).slice(0, 500)) } catch (_) {} };
          window.addEventListener('error', e => { if (e instanceof ErrorEvent) post(e.message || 'erro') });
          window.addEventListener('unhandledrejection', e => {
            const r = e.reason; post('Unhandled rejection: ' + (r && r.message !== undefined ? r.message : r));
          });
        })();
        """

    public var view: NSView { box }

    public required init(panel: Panel, host: PanelHostContext) {
        self.panel = panel; self.host = host
        super.init()
        box.owner = self
        header.onReload = { [weak self] in self?.reload(keepScroll: true) }
        header.onTheme = { [weak self] in self?.setTheme($0) }
        box.setHeader(header)
    }

    func string(_ k: String) -> String? { if case .string(let s)? = panel.state[k], !s.isEmpty { s } else { nil } }
    var projectRoot: URL? { string("root").map { URL(fileURLWithPath: $0) } }
    var artifactId: String? { string("artifact") }

    /// The panel's screenshots go with it; the page stays (it belongs to the project).
    public static func panelRemoved(_ panel: Panel, host: PanelHostContext) {
        DiagramPanel.panelRemoved(panel, host: host)
    }

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
    }

    public func close() {
        closed = true
        watcher?.stop(); watcher = nil
        dropWebView()
    }
    private func dropWebView() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        box.web = nil; webView = nil
    }

    fileprivate func windowChanged() { if box.window != nil, !started, !closed { start() } }
    func startIfNeeded() { if !started, !closed { start() } }

    private func fail(_ m: String) { failure = m; box.overlay(m) }

    fileprivate func start() {
        started = true; failure = nil
        box.overlay("Abrindo…")
        if let id = artifactId {
            header.file = "artifact"
            Task { [weak self] in
                guard let self else { return }
                let url: URL
                do throws(ProtocolError) {
                    let a = try await self.host.call("artifact.get", ["id": .string(id)])
                    guard case .object(let o) = a, case .string(let s)? = o["url"], let u = URL(string: s),
                          u.scheme == BrowserPanel.artifactScheme, u.host == "app" else { return self.fail("Artifact sem página") }
                    if case .string(let t)? = o["title"] { self.header.file = t }
                    url = u
                } catch { return self.fail(error.message) }
                guard !self.closed else { return }
                self.open(url)
            }
            return
        }
        guard let root = projectRoot else { return fail("Painel sem pasta de projeto: abra-o de novo") }
        let url: URL
        do throws(ProtocolError) { url = try PreviewFile.resolve(string("file") ?? "", projectRoot: root) }
        catch { return fail(error.message) }
        file = url
        let rel = String(url.path.dropFirst(DiagramFile.real(root).path.count + 1))
        header.file = rel
        // ponytail: the page's folder and the page itself are watched; an in-place write to a file in a subfolder (or to a
        // sibling, same inode) isn't seen: **Recarregar** covers it.
        watcher = FileWatch(file: url, root: root) { [weak self] in self?.fileChanged() }
        guard let path = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let page = URL(string: "\(PreviewSchemeHandler.scheme)://app/\(path)") else { return fail("Caminho inválido: \(rel)") }
        if (try? DiagramFile.readData(url, root: root, noun: "página")) ?? nil == nil { header.status = "Arquivo removido" }
        open(page)
    }

    private func open(_ url: URL) {
        pageURL = url
        Task { [weak self] in
            let rules = try? await HTMLSnapshotter.ruleList()
            guard let self, !self.closed else { return }
            guard let rules else { return self.fail("Não consegui bloquear a rede da prévia") }
            self.makeWebView(rules: rules, url: url)
        }
    }

    private func makeWebView(rules: WKContentRuleList, url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        WebLockdown.harden(config)   // WebRTC off: ICE gets past the rule list
        if let root = projectRoot { config.setURLSchemeHandler(PreviewSchemeHandler(root: root), forURLScheme: PreviewSchemeHandler.scheme) }
        config.setURLSchemeHandler(DesignSchemeHandler(root: host.root.appendingPathComponent("artifacts"), artifacts: true),
                                   forURLScheme: BrowserPanel.artifactScheme)
        config.userContentController.add(rules)
        config.userContentController.add(Bridge(self), contentWorld: Self.world, name: "colliePreview")
        installScripts(config.userContentController)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web; box.web = web
        box.card.addSubview(web); box.needsLayout = true
        Task { [weak self] in   // fail closed: the WebRTC switch is private, check it took before loading
            guard let self, !self.closed, self.webView === web else { return }
            guard await WebLockdown.peerConnectionsOff(web) else { return self.fail("Não consegui bloquear a rede da prévia") }
            guard !self.closed, self.webView === web else { return }
            self.box.overlay(nil)
            web.load(URLRequest(url: url))
        }
    }

    /// The error catcher at document start and the theme (if any) at document end, both in the panel's world.
    private func installScripts(_ c: WKUserContentController) {
        c.removeAllUserScripts()
        c.addUserScript(WKUserScript(source: Self.errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        if let t = theme { c.addUserScript(WKUserScript(source: Self.themeJS(t), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world)) }
    }
    static func themeJS(_ t: String?) -> String {
        switch t {
        case "dark": "document.documentElement.dataset.theme = 'dark';"
        case "light": "document.documentElement.dataset.theme = 'light';"
        default: "delete document.documentElement.dataset.theme;"
        }
    }

    /// light | dark | nil (the page's own), on the page now and on every later load.
    func setTheme(_ t: String?) {
        theme = t == "dark" || t == "light" ? t : nil
        header.theme = theme
        guard let web = webView else { return }
        installScripts(web.configuration.userContentController)
        web.evaluateJavaScript(Self.themeJS(theme), in: nil, in: Self.world) { _ in }
    }

    /// Reloads the page; `keepScroll`: back to the same `scrollY` once it has loaded.
    func reload(keepScroll: Bool) {
        guard let web = webView else { return startIfNeeded() }
        guard keepScroll else { pendingScroll = nil; web.reload(); return }
        web.evaluateJavaScript("window.scrollY", in: nil, in: Self.world) { [weak self] r in
            guard let self, self.webView === web else { return }
            if case .success(let y) = r, let y = y as? Double, y > 0 { self.pendingScroll = y }
            if web.url == nil, let u = self.pageURL { web.load(URLRequest(url: u)) } else { web.reload() }
        }
    }

    /// The page or its folder changed (one call per burst): gone → "Arquivo removido" over the last render; else reload.
    func fileChanged() {
        guard let file, let root = projectRoot else { return }
        do throws(ProtocolError) {
            guard try DiagramFile.readData(file, root: root, noun: "página") != nil else { header.status = "Arquivo removido"; return }
        } catch { header.status = error.message; return }
        header.status = nil
        reload(keepScroll: true)
    }

    fileprivate func received(_ message: String) {
        errors.append(message)
        if errors.count > 20 { errors.removeFirst(errors.count - 20) }
    }

    /// Weak: the user content controller keeps its handlers alive.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: PreviewPanel?
        init(_ o: PreviewPanel) { owner = o }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let s = m.body as? String, m.frameInfo.isMainFrame else { return }
            owner?.received(s)
        }
    }

    /// The header, then the web view inside a card; a centered overlay ("Abrindo…", a failure) over the card.
    final class Box: NSView {
        weak var owner: PreviewPanel?
        var web: WKWebView?
        let card = NSView()
        private var header: NSView?
        private let label = NSTextField(wrappingLabelWithString: "")
        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            card.wantsLayer = true
            card.layer?.cornerRadius = 14; card.layer?.borderWidth = 1; card.layer?.masksToBounds = true
            addSubview(card)
            applyChrome()
            label.alignment = .center; label.textColor = CollieColor.muted
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        func setHeader(_ m: PreviewHeaderModel) {
            let h = NSHostingView(rootView: PreviewHeader(m: m))
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

        func overlay(_ text: String?) {
            label.isHidden = text == nil; label.stringValue = text ?? ""
            web?.isHidden = text != nil
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let top = header.map { h in h.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h.fittingSize.height); return h.frame.maxY } ?? 0
            card.frame = CGRect(x: 12, y: top + 12, width: max(0, bounds.width - 24), height: max(0, bounds.height - top - 24))
            web?.frame = card.bounds
            let w = max(0, min(card.frame.width - 24, 360)), h = label.fittingSize.height
            label.frame = CGRect(x: card.frame.minX + (card.frame.width - w) / 2, y: card.frame.minY + (card.frame.height - h) / 2, width: w, height: h)
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.windowChanged() }
    }
}

/// What the Prévia's header shows and its controls call.
@MainActor final class PreviewHeaderModel: ObservableObject {
    @Published var file: String?
    @Published var status: String?
    @Published var theme: String?
    var onReload: () -> Void = {}
    var onTheme: (String?) -> Void = { _ in }
}

/// The file (relative to the project), a status over the last render, **Recarregar** and `Página | Claro | Escuro`.
private struct PreviewHeader: View {
    @ObservedObject var m: PreviewHeaderModel
    var body: some View {
        PanelHeader("Prévia", subtitle: m.file) {
            HStack(spacing: 8) {
                if let s = m.status { Text(s).font(.collieMono(11, .medium)).foregroundStyle(Color.collieAttention) }
                Picker("Tema", selection: Binding(get: { m.theme ?? "" }, set: { m.onTheme($0.isEmpty ? nil : $0) })) {
                    Text("Página").tag(""); Text("Claro").tag("light"); Text("Escuro").tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Recarregar") { m.onReload() }.buttonStyle(CollieButtonStyle(.secondary))
            }
        }
        .background(Color.collieSidebar)
    }
}

extension PreviewPanel: WKNavigationDelegate, WKUIDelegate {
    /// Only the panel's own schemes, in any frame.
    nonisolated static func allows(_ url: URL?) -> Bool {
        let s = url?.scheme?.lowercased()
        return s == PreviewSchemeHandler.scheme || s == BrowserPanel.artifactScheme
            || url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc"
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
    }
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { errors = [] }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loads += 1
        guard let y = pendingScroll else { return }
        pendingScroll = nil
        webView.evaluateJavaScript("window.scrollTo(0, \(y))", in: nil, in: Self.world) { _ in }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { header.status = "Não consegui carregar a página" }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { header.status = "Não consegui carregar a página" }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dropWebView(); watcher?.stop(); watcher = nil
        started = false; fail("A prévia parou: Recarregar")
    }
}
