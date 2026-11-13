import Foundation
import CollieCore
import CollieProtocol
import WebKit

/// `html.snapshot` for the daemon's importer (`HostTarget.importer`): an artifact page rendered in an offscreen
/// WKWebView (own non-persistent store, page JS on, every http/https/ws/wss/ftp load blocked by a content rule list)
/// and read back as a DOM snapshot by `HTMLSnapshotScript`. The web view is discarded after each snapshot.
///
/// The snapshot goes to files, not the reply (the host channel caps results at 1 MiB): `<artifactsRoot>/<id>/.import/`
/// (0700, replaced per run) holds `snapshot.json`, `img-<n>.png` and `svg-<n>.svg`. Reply:
/// `{file: ".import/snapshot.json", blocked: <count>, truncated}`.
///
/// Snapshot: `{title, width, height, truncated, blocked: [url], root}`. Node: `{tag, x, y, w, h, style, children}` +
/// optional `text`, `runs [{start, end, color?, fontWeight?, fontStyle?, decoration?, href?}]` (UTF-16 offsets
/// into `text`), `href`, `image {file, w, h, fit}`, `svg {file}`, `alt`, `id`, `cls`. Coordinates are page CSS px.
/// Loose text beside elements becomes a `#text` child.
@MainActor public enum HTMLSnapshotter {
    static let height = 900
    nonisolated static let importDir = ".import"
    static let ruleJSON = #"""
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]
        """#
    private static var rules: WKContentRuleList?
    /// Tests: the last snapshot's web view, to check it is released (even after a timeout).
    static weak var lastWebView: WKWebView?

    /// The `ui.host` entry point: `html.snapshot {id, url, width?}` only; deadline = the call's minus 2 s (≥ 5 s).
    public static func handle(command: String, args: [String: JSONValue], artifactsRoot: URL,
                              timeoutSeconds: Double) async throws(ProtocolError) -> JSONValue {
        guard command == "html.snapshot" else { throw ProtocolError(code: .invalidArgs, message: "unknown command: \(command)") }
        guard case .string(let rawId)? = args["id"], let id = UUID(uuidString: rawId) else {
            throw ProtocolError(code: .invalidArgs, message: "id must be an artifact id")
        }
        guard case .string(let raw)? = args["url"], let url = URL(string: raw) else {
            throw ProtocolError(code: .invalidArgs, message: "url is required")
        }
        var width = 1440
        if let w = args["width"] {
            guard case .number(let n) = w, n.rounded() == n, (320...3840).contains(n) else {
                throw ProtocolError(code: .invalidArgs, message: "width must be an integer in 320…3840")
            }
            width = Int(n)
        }
        let out = try importFolder(artifactsRoot, id)
        let snap = try await snapshot(url: url, artifactsRoot: artifactsRoot, width: width,
                                      timeout: .milliseconds(Int(max(5, timeoutSeconds - 2) * 1000)))
        return try await BrowserAutomation.offMain { store(snap, in: out) }.get()
    }

    /// `<artifactsRoot>/<id>/<name>` (`.import` by default), checked to stay under the artifact's folder (which must exist).
    static func importFolder(_ artifactsRoot: URL, _ id: UUID, _ name: String = importDir) throws(ProtocolError) -> URL {
        let root = artifactsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(id.uuidString.lowercased()).standardizedFileURL.resolvingSymlinksInPath()
        var dir: ObjCBool = false
        guard folder.deletingLastPathComponent().path == root.path,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &dir), dir.boolValue else {
            throw ProtocolError(code: .notFound, message: "artifact not found: \(id.uuidString.lowercased())")
        }
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    /// Moves `root`'s inline payloads (`image.data` / `svg`) to named files, numbering on from `images` / `svgs`.
    nonisolated static func extractPayloads(_ root: JSONValue, images: inout Int, svgs: inout Int) -> (JSONValue, [(String, Data)]) {
        var files: [(String, Data)] = []
        func external(_ v: JSONValue) -> JSONValue {
            guard case .object(var n) = v else { return v }
            if case .object(var img)? = n["image"] {
                if case .string(let b64)? = img["data"], let d = Data(base64Encoded: b64) {
                    images += 1
                    let name = "img-\(images).png"
                    files.append((name, d)); img["data"] = nil; img["file"] = .string(name); n["image"] = .object(img)
                } else { n["image"] = nil }
            }
            if case .string(let s)? = n["svg"] {
                svgs += 1
                let name = "svg-\(svgs).svg"
                files.append((name, Data(s.utf8))); n["svg"] = .object(["file": .string(name)])
            }
            if case .array(let cs)? = n["children"] { n["children"] = .array(cs.map(external)) }
            return .object(n)
        }
        return (external(root), files)
    }

    /// Empties `dir` for a new run: removes it (a symlink there is removed, never followed) and recreates it 0700.
    nonisolated static func replaceFolder(_ dir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) || (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    /// Writes the snapshot and its payloads (inline `image.data` / `svg` → files) to `dir`, replacing it, as `file`.
    /// A deck snapshot (`slides: [{root}]`) has each slide's payloads moved, numbered across slides.
    /// `replace: false`: `dir` is left as is (the caller has prepared it).
    nonisolated static func store(_ snap: JSONValue, in dir: URL, file: String = "snapshot.json",
                                  replace: Bool = true) -> Result<JSONValue, ProtocolError> {
        guard case .object(var o) = snap else { return .failure(ProtocolError(code: .internal, message: "html.snapshot: bad snapshot")) }
        var files: [(String, Data)] = []
        var images = 0, svgs = 0
        func external(_ v: JSONValue) -> JSONValue {
            let (out, f) = extractPayloads(v, images: &images, svgs: &svgs)
            files += f
            return out
        }
        o["root"] = o["root"].map(external)
        if case .array(let slides)? = o["slides"] {
            o["slides"] = .array(slides.map { sl in
                guard case .object(var x) = sl else { return sl }
                x["root"] = x["root"].map(external)
                return .object(x)
            })
        }
        do {
            if replace { try replaceFolder(dir) }
            for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
            try JSONEncoder().encode(JSONValue.object(o)).write(to: dir.appendingPathComponent(file))
        } catch {
            return .failure(ProtocolError(code: .internal, message: "html.snapshot: could not write the snapshot: \(error.localizedDescription)"))
        }
        let blocked: Double = if case .array(let b)? = o["blocked"] { Double(b.count) } else { 0 }
        var reply: [String: JSONValue] = ["file": .string("\(dir.lastPathComponent)/\(file)"), "blocked": .number(blocked),
                                          "truncated": o["truncated"] ?? .bool(false)]
        if case .array(let slides)? = o["slides"] { reply["slides"] = .number(Double(slides.count)) }
        return .success(.object(reply))
    }

    /// The snapshot with payloads inline (`image.data` base64 PNG, `svg` markup); `deck` runs `deckUserScript`.
    static func snapshot(url: URL, artifactsRoot: URL, width: Int, timeout: Duration,
                         libs: URL? = WebLibs.directory, deck: Bool = false,
                         script: String? = nil) async throws(ProtocolError) -> JSONValue {
        let json = try await withPage(url: url, artifactsRoot: artifactsRoot, width: width, timeout: timeout, libs: libs,
                                      script: script ?? (deck ? HTMLSnapshotScript.deckUserScript : HTMLSnapshotScript.userScript)) { _, s in s }
        return try await BrowserAutomation.offMain { () -> Result<JSONValue, ProtocolError> in
            do { return .success(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) } catch {
                return .failure(ProtocolError(code: .internal, message: "html.snapshot: bad snapshot JSON"))
            }
        }.get()
    }

    /// A fresh offline configuration: own non-persistent store, WebRTC off, the artifact and lib schemes, the no-network rule list.
    static func hardenedConfiguration(artifactsRoot: URL, libs: URL?) async throws(ProtocolError) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        WebLockdown.harden(config)   // WebRTC off: ICE gets past the rule list
        config.setURLSchemeHandler(DesignSchemeHandler(root: artifactsRoot, artifacts: true), forURLScheme: BrowserPanel.artifactScheme)
        config.setURLSchemeHandler(WebLibSchemeHandler(directory: libs, bundledFonts: WebLibs.fontsDirectory,
                                                            downloadedFonts: artifactsRoot.deletingLastPathComponent().appendingPathComponent("fonts")), forURLScheme: WebLibs.scheme)
        config.userContentController.add(try await ruleList())
        return config
    }

    /// Loads `url` (collie-artifact://app/… only) in a fresh hardened view, waits for `script`'s posted string (or the
    /// deadline), and hands view + string to `body`; the view is released afterwards, also on failure.
    static func withPage<T>(url: URL, artifactsRoot: URL, width: Int, timeout: Duration, libs: URL?, script: String,
                            _ body: (WKWebView, String) async throws(ProtocolError) -> T) async throws(ProtocolError) -> T {
        guard url.scheme?.lowercased() == BrowserPanel.artifactScheme, url.host == "app" else {
            throw ProtocolError(code: .invalidArgs, message: "url must be collie-artifact://app/…: \(url.absoluteString)")
        }
        let config = try await hardenedConfiguration(artifactsRoot: artifactsRoot, libs: libs)
        let content = config.userContentController
        // The script runs as a user script that posts its result, not through `callAsyncJavaScript`: WebKit keeps the
        // view alive while such a call is pending, so a page hung in JS would pin it (and its WebContent process).
        let run = Run()
        content.add(run, contentWorld: .defaultClient, name: Run.handler)
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        var web: WKWebView? = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        lastWebView = web
        web?.navigationDelegate = run
        // A classic scrollbar (system setting or page CSS) takes width off the layout: the script reports the gap, we widen the view by it.
        run.widen = { [weak web] gap in web?.frame.size.width = CGFloat(width + min(max(gap, 0), 64)) }  // clamp: page CSS controls the gap
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let late = ProtocolError(code: .timeout, message: "html.snapshot timed out after \(String(format: "%g", secs)) s")
        let timer = Task { try? await Task.sleep(for: timeout); run.finish(.failure(late)) }
        // fail closed: the WebRTC switch is private, so check it took before the page exists
        guard let w = web, await WebLockdown.peerConnectionsOff(w) else {
            timer.cancel(); web?.navigationDelegate = nil; content.removeAllScriptMessageHandlers()
            throw ProtocolError(code: .unavailable, message: "html.snapshot: \(WebLockdown.failure)")
        }
        let out: Result<String, ProtocolError> = await withCheckedContinuation { c in
            run.waiter = c
            web?.load(URLRequest(url: url))
        }
        timer.cancel()
        var result: Result<T, ProtocolError>
        switch out {
        case .failure(let e): result = .failure(e)
        case .success(let s):
            do throws(ProtocolError) { result = .success(try await body(w, s)) } catch { result = .failure(error) }
        }
        // the only strong reference: dropping it releases the view and its WebContent process; the next snapshot gets new ones
        web?.stopLoading()
        web?.navigationDelegate = nil
        content.removeAllScriptMessageHandlers()
        web = nil
        return try result.get()
    }

    /// Compiled once per app run (WebKit also keeps it in its store).
    /// Also the Diagram panel's: no http(s)/ws(s)/ftp load at all.
    static func ruleList() async throws(ProtocolError) -> WKContentRuleList {
        if let rules { return rules }
        let list: WKContentRuleList?
        do { list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "collie-import-offline", encodedContentRuleList: ruleJSON) } catch {
            throw ProtocolError(code: .internal, message: "html.snapshot: content rules: \(error.localizedDescription)")
        }
        guard let list else { throw ProtocolError(code: .internal, message: "html.snapshot: content rules missing") }
        rules = list
        return list
    }

    /// One snapshot's outcome, resumed once by whichever comes first: the script's message, a failed load, the deadline.
    /// Only artifact, collie-lib, data, blob and about: navigations are allowed; once the page has loaded, a later navigation
    /// that was cancelled (or refused by policy) leaves the snapshot running.
    private final class Run: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handler = "collieSnapshot"
        var waiter: CheckedContinuation<Result<String, ProtocolError>, Never>?
        var widen: (@MainActor (Int) -> Void)?
        private var loaded = false

        func finish(_ r: Result<String, ProtocolError>) { waiter?.resume(returning: r); waiter = nil }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let s = message.body as? String { return finish(.success(s)) }
            if let gap = (message.body as? [String: Any])?["gap"] as? Int { return widen?(gap) ?? () }
            let why = (message.body as? [String: Any])?["error"] as? String ?? "no snapshot"
            finish(.failure(ProtocolError(code: .internal, message: "html.snapshot script failed: \(why)")))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(ProtocolError(code: .unavailable, message: "html.snapshot: web content process ended")))
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            decisionHandler([BrowserPanel.artifactScheme, WebLibs.scheme, "data", "blob", "about"].contains(scheme) ? .allow : .cancel)
        }

        private func failed(_ error: any Error) {
            let e = error as NSError
            if loaded, (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
            finish(.failure(ProtocolError(code: .unavailable, message: "html.snapshot: load failed: \(error.localizedDescription)")))
        }
    }
}
