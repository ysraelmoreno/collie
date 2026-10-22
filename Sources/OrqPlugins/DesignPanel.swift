import AppKit
import OrqCore
import OrqProtocol
import OrqTheme
import SwiftUI
import WebKit

/// The figcraft web UI for a panel's design file: `orq-design://app/index.html[?webgl]#orq=1&join=<edit link>` (`?webgl`
/// forces WebGL2; without it figcraft-web tries WebGPU, see `GPUProbe`). The page joins the file's live session on the local figcraft-server
/// (`ws://127.0.0.1:<port>`) without its confirmation dialog (`orq=1`, patch 0004; before `join=`, which takes
/// the rest of the fragment). The link comes only from the daemon's `design.link`; it is a secret, so it is
/// never logged or shown.
@MainActor func designURL(editLink: String, webGPU: Bool = false) -> URL {
    // the page decodes the fragment (decodeURIComponent): encode all but the unreserved characters
    let link = editLink.addingPercentEncoding(withAllowedCharacters: DesignSchemeHandler.unreserved) ?? ""
    return URL(string: "\(DesignSchemeHandler.scheme)://app/index.html\(webGPU ? "" : "?webgl")#orq=1&join=\(link)")!
}

/// Whether this WebKit has a usable WebGPU adapter: an offscreen web view on the `orq-design://` scheme (the panel's own
/// context: `navigator.gpu` needs it) asks once per app run (deadline 2 s, then `false`). `ORQ_DESIGN_GPU=webgl|webgpu`
/// forces the answer (diagnostics).
@MainActor public enum GPUProbe {
    /// How a probe ended: the page's answer (`script`) or the deadline (`timer`).
    enum Outcome: Equatable { case script(Bool), timer }
    /// The in-flight or finished probe, shared by concurrent callers; set to `false` when a WebGPU page fails to start.
    static var task: Task<Bool, Never>?
    static var probes = 0   // tests: how many probes ran
    static var last: Outcome?   // diagnostics: how the last probe ended
    static let script = """
        (async () => { let ok = false; try { ok = navigator.gpu ? (await navigator.gpu.requestAdapter()) !== null : false } catch (e) {}
        window.webkit.messageHandlers.orqGPU.postMessage(ok) })()
        """

    static func envOverride(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool? {
        switch env["ORQ_DESIGN_GPU"]?.trimmingCharacters(in: .whitespaces).lowercased() { case "webgpu": true; case "webgl": false; default: nil }
    }

    /// Memoize `false` (a WebGPU page failed to start).
    static func memoize(_ v: Bool) { task = Task { v } }

    public static func webGPUAvailable() async -> Bool {
        if let o = envOverride() { return o }
        if let task { return await task.value }
        let t = Task { @MainActor in await probe(deadline: .seconds(2)).ok }
        task = t
        return await t.value
    }

    /// Serves one empty page, so the probe runs in the same kind of context as the panel.
    private final class Blank: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let r = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            task.didReceive(r); task.didReceive(Data("<html></html>".utf8)); task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    /// ponytail: a user script posting its result (not `callAsyncJavaScript`): a pending call keeps a hung view alive, as in HTMLSnapshotter.
    static func probe(deadline: Duration) async -> (ok: Bool, outcome: Outcome) {
        probes += 1
        let run = Run()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(Blank(), forURLScheme: DesignSchemeHandler.scheme)
        config.userContentController.add(run, name: "orqGPU")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        var web: WKWebView? = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: config)
        let timer = Task { try? await Task.sleep(for: deadline); run.finish(.timer) }
        let outcome: Outcome = await withCheckedContinuation { c in
            run.waiter = c
            web?.load(URLRequest(url: URL(string: "\(DesignSchemeHandler.scheme)://app/probe.html")!))
        }
        timer.cancel()
        web?.stopLoading()
        config.userContentController.removeAllScriptMessageHandlers()   // the controller retains the handler
        web = nil
        last = outcome
        if case .script(let ok) = outcome { return (ok, outcome) }
        return (false, outcome)
    }

    private final class Run: NSObject, WKScriptMessageHandler {
        var waiter: CheckedContinuation<Outcome, Never>?
        func finish(_ o: Outcome) { waiter?.resume(returning: o); waiter = nil }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { finish(.script(m.body as? Bool == true)) }
    }
}

/// Serves `orq-design://app/<path>` from the figcraft web folder: GET only, nothing outside the folder.
public final class DesignSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "orq-design"
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let types = ["wasm": "application/wasm", "js": "text/javascript", "html": "text/html; charset=utf-8", "css": "text/css",
                        "json": "application/json", "png": "image/png", "svg": "image/svg+xml", "woff2": "font/woff2"]
    let root: URL
    /// The artifacts folder: only for artifact pages (main document on the same scheme), never `artifacts.json` or
    /// a dot entry (`.removed/`).
    let artifacts: Bool

    public init(root: URL, artifacts: Bool = false) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.artifacts = artifacts
    }

    /// Status, content type and body for a request.
    func serve(_ r: URLRequest) -> (Int, String, Data) {
        guard (r.httpMethod ?? "GET") == "GET" else { return (405, "text/plain", Data()) }
        guard let url = r.url, url.host == "app" else { return (404, "text/plain", Data()) }
        if artifacts {
            guard r.mainDocumentURL?.scheme?.lowercased() == url.scheme?.lowercased() else { return (403, "text/plain", Data()) }
            guard !url.pathComponents.contains(where: { $0.hasPrefix(".") || $0 == "artifacts.json" }) else { return (404, "text/plain", Data()) }
        }
        // `path` is percent-decoded: `%2e%2e` is `..` here, and standardizing removes it
        let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        var dir: ObjCBool = false
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &dir), !dir.boolValue,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (404, "text/plain", Data()) }
        return (200, Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream", data)
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let (status, type, data) = serve(task.request)
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"]) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered synchronously in `start`
}

/// The Design plug-in's view: the live figcraft UI on the panel's file (`state["file"]`). On its first mount it asks
/// the daemon for the file's edit link (`design.link`, admin only) and loads the page; a failure shows
/// "Motor de design indisponível" + **Reconectar**. Agent commands (`design.*`) run in the daemon.
@MainActor public final class DesignPanel: NSObject, PluginPanelView {
    let panel: Panel
    let host: PanelHostContext
    private(set) var webView: WKWebView?
    private let box = Box()
    private var started = false
    private var gen = 0   // bumped per connect: a stale `design.link` reply never loads

    public var view: NSView { box }

    /// The figcraft web build: the app's Resources, then `ORQ_FIGCRAFT_DIR` (as the daemon), then the repo's vendor
    /// dir (`swift run`, debug builds only).
    static let webDirectory: URL? = {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("figcraft/web")) }
        if let e = ProcessInfo.processInfo.environment["ORQ_FIGCRAFT_DIR"] { c.append(URL(fileURLWithPath: e).appendingPathComponent("web")) }
        #if DEBUG
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/figcraft/web"))
        #endif
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }()

    public required convenience init(panel: Panel, host: PanelHostContext) { self.init(panel: panel, host: host, webRoot: Self.webDirectory) }

    /// `webRoot`: the figcraft web build it serves (tests pass their own).
    init(panel: Panel, host: PanelHostContext, webRoot: URL?) {
        self.panel = panel; self.host = host
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let failure = FailureHandler()
        // A WebGPU page that cannot start (figcraft-web writes "FigCraft failed to start") reloads with `?webgl`.
        // The page can post this, but the only effect is that reload.
        config.userContentController.add(failure, name: "orqStartFailed")
        config.userContentController.addUserScript(WKUserScript(source: Self.failureWatch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let dir = webRoot { config.setURLSchemeHandler(DesignSchemeHandler(root: dir), forURLScheme: DesignSchemeHandler.scheme) }
        let web = WKWebView(frame: .zero, configuration: config)
        webView = web
        super.init()
        failure.fire = { [weak self] in self?.webGPUFailed() }
        web.navigationDelegate = self
        box.owner = self
        box.web = web
        box.card.addSubview(web)
        box.setHeader(file: panel.state["file"].flatMap { if case .string(let f) = $0 { f } else { nil } })
    }

    static let failureWatch = """
        (() => { let sent = false; const look = () => { if (!sent && document.body && document.body.innerText.includes("FigCraft failed to start")) {
        sent = true; window.webkit.messageHandlers.orqStartFailed.postMessage(1) } };
        new MutationObserver(look).observe(document, { childList: true, subtree: true, characterData: true }) })()
        """

    private final class FailureHandler: NSObject, WKScriptMessageHandler {
        var fire: (@MainActor () -> Void)?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { fire?() }
    }

    /// Reloads the current page with `?webgl` (once: only when it has none) and remembers WebGPU does not work here.
    func webGPUFailed() {
        guard let web = webView, let url = web.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.query == nil else { return }
        GPUProbe.memoize(false)
        c.query = "webgl"
        if let u = c.url { web.load(URLRequest(url: u)) }
    }

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .unavailable, message: "design commands run in the daemon")
    }

    public func close() {
        gen += 1
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        box.web = nil
        webView = nil
    }

    fileprivate func windowChanged() { if box.window != nil, !started { connect() } }

    fileprivate func connect() {
        guard let web = webView else { return }
        started = true; gen += 1
        let g = gen
        guard Self.webDirectory != nil else { return failed("Rode scripts/build-figcraft.sh") }
        box.status("Abrindo…", retry: false)
        let call = host.call, name = panel.name
        Task { [weak self] in
            do throws(ProtocolError) {
                let r = try await call("design.link", ["panel": .string(name)])
                guard let self, self.gen == g else { return }
                guard case .object(let o) = r, case .string(let link)? = o["editLink"] else { return self.failed(nil) }
                let gpu = await GPUProbe.webGPUAvailable()
                guard self.gen == g else { return }
                web.load(URLRequest(url: designURL(editLink: link, webGPU: gpu)))
            } catch {
                guard let self, self.gen == g else { return }
                self.failed(error.message)   // the daemon scrubs links from errors
            }
        }
    }

    /// WebKit errors are not shown: their text can carry the page URL (and so the link).
    fileprivate func failed(_ detail: String?) {
        box.status("Motor de design indisponível" + (detail.map { "\n" + $0 } ?? ""), retry: true)
    }

    /// The header (file + "sincronizado"), then the web view inside a card; the status overlay (label + **Reconectar**)
    /// over the card.
    final class Box: NSView {
        weak var owner: DesignPanel?
        var web: WKWebView?
        let card = NSView()
        private let sync = DesignSync()
        private var header: NSView?
        private let label = NSTextField(wrappingLabelWithString: "")
        private let retry = NSButton(title: "Reconectar", target: nil, action: nil)
        private let overlay = NSStackView()
        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            card.wantsLayer = true
            card.layer?.cornerRadius = 14; card.layer?.borderWidth = 1; card.layer?.masksToBounds = true
            addSubview(card)
            applyChrome()
            label.alignment = .center; label.textColor = OrqColor.muted
            retry.target = self; retry.action = #selector(reconnect)
            overlay.orientation = .vertical; overlay.alignment = .centerX
            overlay.addArrangedSubview(label); overlay.addArrangedSubview(retry)
            addSubview(overlay)
            status("Abrindo…", retry: false)
        }
        required init?(coder: NSCoder) { fatalError() }

        func setHeader(file: String?) {
            let h = NSHostingView(rootView: DesignHeader(file: file, sync: sync))
            addSubview(h); header = h
            needsLayout = true
        }

        /// `cgColor`s resolve under the view's appearance, again on theme change (as the canvas nodes).
        private func applyChrome() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = OrqColor.background.cgColor
                card.layer?.backgroundColor = OrqColor.sunken.cgColor
                card.layer?.borderColor = OrqColor.border.cgColor
            }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyChrome() }

        func status(_ text: String?, retry showRetry: Bool) {
            overlay.isHidden = text == nil
            web?.isHidden = text != nil
            sync.synced = text == nil
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
        @objc private func reconnect() { owner?.connect() }
    }
}

extension DesignPanel: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == DesignSchemeHandler.scheme || scheme == "about" ? .allow : .cancel)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { box.status(nil, retry: false) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { failed(nil) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !BrowserPanel.isSuperseded(error) { failed(nil) }   // a Reconectar replaced it
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(nil) }
}

/// Whether the page is live on the file's session (no status overlay).
@MainActor final class DesignSync: ObservableObject { @Published var synced = false }

/// The Design panel's header: the file and, once the page is live, "sincronizado" (a dot in `accent` plus the word).
private struct DesignHeader: View {
    let file: String?
    @ObservedObject var sync: DesignSync
    var body: some View {
        PanelHeader("Design", subtitle: file) {
            // ponytail: "sincronizado" means "page loaded" (the figcraft page is live), not a confirmed round-trip with the file.
            if sync.synced {
                HStack(spacing: 6) {
                    Circle().fill(Color.orqAccent).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text("sincronizado").font(.orqMono(11, .medium)).foregroundStyle(Color.orqAccent)
                }
            }
        }
        .background(Color.orqSidebar)
    }
}
