import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import WebKit

/// Serves `collie-plugin://<id>/<path>` from an installed plug-in's `ui/` folder: GET only, its own host only, a
/// regular file inside the folder (no `..`, no link out), a MIME type by extension, and a CSP that keeps the page to
/// its own origin.
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "collie-plugin"
    static let types = ["html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "js": "text/javascript", "mjs": "text/javascript",
                        "css": "text/css", "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
                        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon", "woff": "font/woff",
                        "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8",
                        "md": "text/markdown; charset=utf-8", "csv": "text/csv; charset=utf-8"]
    /// Belt and braces with the rule list: nothing but this origin (and inline/data/blob, which stay local).
    static let csp = "default-src 'self' 'unsafe-inline' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; connect-src 'self'; frame-src 'self'; form-action 'none'; base-uri 'none'"
    let id: String
    let root: URL
    /// An app do cercado's `ui/` files, read and checked against its pin once (`PluginManifest.appFiles`): served from
    /// here, never from the paddock folder, which the agent may be editing.
    let files: [String: Data]?

    init(id: String, uiRoot: URL) { self.id = id; root = uiRoot.standardizedFileURL.resolvingSymlinksInPath(); files = nil }
    init(id: String, files: [String: Data]) { self.id = id; root = URL(fileURLWithPath: "/"); self.files = files }

    func serve(_ r: URLRequest) -> (Int, String, Data) {
        guard (r.httpMethod ?? "GET") == "GET" else { return (405, "text/plain", Data()) }
        guard let url = r.url, url.scheme?.lowercased() == Self.scheme, url.host == id else { return (404, "text/plain", Data()) }
        if let files {   // `path` is percent-decoded and absolute; only an exact name in the pinned set answers
            guard let d = files["ui" + url.path] else { return (404, "text/plain", Data()) }
            return (200, Self.types[(url.path as NSString).pathExtension.lowercased()] ?? "application/octet-stream", d)
        }
        // `path` is percent-decoded: `%2e%2e` is `..` here, and standardizing removes it
        let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"),
              (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (404, "text/plain", Data()) }
        return (200, Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream", data)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let (status, type, data) = serve(task.request)
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": "\(data.count)", "Content-Security-Policy": Self.csp,
                "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"]) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered synchronously in `start`
}

/// The panel of an external (web UI) plug-in: its installed `ui/` in a web view with every network load blocked
/// (`WKContentRuleList` + CSP + navigation policy), a non-persistent data store, and `window.collie` (page API v1,
/// `WebPluginBridge`) as its only way out. Output files: written by this host from the page's bytes into
/// `<root>/plugins-out/<id>/` under a name it makes (R6). Agent commands (`<id>.<cmd>`) arrive through `handle` and go to the page's
/// `collie.onCommand`. The page sees only those command args: no agent text, terminal ids, tokens or root paths
/// (`files.output` hands it an opaque `collie-output://` path that the command result swaps for the real file).
/// When the plug-in is not installed (never, removed, disabled) the panel shows a placeholder and keeps its state;
/// when the registry changes it follows: a new version reloads, a removal fails the calls in flight (`unavailable`).
@MainActor public final class WebPluginPanel: NSObject, PluginPanelView {
    static let resultCap = 1 << 20, stateCap = 256 * 1024, outputCap = 16 << 20, payloadCap = 64 * 1024, outputsKept = 200, outputDayCap = 64 << 20, crashesAllowed = 3
    static let outputExtensions: Set<String> = ["png", "svg", "json", "txt", "md", "csv", "html"]
    static let outputScheme = "collie-output://"
    let panel: Panel
    let host: PanelHostContext
    private let box = Box()
    private(set) var webView: WKWebView?
    /// The installed version the page runs; nil: placeholder.
    private(set) var version: String?
    private(set) var ready = false
    private var gen = 0
    private var pending: [String: CheckedContinuation<Result<String, ProtocolError>, Never>] = [:]
    /// `files.output` handles this page made (token → file under `screens/`).
    private var outputs: [String: URL] = [:]
    private var observer: (any NSObjectProtocol)?
    /// Web content process deaths of this page (reset by a version load); past `crashesAllowed` it is left as a placeholder.
    private var crashes = 0
    public var view: NSView { box }

    public required init(panel: Panel, host: PanelHostContext) {
        self.panel = panel; self.host = host
        super.init()
        box.owner = self
        observer = NotificationCenter.default.addObserver(forName: PluginRegistry.externalChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: lifecycle

    private var spec: PluginSpec? { PluginRegistry.spec(panel.pluginId).flatMap { $0.source == .builtIn ? nil : $0 } }
    private var title: String { spec?.title ?? panel.pluginId }

    /// Follows the registry: the installed version loads (again, if it changed); a missing plug-in shows the placeholder.
    func refresh() {
        guard let spec, case .external(let v0) = spec.source else {
            teardown("plug-in removido")
            return box.placeholder("Plug-in \(panel.pluginId) não está instalado")
        }
        let v = spec.uiURL.map { v0 + "|" + $0 } ?? spec.appPin.map { v0 + "|" + $0 } ?? v0   // an app's page moves with its URL or pin too
        guard v != version else { return }
        teardown("plug-in atualizado")
        crashes = 0
        if let ui = spec.uiURL, let base = spec.serviceBase, let page = URL(string: ui) {   // an app do cercado: its own service
            version = v
            return load(title: spec.title, id: spec.id, page: page, origin: base)
        }
        if let dir = spec.appFolder, let pin = spec.appPin {   // an app do cercado's ui/ file: the bytes the user approved
            guard let (files, sha) = try? PluginManifest.appFiles(URL(fileURLWithPath: dir)), sha == pin,
                  let data = files[PluginManifest.fileName], let m = try? PluginManifest.decode(data), m.id == spec.id, !m.uiIsURL else {
                return box.placeholder("\(spec.title) mudou depois da aprovação: aprove de novo (collie app attach \(spec.id))")
            }
            version = v
            return load(title: m.name, id: m.id, page: URL(string: "\(PluginSchemeHandler.scheme)://\(m.id)/\(m.ui.dropFirst("ui/".count))")!,
                        files: files, app: true)
        }
        let folder = host.root.appendingPathComponent("plugins").appendingPathComponent(spec.id).appendingPathComponent(v)
        guard let m = try? PluginManifest.load(folder: folder), m.id == spec.id, m.version == v else {
            return box.placeholder("Plug-in \(spec.title) não pôde ser carregado")
        }
        version = v
        load(title: m.name, id: m.id, page: URL(string: "\(PluginSchemeHandler.scheme)://\(m.id)/\(m.ui.dropFirst("ui/".count))")!,
             folder: folder)
    }

    /// The app do cercado's service origin while its page is loaded; nil: an installed plug-in's own `ui/`, or an
    /// app's `ui/` file page (`isApp`).
    private(set) var origin: String?
    /// An app do cercado's page (URL or `ui/` file): `collie.context` and `app.snapshot` are for these only.
    private(set) var isApp = false

    /// `folder`: an installed plug-in's, served by `PluginSchemeHandler`; `origin`: an app's loopback service, the only
    /// origin its rule list lets through and the only one that gets the bridge.
    private func load(title: String, id: String, page: URL, folder: URL? = nil, files: [String: Data]? = nil, origin: String? = nil, app: Bool = false) {
        gen += 1
        let g = gen
        self.origin = origin
        isApp = app || origin != nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        WebLockdown.harden(config)   // WebRTC off: ICE gets past the rule list and the CSP
        if let folder {
            config.setURLSchemeHandler(PluginSchemeHandler(id: id, uiRoot: folder.appendingPathComponent("ui")), forURLScheme: PluginSchemeHandler.scheme)
        } else if let files {
            config.setURLSchemeHandler(PluginSchemeHandler(id: id, files: files), forURLScheme: PluginSchemeHandler.scheme)
        }
        let ucc = config.userContentController
        ucc.addScriptMessageHandler(Bridge(self), contentWorld: .page, name: WebPluginBridge.handler)
        ucc.addUserScript(WKUserScript(source: WebPluginBridge.script(theme: themeJSON(), origin: origin), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: box.bounds, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web
        box.show(web)
        Task { [weak self] in
            let rules = if let origin { await Self.rules(origin: origin) } else { await Self.rules() }
            guard let self, self.gen == g, let web = self.webView else { return }
            guard let rules else { self.teardown("bloqueio de rede indisponível"); return self.box.placeholder("Plug-in \(title): bloqueio de rede indisponível") }
            web.configuration.userContentController.add(rules)
            // fail closed: the WebRTC switch is private, so check it took before the page exists
            guard await WebLockdown.peerConnectionsOff(web), self.gen == g else {
                if self.gen == g { self.teardown(WebLockdown.failure); self.box.placeholder("Plug-in \(title): \(WebLockdown.failure)") }
                return
            }
            web.load(URLRequest(url: page))   // only after the rules: no load ever runs unblocked
        }
    }

    /// Fails the calls in flight with `why` and drops the page (state stays on disk).
    private func teardown(_ why: String) {
        gen += 1
        for (_, c) in pending { c.resume(returning: .failure(ProtocolError(code: .unavailable, message: why))) }
        pending = [:]
        ready = false; version = nil; origin = nil; isApp = false; outputs = [:]   // files stay (plugins-out keeps the newest `outputsKept`)
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.removeFromSuperview()
        webView = nil
    }

    public func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        teardown("painel fechado")
    }

    public static func panelRemoved(_ panel: Panel, host: PanelHostContext) {
        try? FileManager.default.removeItem(at: stateFile(panel, root: host.root))
        let dir = outputDir(panel, root: host.root), prefix = panel.id.uuidString + "-"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    // MARK: network rules

    /// Every load blocked but this scheme (and local data/blob URLs). Content-blocker regexes have no `|`: one rule each.
    static let ruleJSON = #"""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^collie-plugin:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
        """#
    private static var compiled: WKContentRuleList?
    static func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "collie-plugin-offline", encodedContentRuleList: ruleJSON)
        compiled = list
        return list
    }

    /// An app do cercado's page: every load blocked but its service's origin (and local data/blob URLs). One list per
    /// origin, compiled once.
    static func ruleJSON(origin: String) -> String {
        // an origin holds letters, digits, ':', '/', '.', and '[' ']' (IPv6): only these three are regex syntax
        let esc = (origin + "/").replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
        let filter = (try? enc.encode("^" + esc)).map { String(decoding: $0, as: UTF8.self) } ?? "\"^$\""
        return """
            [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
             {"trigger":{"url-filter":\(filter)},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
            """
    }
    private static var compiledApps: [String: WKContentRuleList] = [:]
    static func rules(origin: String) async -> WKContentRuleList? {
        if let r = compiledApps[origin] { return r }
        let ident = "collie-app-" + origin.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ident, encodedContentRuleList: ruleJSON(origin: origin))
        compiledApps[origin] = list
        return list
    }
    /// `http://127.0.0.1:4100`-form origin of `url`; nil: none.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(h)" + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: commands

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        if command == "app.snapshot" { return try await snapshot() }
        let removed = ProtocolError(code: .unavailable, message: "plug-in removido")
        guard let (p, cmd) = PluginRegistry.command(command), p.id == panel.pluginId, case .external(let v) = p.source else {
            throw ProtocolError(code: .unavailable, message: "plug-in \(panel.pluginId) não está instalado")
        }
        if v != version { refresh() }   // the registry moved on before its notification ran: never the old page
        guard version != nil else { throw ProtocolError(code: .unavailable, message: "plug-in \(panel.pluginId) não pôde ser carregado") }
        let seconds = cmd.timeoutSeconds ?? 30
        let deadline = ContinuousClock.now + .seconds(seconds)
        let timedOut = ProtocolError(code: .timeout, message: "'\(command)' não respondeu em \(Int(seconds)) s")
        while !ready {   // the page registers its handler after loading
            guard webView != nil else { throw removed }
            guard ContinuousClock.now < deadline else { throw timedOut }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let web = webView, let argsJSON = try? JSONEncoder().encode(args) else { throw removed }
        let id = UUID().uuidString, name = String(command.dropFirst(p.id.count + 1))
        let r: Result<String, ProtocolError> = await withCheckedContinuation { c in
            pending[id] = c
            web.callAsyncJavaScript("window.__collieDispatch(id, name, JSON.parse(args))",
                                    arguments: ["id": id, "name": name, "args": String(decoding: argsJSON, as: UTF8.self)],
                                    in: nil, in: .page) { [weak self] res in
                if case .failure = res { self?.finish(id, .failure(ProtocolError(code: .unavailable, message: "a página do plug-in não respondeu"))) }
            }
            Task { [weak self] in
                try? await Task.sleep(until: deadline)
                self?.finish(id, .failure(timedOut))
            }
        }
        let text = try r.get()
        guard text.utf8.count <= Self.resultCap else { throw ProtocolError(code: .invalidArgs, message: "resultado do plug-in maior que 1 MiB") }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw ProtocolError(code: .internal, message: "resultado do plug-in não é JSON")
        }
        return try outputPath(value, outputFile: cmd.outputFile)
    }

    /// Slice 3 (`collie app snapshot`): an app's page as rendered now, read by `HTMLSnapshotScript` in the isolated
    /// `.defaultClient` world (the page's JS can't touch it). Payloads and styles are dropped: text, boxes, links,
    /// alt; ≤ 1 MiB.
    func snapshot() async throws(ProtocolError) -> JSONValue {
        guard isApp, let web = webView else { throw ProtocolError(code: .unavailable, message: "o painel não mostra a página de um app agora") }
        let late = ProtocolError(code: .timeout, message: "a página não terminou o snapshot em 15 s")
        let id = UUID().uuidString
        let r: Result<String, ProtocolError> = await withCheckedContinuation { c in
            pending[id] = c
            web.callAsyncJavaScript(HTMLSnapshotScript.source, arguments: [:], in: nil, in: .defaultClient) { [weak self] res in
                switch res {
                case .success(let v as String): self?.finish(id, .success(v))
                default: self?.finish(id, .failure(ProtocolError(code: .internal, message: "o snapshot da página falhou")))
                }
            }
            Task { [weak self] in try? await Task.sleep(for: .seconds(15)); self?.finish(id, .failure(late)) }
        }
        guard case .object(var o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(try r.get().utf8)) else {
            throw ProtocolError(code: .internal, message: "snapshot inválido")
        }
        o["root"] = o["root"].map(Self.lean)
        let v = JSONValue.object(o)
        guard ((try? JSONEncoder().encode(v).count) ?? Int.max) <= Self.resultCap else { throw ProtocolError(code: .invalidArgs, message: "snapshot maior que 1 MiB") }
        return v
    }

    /// A snapshot node without its style and payloads (image bytes, svg markup).
    nonisolated static func lean(_ v: JSONValue) -> JSONValue {
        guard case .object(var n) = v else { return v }
        n["style"] = nil
        if case .object(var img)? = n["image"] { img["data"] = nil; n["image"] = .object(img) }
        if n["svg"] != nil { n["svg"] = .string("[svg]") }
        if case .array(let cs)? = n["children"] { n["children"] = .array(cs.map(lean)) }
        return .object(n)
    }

    private func finish(_ id: String, _ r: Result<String, ProtocolError>) { pending.removeValue(forKey: id)?.resume(returning: r) }

    /// A result's `path` that is one of this page's `files.output` handles becomes the real file (so the daemon hands
    /// it over); an `outputFile` command's `path` must be one.
    private func outputPath(_ v: JSONValue, outputFile: Bool) throws(ProtocolError) -> JSONValue {
        guard case .object(var o) = v, case .string(let p)? = o["path"] else { return v }
        if p.hasPrefix(Self.outputScheme), let f = outputs[String(p.dropFirst(Self.outputScheme.count))], FileManager.default.fileExists(atPath: f.path) {
            o["path"] = .string(f.path)
            return .object(o)
        }
        if outputFile { throw ProtocolError(code: .invalidArgs, message: "o path do resultado precisa vir de collie.files.output") }
        return v
    }

    // MARK: page messages

    /// One `window.collie` call: (reply, error). Only the main frame of this plug-in's own origin is heard.
    func message(_ m: WKScriptMessage) async -> (Any?, String?) {
        let so = m.frameInfo.securityOrigin
        let own = if let origin {   // an app: its service's origin only
            Self.origin(of: URL(string: "\(so.protocol)://\(so.host.contains(":") ? "[\(so.host)]" : so.host)" + (so.port == 0 ? "" : ":\(so.port)"))) == origin
        } else { so.protocol == PluginSchemeHandler.scheme && so.host == panel.pluginId }
        guard m.frameInfo.isMainFrame, own, m.webView === webView,
              let body = m.body as? [String: Any], let op = body["op"] as? String else { return (nil, "chamada inválida") }
        func str(_ k: String) -> String? { body[k] as? String }
        switch op {
        case "ready":
            ready = true
            return (true, nil)
        case "result":
            guard let id = str("id"), let ok = body["ok"] as? Bool, let value = str("value") else { return (nil, "resultado inválido") }
            finish(id, ok ? .success(value)
                       : .failure(ProtocolError(code: .invalidArgs, message: "plug-in: " + String(value.prefix(500)).filter { !$0.isNewline })))
            return (true, nil)
        case "emit":
            guard let event = str("event"), spec?.events.contains(event) == true else { return (nil, "evento não declarado no manifesto") }
            guard let raw = str("payload"), raw.utf8.count <= Self.payloadCap,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return (nil, "payload inválido ou maior que 64 KiB") }
            host.emit(event, payload)
            return (true, nil)
        case "context":   // slice 3: an app's page only; the daemon keeps it for `collie app context`
            guard isApp else { return (nil, "collie.context é só para apps do cercado") }
            guard let raw = str("value"), raw.utf8.count <= 16 * 1024,
                  let v = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return (nil, "contexto inválido ou maior que 16 KiB") }
            do throws(ProtocolError) { _ = try await host.call("admin.app.context", ["panel": .string(panel.id.uuidString), "context": v]) }
            catch { return (nil, error.message) }
            return (true, nil)
        case "state.get":
            let f = Self.stateFile(panel, root: host.root)
            return (((try? String(contentsOf: f, encoding: .utf8)) ?? "{}"), nil)
        case "state.set":
            guard let raw = str("value"), raw.utf8.count <= Self.stateCap else { return (nil, "estado maior que 256 KiB") }
            guard case .object? = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return (nil, "o estado precisa ser um objeto") }
            do { try Self.writePrivate(Data(raw.utf8), to: Self.stateFile(panel, root: host.root)) } catch { return (nil, "não foi possível gravar o estado") }
            return (true, nil)
        case "files.output":
            guard let name = str("name"), Self.validOutputName(name) else {
                return (nil, "nome inválido: letras, dígitos, . _ -, extensão png|svg|json|txt|md|csv|html")
            }
            guard let b64 = str("data"), b64.utf8.count <= Self.outputCap / 3 * 4 + 4, let data = Data(base64Encoded: b64), data.count <= Self.outputCap else {
                return (nil, "arquivo inválido (base64) ou maior que 16 MiB")
            }
            guard Self.chargeOutput(panel.pluginId, data.count) else { return (nil, "limite de 64 MiB de arquivos por dia atingido") }
            let token = UUID().uuidString
            guard let file = Self.writeOutput(data, name: "\(panel.id.uuidString)-\(token)-\(name)", panel: panel, root: host.root) else {
                return (nil, "não foi possível gravar o arquivo")
            }
            outputs[token] = file
            Self.pruneOutputs(Self.outputDir(panel, root: host.root))
            return ("{\"path\":\"\(Self.outputScheme)\(token)\"}", nil)
        default:
            return (nil, "operação desconhecida")
        }
    }

    /// `<root>/plugins-out/<id>/<name>`: both dirs made 0700 and checked real dirs (a link there is refused, never
    /// followed), the file created new (O_EXCL, O_NOFOLLOW), 0600. nil: refused or failed.
    static func writeOutput(_ data: Data, name: String, panel: Panel, root: URL) -> URL? {
        let out = root.appendingPathComponent("plugins-out", isDirectory: true), dir = outputDir(panel, root: root)
        for d in [out, dir] {
            if mkdir(d.path, 0o700) != 0 && errno != EEXIST { return nil }
            guard (try? FileManager.default.attributesOfItem(atPath: d.path)[.type] as? FileAttributeType) == .typeDirectory else { return nil }   // lstat
        }
        let file = dir.appendingPathComponent(name)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        let ok = data.withUnsafeBytes { b in b.count == 0 || write(fd, b.baseAddress, b.count) == b.count }
        if !ok { unlink(file.path); return nil }
        return file
    }

    /// The plug-in's newest `outputsKept` files stay (all its panels); older ones go.
    static func pruneOutputs(_ dir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path), names.count > outputsKept else { return }
        func mtime(_ n: String) -> Date { ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.modificationDate] as? Date) ?? .distantPast }
        for n in names.map({ ($0, mtime($0)) }).sorted(by: { $0.1 < $1.1 }).prefix(names.count - outputsKept).map(\.0) {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// `files.output` bytes per plug-in (all its panels) per calendar day: at most `outputDayCap`. True: charged.
    // ponytail: in memory, so an app restart resets the day's count; the 200-file prune still bounds the disk
    static func chargeOutput(_ id: String, _ n: Int, now: Date = Date()) -> Bool {
        let day = Calendar.current.startOfDay(for: now)
        let used = outputDay[id].flatMap { $0.day == day ? $0.bytes : nil } ?? 0
        guard used + n <= outputDayCap else { return false }
        outputDay[id] = (day, used + n)
        return true
    }
    private static var outputDay: [String: (day: Date, bytes: Int)] = [:]
    static func validOutputName(_ n: String) -> Bool {
        (try? Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}").wholeMatch(in: n)) != nil && outputExtensions.contains((n as NSString).pathExtension.lowercased())
    }
    /// Where the host writes this plug-in's `files.output` files (the router hands over only these, R6).
    static func outputDir(_ panel: Panel, root: URL) -> URL {
        root.appendingPathComponent("plugins-out", isDirectory: true).appendingPathComponent(panel.pluginId, isDirectory: true)
    }
    static func stateFile(_ panel: Panel, root: URL) -> URL {
        root.appendingPathComponent("plugin-data").appendingPathComponent(panel.pluginId).appendingPathComponent("\(panel.id.uuidString).json")
    }
    /// `<root>/plugin-data/<id>/<file>`, atomic, 0600: both dirs made 0700 and opened no-follow (a link there is
    /// refused, never followed), the temp file created new (O_EXCL, O_NOFOLLOW) and renamed in that dir.
    static func writePrivate(_ data: Data, to f: URL) throws {
        let fail = CocoaError(.fileWriteUnknown)
        let idDir = f.deletingLastPathComponent(), pd = idDir.deletingLastPathComponent(), root = pd.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw fail }
        for c in [pd.lastPathComponent, idDir.lastPathComponent] {
            if mkdirat(fd, c, 0o700) != 0 && errno != EEXIST { Darwin.close(fd); throw fail }
            let next = openat(fd, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw fail }
            fd = next
        }
        defer { Darwin.close(fd) }
        let tmp = ".\(UUID().uuidString)"
        let t = openat(fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard t >= 0 else { throw fail }
        let ok = data.withUnsafeBytes { b in b.count == 0 || write(t, b.baseAddress, b.count) == b.count }
        Darwin.close(t)
        guard ok, renameat(fd, tmp, fd, f.lastPathComponent) == 0 else { unlinkat(fd, tmp, 0); throw fail }
    }

    // MARK: theme

    private static let tokens: [(String, KeyPath<Palette, RGB>)] = [
        ("background", \.background), ("surface", \.surface), ("sunken", \.sunken), ("raised", \.raised), ("border", \.border),
        ("border-soft", \.borderSoft), ("text", \.text), ("text-secondary", \.textSecondary), ("muted", \.muted), ("accent", \.accent),
        ("on-accent", \.onAccent), ("attention", \.attention), ("secondary", \.secondary), ("danger", \.danger)]

    /// `{scheme, tokens: {"--collie-<token>": "#rrggbb"}}` for the panel's appearance.
    func themeJSON() -> String {
        let dark = box.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = dark ? Palette.dark : Palette.light
        var t: [String: JSONValue] = [:]
        for (n, k) in Self.tokens { let c = p[keyPath: k]; t["--collie-\(n)"] = .string(String(format: "#%02x%02x%02x", c.r, c.g, c.b)) }
        let v: JSONValue = .object(["scheme": .string(dark ? "dark" : "light"), "tokens": .object(t)])
        return (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    fileprivate func appearanceChanged() {
        guard let web = webView else { return }
        web.callAsyncJavaScript("window.__collieTheme && window.__collieTheme(JSON.parse(t))", arguments: ["t": themeJSON()], in: nil, in: .page)
    }

    // MARK: view

    /// The web view, or a centered placeholder line.
    final class Box: NSView {
        weak var owner: WebPluginPanel?
        let label = NSTextField(wrappingLabelWithString: "")
        private let retryButton = NSButton(title: "Tentar de novo", target: nil, action: nil)
        private var retry: (() -> Void)?
        private var web: NSView?
        override var isFlipped: Bool { true }
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            label.alignment = .center; label.textColor = CollieColor.muted
            addSubview(label)
            retryButton.target = self; retryButton.action = #selector(retryTapped); retryButton.isHidden = true
            addSubview(retryButton)
        }
        @objc private func retryTapped() { retry?() }
        required init?(coder: NSCoder) { fatalError() }
        func show(_ v: NSView) {
            web?.removeFromSuperview(); web = v; addSubview(v); label.isHidden = true; retryButton.isHidden = true; retry = nil; needsLayout = true
        }
        /// `retry`: a Tentar de novo button under the text (the web view, if any, stays for it).
        func placeholder(_ text: String, retry: (() -> Void)? = nil) {
            if retry == nil { web?.removeFromSuperview(); web = nil } else { web?.isHidden = true }
            label.stringValue = text; label.isHidden = false
            self.retry = retry; retryButton.isHidden = retry == nil
            needsLayout = true
        }
        override func layout() {
            super.layout()
            web?.frame = bounds
            let w = max(0, min(bounds.width - 24, 360)), h = label.fittingSize.height
            label.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            let b = retryButton.fittingSize
            retryButton.frame = CGRect(x: (bounds.width - b.width) / 2, y: label.frame.maxY + 8, width: b.width, height: b.height)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = CollieColor.background.cgColor }
            owner?.appearanceChanged()
        }
    }

    /// The `collie` handler; weak, so the content controller never keeps the panel alive.
    private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        weak var owner: WebPluginPanel?
        init(_ o: WebPluginPanel) { owner = o }
        @MainActor func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) async -> (Any?, String?) {
            guard let owner else { return (nil, "painel fechado") }
            return await owner.message(m)
        }
    }
}

extension WebPluginPanel: WKNavigationDelegate, WKUIDelegate {
    /// Only this plug-in's own pages (and about:blank / srcdoc); `location = "file:…"`, `http…`, other schemes: cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let u = action.request.url
        let own = origin.map { Self.origin(of: u) == $0 } ?? (u?.scheme?.lowercased() == PluginSchemeHandler.scheme && u?.host == panel.pluginId)
        decisionHandler(own || u?.absoluteString == "about:blank" || u?.absoluteString == "about:srcdoc" ? .allow : .cancel)
    }
    /// `window.open`, `target=_blank`: never a new window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    /// Slice 5: the app's service, run by the daemon (`collie.service`): starting shows "iniciando", running reloads the
    /// page, failed shows the reason with Tentar de novo (`admin.app.restart`).
    public func receive(event: String, payload: JSONValue) {
        guard event == "collie.service", origin != nil, case .object(let o) = payload, case .string(let state)? = o["state"] else { return }
        switch state {
        case "starting":
            box.placeholder("\(title): iniciando o serviço…")   // the web view stays the panel's; running shows it again
        case "running":
            guard let web = webView else { return }
            web.isHidden = false
            box.show(web)
            web.reload()
        case "failed":
            let why: String = if case .string(let r)? = o["reason"] { r } else { "o serviço parou" }
            webView?.isHidden = true
            let host = host, panel = panel
            box.placeholder("\(title) parou: \(why)", retry: { Task { _ = try? await host.call("admin.app.restart", ["panel": .string(panel.id.uuidString)]) } })
        default: break
        }
    }

    /// An app's service that doesn't answer: the placeholder says so, with Tentar de novo.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView, let origin else { return }
        let at = origin.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        let g = gen
        webView.isHidden = true
        box.placeholder("\(title) não está respondendo em \(at)", retry: { [weak self, weak webView] in
            guard let self, self.gen == g, let webView, webView === self.webView else { return }
            webView.isHidden = false
            self.box.show(webView)
            webView.reload()
        })
    }
    /// A process death fails the calls in flight and reloads after 0.5, 1, 2 s; the fourth one leaves the placeholder.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        ready = false
        for (_, c) in pending { c.resume(returning: .failure(ProtocolError(code: .unavailable, message: "a página do plug-in parou"))) }
        pending = [:]
        crashes += 1
        guard crashes <= Self.crashesAllowed else {
            teardown("a página do plug-in parou")
            return box.placeholder("Plug-in \(title): a página parou várias vezes")
        }
        let g = gen, delay = 0.5 * pow(2, Double(crashes - 1))
        Task { [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.gen == g, let webView, webView === self.webView else { return }
            webView.reload()
        }
    }
    /// A new document in the main frame (an in-plug-in navigation, a reload): its handler isn't registered yet.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, ready else { return }
        ready = false
        for (_, c) in pending { c.resume(returning: .failure(ProtocolError(code: .unavailable, message: "a página do plug-in recarregou"))) }
        pending = [:]
    }
    /// Camera and microphone: never (motion permission is iOS-only) (the page could hand a recording out through a command result).
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
