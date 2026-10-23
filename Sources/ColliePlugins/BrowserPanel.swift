import AppKit
import CollieCore
import CollieProtocol
import WebKit
import os

/// A host slot that resizes itself to a plug-in's requested content size (the canvas node's body does; a dock doesn't).
@MainActor public protocol PanelContentSizing: NSView {
    func setContentSize(_ size: CGSize)
}

/// The Browser plug-in: a `WKWebView` driven by `browser.*` commands (see BrowserCommands.swift).
/// Storage by the panel's `state["storage"]`: isolated → a data store of its own (id = panel id, deleted with the
/// panel); workspace → one store per workspace whose identifier is the workspace UUID itself (deterministic, and
/// UUIDs don't collide with panel ids); global → the default store.
@MainActor public final class BrowserPanel: NSObject, PluginPanelView {
    static let consoleCap = 500
    static let consoleRatePerSecond = 10
    /// Artifact pages (`collie-artifact://app/<folder>/…`), served from `<root>/artifacts`.
    nonisolated static let artifactScheme = "collie-artifact"

    let panel: Panel
    let host: PanelHostContext
    private(set) var webView: WKWebView?
    let container = Container()
    private struct Waiter { let done: CheckedContinuation<Void, any Error>; let fragmentTarget: URL? }
    private var navigations: [ObjectIdentifier: Waiter] = [:]
    /// Waiters whose navigation was superseded (cancelled by a newer one): they take the next navigation's outcome.
    private var superseded: [CheckedContinuation<Void, any Error>] = []
    private var urlObservation: NSKeyValueObservation?
    /// Panels with a live view: `reconcile` never sweeps their store, even one opened after the snapshot.
    private static var liveIds: Set<UUID> = []
    private(set) var consoleLines: [String] = []
    /// The URL the app or an agent is loading (set right before `web.load`): an `collie-artifact` page a web page couldn't open.
    var appLoad: URL?
    private var consoleEmits: [ContinuousClock.Instant] = []

    public var view: NSView { container }

    public init(panel: Panel, host: PanelHostContext) {
        self.panel = panel; self.host = host
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(for: panel, workspaceId: host.workspaceId)
        config.setURLSchemeHandler(DesignSchemeHandler(root: host.root.appendingPathComponent("artifacts"), artifacts: true), forURLScheme: Self.artifactScheme)
        let content = config.userContentController
        let web = WKWebView(frame: .zero, configuration: config)
        webView = web
        super.init()
        installScripts()
        content.add(WeakHandler(self), contentWorld: .page, name: BrowserAutomation.consoleHandler)
        web.navigationDelegate = self
        web.uiDelegate = self
        container.web = web
        container.offscreenFrame()
        Self.liveIds.insert(panel.id)
        // a same-document (fragment) navigation has no didFinish: its URL change ends the wait
        urlObservation = web.observe(\.url) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.urlChanged(web.url) }
        }
        if case .string(let s)? = panel.state["url"], let url = try? Self.url(Self.normalize(s)) { appLoad = url; web.load(URLRequest(url: url)) }
    }

    public func close() {
        guard let web = webView else { return }
        Self.liveIds.remove(panel.id)
        urlObservation = nil
        web.stopLoading()
        web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        container.web = nil
        webView = nil
        failNavigations(ProtocolError(code: .unavailable, message: "browser closed"))
    }

    /// Reduced-motion emulation (`nil` = the system's); the color scheme lives on the web view's `appearance`.
    var reducedMotion: String?
    var colorScheme: String?

    /// (Re)builds the user scripts, in order: built-ins, then the motion emulation. Task 5's init scripts go after these.
    func installScripts() {
        guard let content = webView?.configuration.userContentController else { return }
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: BrowserAutomation.script, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: BrowserAutomation.world))
        content.addUserScript(WKUserScript(source: BrowserAutomation.consoleScript, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        if let reducedMotion {
            content.addUserScript(WKUserScript(source: BrowserAutomation.motionScript(reducedMotion), injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: .page))
        }
    }

    func live() throws(ProtocolError) -> WKWebView {
        guard let webView else { throw ProtocolError(code: .unavailable, message: "browser closed") }
        return webView
    }

    // MARK: storage

    static func scope(_ p: Panel) -> StorageScope {
        if case .string(let s)? = p.state["storage"], let sc = StorageScope(rawValue: s) { return sc }
        return .isolated
    }

    static func dataStore(for panel: Panel, workspaceId: UUID?) -> WKWebsiteDataStore {
        switch scope(panel) {
        case .isolated: return WKWebsiteDataStore(forIdentifier: panel.id)
        // ponytail: no workspace id (never expected while connected) → nothing persisted
        case .workspace: return workspaceId.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
        case .global: return .default()
        }
    }

    public static func panelRemoved(_ panel: Panel, host: PanelHostContext) {
        let dir = host.root.appendingPathComponent("screens", isDirectory: true), prefix = panel.id.uuidString + "-"
        Task.detached { removeScreenshots(in: dir, prefix: prefix) }
        guard scope(panel) == .isolated else { return }
        let id = panel.id
        Task { @MainActor in await removeStore(id) }
    }

    public static func reconcile(livePanels: [Panel], host: PanelHostContext) {
        guard let w = host.workspaceId else { return }   // can't tell the workspace store apart: sweep nothing
        let keep = Set(livePanels.filter { scope($0) == .isolated }.map(\.id) + [w])
        Task { @MainActor in
            warmWebKit()
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !keep.contains(id) && !liveIds.contains(id) {
                await removeStore(id)
            }
        }
    }

    /// WebKit crashes (SIGSEGV in RunLoop::dispatch) when the data store identifier APIs run before anything has
    /// touched a data store: true at launch, when `reconcile`/`panelRemoved` run before any webview exists.
    static func warmWebKit() { _ = WKWebsiteDataStore.default() }

    /// The store can still be in use right after its webview went away (WebContent process winding down): retried.
    @discardableResult static func removeStore(_ id: UUID) async -> Bool {
        warmWebKit()
        for _ in 0..<20 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: id); return true } catch {
                if !(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(id) { return true }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        Logger(subsystem: "dev.collie.app", category: "browser").error("browser: could not remove data store \(id)")
        return false
    }

    // MARK: navigation

    /// What may load (links, redirects, window.open, the app's own loads): web schemes; no file: or other custom
    /// schemes. An `collie-artifact` page only from another artifact page or as the main-frame load the app or an agent
    /// asked for (`appLoad`; the caller passes nil for other frames): a web page can't open local artifacts.
    nonisolated static func allowsNavigation(to url: URL?, from source: URL?, appLoad: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == artifactScheme {
            return url == appLoad || source?.scheme?.lowercased() == artifactScheme
        }
        return ["http", "https", "about", "data", "blob"].contains(scheme)
    }

    /// http(s), about: and `collie-artifact://app/…` only (no file: or other custom schemes); a bare host gets https://.
    /// Saved panel state from Orq holds `orq-artifact://` / `orq-design://` URLs: rewrite to the Collie schemes.
    nonisolated static let legacyScheme = ["orq-artifact://": "collie-artifact://", "orq-design://": "collie-design://"]
    nonisolated static func normalize(_ url: String) -> String {
        for (old, new) in legacyScheme where url.lowercased().hasPrefix(old) { return new + url.dropFirst(old.count) }
        return url
    }

    static func url(_ raw: String) throws(ProtocolError) -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://"), !s.lowercased().hasPrefix("about:") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "about" || (["http", "https"].contains(scheme) && u.host != nil) || (scheme == artifactScheme && u.host == "app") else {
            throw ProtocolError(code: .invalidArgs, message: "url must be http(s) or collie-artifact://app/: \(raw)")
        }
        return u
    }

    /// The URL of the frame that started a navigation; nil when the app started it (WebKit leaves `sourceFrame` nil
    /// although it's declared non-optional, hence the optional cast).
    static func source(_ action: WKNavigationAction) -> URL? { (action.sourceFrame as WKFrameInfo?)?.request.url }

    /// Waits for `didFinish` (or, for a fragment-only change of `target`, the URL change); a failed navigation is
    /// `invalidArgs` with WebKit's description.
    func wait(for nav: WKNavigation?, fragmentOf target: URL? = nil) async throws(ProtocolError) {
        guard let nav else { throw ProtocolError(code: .invalidArgs, message: "navigation did not start") }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                navigations[ObjectIdentifier(nav)] = Waiter(done: c, fragmentTarget: target)
                urlChanged(webView?.url)   // already there
            }
        } catch let e as ProtocolError {
            throw e
        } catch {
            throw ProtocolError(code: .invalidArgs, message: "navigation failed: \(error.localizedDescription)")
        }
    }

    /// Tests: an HTML page on a secure origin, so storage APIs work.
    func load(html: String) async throws(ProtocolError) {
        try await wait(for: live().loadHTMLString(html, baseURL: URL(string: "https://collie.test/")))
    }

    /// A cancelled navigation (NSURLErrorCancelled, or WebKit's 102 "frame load interrupted") was replaced by a newer
    /// one: its waiter takes that one's outcome, or succeeds if nothing is loading any more.
    private func finish(_ nav: WKNavigation?, _ error: (any Error)?) {
        let waiter = nav.flatMap { navigations.removeValue(forKey: ObjectIdentifier($0)) }
        if let error, Self.isSuperseded(error) {
            if let waiter { superseded.append(waiter.done) }
            if webView?.isLoading != true { resumeSuperseded(nil) }
            return
        }
        resumeSuperseded(error)
        guard let waiter else { return }
        if let error { waiter.done.resume(throwing: error) } else { waiter.done.resume() }
    }

    private func supersedeAll(except nav: WKNavigation?) {
        for (key, w) in navigations where nav.map(ObjectIdentifier.init) != key && w.fragmentTarget == nil {
            navigations[key] = nil
            superseded.append(w.done)
        }
    }

    private func resumeSuperseded(_ error: (any Error)?) {
        let all = superseded; superseded = []
        for c in all { if let error { c.resume(throwing: error) } else { c.resume() } }
    }

    static func isSuperseded(_ error: any Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102)
    }

    private func urlChanged(_ url: URL?) {
        guard let url else { return }
        for (key, w) in navigations where w.fragmentTarget?.absoluteString == url.absoluteString {
            navigations[key] = nil
            w.done.resume()
        }
    }

    private func failNavigations(_ e: ProtocolError) {
        let all = navigations.values.map(\.done) + superseded
        navigations = [:]; superseded = []
        for c in all { c.resume(throwing: e) }
    }

    // MARK: console

    func consoleMessage(level: String, text: String) {
        let level = String(level.prefix(16)), text = String(text.prefix(2000))
        consoleLines.append("[\(level)] \(text)")
        if consoleLines.count > Self.consoleCap { consoleLines.removeFirst(consoleLines.count - Self.consoleCap) }
        let now = ContinuousClock.now
        consoleEmits.removeAll { now - $0 >= .seconds(1) }
        guard consoleEmits.count < Self.consoleRatePerSecond else { return }   // ponytail: excess is dropped, the ring keeps it
        consoleEmits.append(now)
        host.emit("browser.console", .object(["level": .string(level), "text": .string(text)]))
    }

    /// The page slot. Without a viewport the webview fills the slot. With one (`browser.resize`) the page keeps that
    /// size whatever the slot is: `page` has bounds = viewport and a frame = the viewport scaled to fit the slot
    /// (`scale` ≤ 1, centered at the top), so the web view's own frame (= viewport) never changes. Off screen (other
    /// paddock, culled, hidden dock tab: no superview or no size) the page keeps a viewport so layout and
    /// screenshots still work.
    final class Container: NSView {
        static let defaultViewport = CGSize(width: 1280, height: 800)
        /// Holds the web view; its bounds/frame carry the fit-to-slot scale.
        let page = NSView()
        var web: WKWebView? { didSet { if let web { page.addSubview(web) } } }
        var viewport: CGSize? { didSet { needsLayout = true; offscreenFrame() } }
        /// Slot points per page CSS px (1 without a viewport or off screen). A CSS px (x, y) is at `page.frame.origin + (x, y) * scale` in this view.
        private(set) var scale: CGFloat = 1
        override var isFlipped: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); addSubview(page) }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            if superview == nil || bounds.isEmpty { offscreenFrame(); return }
            guard let viewport else { place(CGRect(origin: .zero, size: bounds.size), viewport: bounds.size); return }
            let s = min(bounds.width / viewport.width, bounds.height / viewport.height, 1)
            let size = CGSize(width: viewport.width * s, height: viewport.height * s)
            place(CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: 0, width: size.width, height: size.height), viewport: viewport)
        }
        /// `frame` first: setting a frame resets the bounds size.
        private func place(_ frame: CGRect, viewport: CGSize) {
            page.frame = frame
            page.bounds = CGRect(origin: .zero, size: viewport)
            web?.frame = page.bounds
            scale = viewport.width > 0 ? frame.width / viewport.width : 1
        }
        /// Unmounted: the `browser.resize` viewport, else the last size it had, else 1280×800.
        func offscreenFrame() {
            guard let web, superview == nil || bounds.isEmpty else { return }
            let size = viewport ?? (web.frame.isEmpty ? Self.defaultViewport : web.frame.size)
            place(CGRect(origin: .zero, size: size), viewport: size)
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); needsLayout = true }
    }
}

extension BrowserPanel: WKNavigationDelegate, WKUIDelegate {
    /// One main frame, one navigation: a newer one supersedes every other waiter (WebKit doesn't always report the
    /// cancellation of a navigation replaced before it started).
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        supersedeAll(except: navigation)
    }
    /// `webView.title` can lag behind `didFinish` (KVO): the title is read from the page.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let nav = navigation
        Task {
            let title = (try? await webView.evaluateJavaScript("document.title", in: nil, contentWorld: .page)) as? String
            host.emit("browser.loaded", .object(["url": .string(String((webView.url?.absoluteString ?? "").prefix(2048))),
                                                 "title": .string(String((title ?? webView.title ?? "").prefix(512)))]))
            finish(nav, nil)
        }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(navigation, error)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(navigation, error)
    }
    /// Covers page-initiated loads and target=_blank / window.open (loaded here, below).
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url, main = navigationAction.targetFrame?.isMainFrame == true
        let ok = Self.allowsNavigation(to: url, from: Self.source(navigationAction), appLoad: main ? appLoad : nil)
        if ok, main, url == appLoad { appLoad = nil }
        decisionHandler(ok ? .allow : .cancel)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failNavigations(ProtocolError(code: .unavailable, message: "browser page crashed"))
    }
    /// target=_blank and window.open load here: a panel has a single page.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // checked here with the opener as source: the load below is the app's own (`appLoad`)
        if navigationAction.targetFrame == nil,
           Self.allowsNavigation(to: navigationAction.request.url, from: Self.source(navigationAction), appLoad: nil) {
            appLoad = navigationAction.request.url
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// `WKUserContentController` retains its handlers: this breaks the panel ↔ controller cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserPanel?
    init(_ t: BrowserPanel) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let level = body["level"] as? String,
              let text = body["text"] as? String else { return }
        target?.consoleMessage(level: level, text: text)
    }
}
