import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI
import WebKit

/// Serves `collie-preview://app/<path>` from the panel's project: only what `PreviewFile.servable` allows (no dot-path,
/// nothing outside the root, no symlink out), read without following links (`DiagramFile.readData`), at most 8 MiB.
/// Everything else is a 404 with an empty body. The page is agent-written: untrusted. Files are read off the main
/// thread; a request stopped meanwhile gets no reply.
@MainActor final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "collie-preview"
    let root: URL
    /// The requests started and not stopped nor answered (main thread only).
    private var live: Set<ObjectIdentifier> = []
    init(root: URL) { self.root = root }

    nonisolated static func serve(_ r: URLRequest, root: URL) -> (Int, String, Data) {
        guard (r.httpMethod ?? "GET") == "GET", let url = r.url, url.host == "app",
              let file = PreviewFile.servable(url.path(percentEncoded: true), projectRoot: root),
              let data = (try? DiagramFile.readData(file, root: root, noun: "página")) ?? nil else { return (404, "text/plain", Data()) }
        return (200, PreviewFile.contentType(file.pathExtension), data)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task), request = task.request, root = root
        live.insert(id)
        Task { [weak self] in
            let r = await Task.detached { Self.serve(request, root: root) }.value
            guard let self, self.live.remove(id) != nil else { return }
            Self.reply(task, r)
        }
    }
    private static func reply(_ task: any WKURLSchemeTask, _ r: (Int, String, Data)) {
        let (status, type, data) = r
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }
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
    /// The artifact **Salvar como artifact** made of the page since it last changed on disk (`Importar no Design` reuses it).
    /// ponytail: kept by the view, not in the panel's state (no command updates a panel's state from the app); a relaunch
    /// saves again.
    private(set) var saved: String?
    /// The artifact shown (artifact mode): the panel's own, or another of its presentation folder (**Anterior / Próxima**),
    /// and that folder's pages in order (empty: not a presentation).
    /// ponytail: kept by the view, not the panel's state; comments stay the panel's own artifact's (hidden on the others).
    private(set) var shown: String?
    private(set) var sequence: [String] = []
    /// The key monitor while presenting (full screen: arrows step, Esc ends).
    private var keys: Any?
    /// Pins and threads (plan 2W): the app's comments on this page.
    lazy var comments = PreviewComments(host: host, page: PreviewComments.page(of: panel), title: { [weak self] in self?.header.file ?? "" })

    /// Errors and theme live in a world of their own: the page can't reach the message handler. It can still dispatch a
    /// fake `ErrorEvent` or stop the real ones (DOM events are shared): the errors are diagnostics, not evidence.
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

    /// The offline libraries served as `collie-lib://` (tests pass their own).
    private let libs: URL?

    public required convenience init(panel: Panel, host: PanelHostContext) { self.init(panel: panel, host: host, libs: WebLibs.directory) }

    init(panel: Panel, host: PanelHostContext, libs: URL?) {
        self.panel = panel; self.host = host; self.libs = libs
        super.init()
        box.owner = self
        header.onReload = { [weak self] in self?.reload(keepScroll: true) }
        header.onTheme = { [weak self] in self?.setTheme($0) }
        header.onSave = { [weak self] in Task { await self?.save() } }
        header.onImport = { [weak self] in Task { await self?.importToDesign() } }
        header.onStep = { [weak self] in self?.step($0) }
        header.onPresent = { [weak self] in self?.present() }
        header.canSave = artifactId == nil
        box.setHeader(header)
        header.canComment = comments.page != nil
        header.onComments = { [weak self] in guard let c = self?.comments else { return }; c.drawer.toggle(); if !c.drawer { c.setMode(false) } }
        comments.onLayout = { [weak box] in box?.needsLayout = true }
        comments.onCount = { [weak header] in header?.comments = $0 }
        box.setDrawer(comments)
    }

    func string(_ k: String) -> String? { if case .string(let s)? = panel.state[k], !s.isEmpty { s } else { nil } }
    var projectRoot: URL? { string("root").map { URL(fileURLWithPath: $0) } }
    var artifactId: String? { string("artifact") }

    /// The panel's screenshots go with it; the page stays (it belongs to the project).
    public static func panelRemoved(_ panel: Panel, host: PanelHostContext) {
        DiagramPanel.panelRemoved(panel, host: host)
    }

    /// `preview.get`, `preview.screenshot` (agents, through `ui.host`); a panel never shown starts its view first.
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        switch command {
        case "preview.get":
            return .object(["file": header.file.flatMap { file == nil ? nil : .string($0) } ?? .null,
                            "url": pageURL.map { .string($0.absoluteString) } ?? .null,
                            "errors": .array(errors.map { .string($0) })])
        case "preview.screenshot":
            startIfNeeded()
            let deadline = Date().addingTimeInterval(25)
            while loads == 0, failure == nil, !closed, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard let web = webView, loads > 0 else { throw ProtocolError(code: .unavailable, message: failure ?? "a prévia não carregou a página") }
            let cg = args["full-page"] == .bool(true) ? try await BrowserPanel.fullPage(web) : try await BrowserPanel.snapshot(web, rect: nil)
            let dir = host.root.appendingPathComponent("screens", isDirectory: true), prefix = panel.id.uuidString + "-"
            return try await DiagramPanel.offMain { BrowserPanel.savePNG(cg, in: dir, prefix: prefix) }.get()
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
        }
    }

    /// `comment.changed` (any page: the list is small): the threads and pins again.
    public func receive(event: String, payload: JSONValue) {
        guard event == "comment.changed" else { return }
        Task { await comments.refresh() }
    }

    public func close() {
        endPresent()
        closed = true
        comments.web = nil
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
        Task { await comments.refresh() }
        box.overlay("Abrindo…")
        if let id = artifactId {
            header.file = "artifact"
            Task { [weak self] in await self?.show(id) }
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

    /// Artifact `id` shown: its page, title and folder, and its folder's order when that is a presentation.
    func show(_ id: String) async {
        let url: URL
        do throws(ProtocolError) {
            let a = try await host.call("artifact.get", ["id": .string(id)])
            guard case .object(let o) = a, case .string(let s)? = o["url"], let u = URL(string: s),
                  u.scheme == BrowserPanel.artifactScheme, u.host == "app" else { return fail("Artifact sem página") }
            if case .string(let t)? = o["title"] { header.file = t }
            let folder: String? = if case .string(let f)? = o["folder"] { f } else { nil }
            header.folder = folder
            sequence = []
            if let folder, case .array(let fs) = try await host.call("artifact.folders", [:]) {
                for case .object(let f) in fs {
                    guard case .string(let p)? = f["path"], p.caseInsensitiveCompare(folder) == .orderedSame, f["presentation"] == .bool(true),
                          case .array(let items)? = f["items"] else { continue }
                    sequence = items.compactMap { if case .string(let i) = $0 { i } else { nil } }
                }
            }
            url = u
        } catch { return fail(error.message) }
        guard !closed else { return }
        shown = id
        header.canPrevious = Self.neighbor(sequence, of: id, by: -1) != nil
        header.canNext = Self.neighbor(sequence, of: id, by: 1) != nil
        header.canPresent = sequence.contains(id)
        header.canComment = comments.page != nil && id == artifactId
        if id != artifactId, comments.drawer { comments.drawer = false; comments.setMode(false) }
        if let web = webView { pageURL = url; web.load(URLRequest(url: url)) } else { open(url) }
    }

    /// The page `by` places from `id` in `items` (nil: none there).
    nonisolated static func neighbor(_ items: [String], of id: String, by step: Int) -> String? {
        guard let i = items.firstIndex(of: id), items.indices.contains(i + step) else { return nil }
        return items[i + step]
    }

    /// **Anterior / Próxima** (and the arrows while presenting).
    func step(_ by: Int) {
        guard let id = shown, let next = Self.neighbor(sequence, of: id, by: by) else { return }
        Task { await show(next) }
    }

    /// **Apresentar**: the page full screen; ← → step through the folder, Esc ends.
    func present() {
        guard let web = webView, !web.isInFullScreenMode, let screen = box.window?.screen ?? NSScreen.main else { return }
        web.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false])
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch code {
                case 53: self.endPresent()   // Esc
                case 123: self.step(-1)
                case 124: self.step(1)
                default: return false
                }
                return true
            }
            return handled ? nil : e
        }
    }
    func endPresent() {
        if let k = keys { NSEvent.removeMonitor(k); keys = nil }
        if let web = webView, web.isInFullScreenMode { web.exitFullScreenMode(options: nil) }
        box.needsLayout = true
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
        if artifactId == nil, let root = projectRoot { config.setURLSchemeHandler(PreviewSchemeHandler(root: root), forURLScheme: PreviewSchemeHandler.scheme) }
        config.setURLSchemeHandler(DesignSchemeHandler(root: host.root.appendingPathComponent("artifacts"), artifacts: true),
                                   forURLScheme: BrowserPanel.artifactScheme)
        config.setURLSchemeHandler(WebLibSchemeHandler(directory: libs, bundledFonts: WebLibs.fontsDirectory,
                                                            downloadedFonts: host.root.appendingPathComponent("fonts")), forURLScheme: WebLibs.scheme)
        config.userContentController.add(rules)
        config.userContentController.add(Bridge(self), contentWorld: Self.world, name: "colliePreview")
        config.userContentController.add(PreviewComments.Bridge(comments), contentWorld: PreviewComments.world, name: "collieComments")
        installScripts(config.userContentController)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web; box.web = web; comments.web = web
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
        // document start (not end): its capturing click listener comes before the page's own window listeners
        c.addUserScript(WKUserScript(source: PreviewComments.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: PreviewComments.world))
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
        saved = nil
        reload(keepScroll: true)
    }

    // MARK: out of the panel

    /// `artifact.add`'s arguments for the page: its absolute path, its `<title>` (else the file name), its folder as
    /// `root` (the files it links) unless that is the project root, and `nofollow`. Refused when the page no longer
    /// resolves to the same file (a folder swapped for a link) or can't be read without following one.
    func saveArgs() throws(ProtocolError) -> [String: JSONValue] {
        guard let file, let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "a prévia não tem página") }
        let moved = ProtocolError(code: .invalidArgs, message: "a pasta da página mudou (link simbólico?): reabra a prévia")
        guard try PreviewFile.resolve(string("file") ?? "", projectRoot: root) == file,
              DiagramFile.real(file.deletingLastPathComponent()) == file.deletingLastPathComponent() else { throw moved }
        guard let data = try DiagramFile.readData(file, root: root, noun: "página") else { throw ProtocolError(code: .notFound, message: "Arquivo removido") }
        var args: [String: JSONValue] = ["path": .string(file.path), "title": .string(file.lastPathComponent), "nofollow": .bool(true)]
        if let f = string("folder") { args["folder"] = .string(f) }   // `artifact new --folder`
        if let m = String(decoding: data, as: UTF8.self).firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/) {
            let t = m.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { args["title"] = .string(String(t.prefix(200))) }
        }
        let folder = file.deletingLastPathComponent()
        if folder.path != DiagramFile.real(root).path { args["root"] = .string(folder.path) }
        return args
    }

    /// **Salvar como artifact**: `artifact.add` (its import starts in the background); the id kept for `importToDesign`.
    @discardableResult func save() async -> String? {
        guard header.canSave, !header.busy else { return nil }
        header.error = nil; header.busy = true
        defer { header.busy = false }
        do throws(ProtocolError) {
            guard case .object(let o) = try await host.call("artifact.add", try saveArgs()), case .string(let id)? = o["id"] else {
                header.error = "Resposta inválida do Collie"; return nil
            }
            saved = id
            flash("Salvo como artifact")
            return id
        } catch { header.error = error.message; return nil }
    }

    /// **Importar no Design**: the saved artifact (saved now if the page changed since), imported as a design screen, then
    /// a Design panel on the new file.
    func importToDesign() async {
        guard header.canSave, !header.busy else { return }
        let id: String
        if let s = saved { id = s } else { guard let s = await save() else { return }; id = s }
        header.error = nil; header.busy = true; header.note = "Importando…"
        defer { header.busy = false }
        do throws(ProtocolError) {
            guard case .object(let o) = try await host.call("artifact.import", ["id": .string(id)]), case .string(let f)? = o["file"] else {
                header.note = nil; header.error = "Resposta inválida do Collie"; return
            }
            _ = try await host.call("panel.open", ["plugin": .string("design"), "file": .string(f)])
            flash("Importado no Design: \(f)")
        } catch { header.note = nil; header.error = error.message }
    }

    private func flash(_ m: String) {
        header.note = m
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.header.note == m { self?.header.note = nil }
        }
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
        private var drawer: NSView?
        private weak var comments: PreviewComments?
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
        func setDrawer(_ c: PreviewComments) {
            let d = NSHostingView(rootView: PreviewCommentsDrawer(m: c))
            addSubview(d); drawer = d; comments = c
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
            let side: CGFloat = comments?.drawer == true ? 300 : 0
            drawer?.isHidden = side == 0
            card.frame = CGRect(x: 12, y: top + 12, width: max(0, bounds.width - 24 - side), height: max(0, bounds.height - top - 24))
            drawer?.frame = CGRect(x: bounds.width - side, y: top, width: side, height: max(0, bounds.height - top))
            if web?.isInFullScreenMode != true { web?.frame = card.bounds }
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
    /// A project page (not an artifact): **Salvar como artifact** and **Importar no Design** show.
    @Published var canSave = false
    @Published var busy = false
    /// A short confirmation ("Salvo como artifact", "Importando…") and the last action's error.
    @Published var note: String?
    @Published var error: String?
    var onReload: () -> Void = {}
    var onTheme: (String?) -> Void = { _ in }
    var onSave: () -> Void = {}
    var onImport: () -> Void = {}
    /// Open comments on the page; **Comentários (n)** shows when the page can take comments.
    @Published var comments = 0
    @Published var canComment = false
    var onComments: () -> Void = {}
    /// The artifact's folder; a presentation's **Anterior / Próxima** and **Apresentar**.
    @Published var folder: String?
    @Published var canPrevious = false
    @Published var canNext = false
    @Published var canPresent = false
    var onStep: (Int) -> Void = { _ in }
    var onPresent: () -> Void = {}
}

/// The file (relative to the project), a status over the last render, **Recarregar**, `Página | Claro | Escuro` and, for a
/// project page, **Salvar como artifact** / **Importar no Design**.
private struct PreviewHeader: View {
    @ObservedObject var m: PreviewHeaderModel
    var body: some View {
        PanelHeader("Prévia", subtitle: m.folder.map { "\($0) · \(m.file ?? "")" } ?? m.file) {
            HStack(spacing: 8) {
                if m.canPrevious || m.canNext {
                    Button("Anterior") { m.onStep(-1) }.disabled(!m.canPrevious).buttonStyle(CollieButtonStyle(.secondary))
                    Button("Próxima") { m.onStep(1) }.disabled(!m.canNext).buttonStyle(CollieButtonStyle(.secondary))
                }
                if m.canPresent { Button("Apresentar") { m.onPresent() }.buttonStyle(CollieButtonStyle(.secondary)).help("Tela cheia; setas avançam, Esc sai") }
                if let s = m.status { Text(s).font(.collieMono(11, .medium)).foregroundStyle(Color.collieAttention) }
                if let e = m.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger).lineLimit(2).help(e) }
                if m.busy { ProgressView().controlSize(.small) }
                if let n = m.note { Text(n).font(.collieMono(11, .medium)).foregroundStyle(Color.collieAccent) }
                if m.canSave {
                    Button("Salvar como artifact") { m.onSave() }.disabled(m.busy).buttonStyle(CollieButtonStyle(.secondary))
                    Button("Importar no Design") { m.onImport() }.disabled(m.busy).buttonStyle(CollieButtonStyle(.secondary))
                }
                Picker("Tema", selection: Binding(get: { m.theme ?? "" }, set: { m.onTheme($0.isEmpty ? nil : $0) })) {
                    Text("Página").tag(""); Text("Claro").tag("light"); Text("Escuro").tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if m.canComment { Button("Comentários (\(m.comments))") { m.onComments() }.buttonStyle(CollieButtonStyle(.secondary)) }
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
    /// Camera and microphone: never (no prompt either).
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { errors = [] }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loads += 1
        if shown == nil || shown == artifactId { Task { await comments.drawPins() } }   // re-anchored on the page just loaded
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
