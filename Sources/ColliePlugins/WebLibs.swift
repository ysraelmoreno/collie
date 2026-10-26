import CollieCore
import Foundation
import WebKit

extension WebLibs {
    /// The vendored libraries: the app's Resources, then the repo's vendor dir (`swift run`, debug builds only);
    /// nil when neither has a `manifest.json`.
    static let directory: URL? = {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("weblibs")) }
        #if DEBUG
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/weblibs"))
        #endif
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }()

    /// The app's bundled fonts (Resources/Fonts, from `vendor/fonts`; the repo's in debug builds); nil when neither exists.
    public static let fontsDirectory: URL? = {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("Fonts")) }
        #if DEBUG
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/fonts"))
        #endif
        return c.first { d in Fonts.bundled.flatMap(\.faces).contains { FileManager.default.fileExists(atPath: d.appendingPathComponent($0.file).path) } }
    }()
}

/// `collie-lib://lib/<name>@<version>/<file>`: read-only, GET only, and only the files the manifest lists (looked up
/// by exact key, never as a path). Only for main documents on `collie-preview`/`collie-artifact`: any other page
/// (http, https, about, none) gets 403. A file is read once per handler and kept in memory.
/// `collie-lib://fonts/css?family=<Family>[:<w>,…]` (`@font-face` rules) and `collie-lib://fonts/<family>/<file>`: the
/// downloaded families (`<root>/fonts/<family>/font.json`, Google Fonts), then the bundled ones; only the faces a family
/// lists, regular files inside their dir (no link, no linked family folder). Read on each request (a font added or
/// removed shows on the next load).
public final class WebLibSchemeHandler: NSObject, WKURLSchemeHandler {
    static let documents: Set<String> = [PreviewSchemeHandler.scheme, BrowserPanel.artifactScheme]
    private let dir: URL?
    /// "<name>@<version>/<file>" for each manifest file.
    private let keys: Set<String>
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private let bundledFonts: URL?, downloadedFonts: URL?

    public init(directory: URL?, bundledFonts: URL? = nil, downloadedFonts: URL? = nil) {
        self.bundledFonts = bundledFonts?.standardizedFileURL.resolvingSymlinksInPath()
        self.downloadedFonts = downloadedFonts?.standardizedFileURL.resolvingSymlinksInPath()
        dir = directory?.standardizedFileURL.resolvingSymlinksInPath()
        keys = Set((dir.map(WebLibs.manifest(in:)) ?? []).flatMap { e in e.files.map { "\(e.name)@\(e.version)/\($0)" } })
    }

    /// Status, headers and body for a request.
    func serve(_ r: URLRequest) -> (Int, [String: String], Data) {
        let plain = ["Content-Type": "text/plain"]
        guard (r.httpMethod ?? "GET") == "GET" else { return (405, plain, Data()) }
        guard let doc = r.mainDocumentURL?.scheme?.lowercased(), Self.documents.contains(doc) else { return (403, plain, Data()) }
        if let url = r.url, url.host == "fonts" { return font(url) ?? (404, plain, Data()) }
        guard let url = r.url, url.host == "lib", let data = file(String(url.path.dropFirst())) else { return (404, plain, Data()) }
        return (200, ["Content-Type": "text/javascript; charset=utf-8", "Access-Control-Allow-Origin": "*",
                      "Cache-Control": "immutable"], data)
    }

    private func font(_ url: URL) -> (Int, [String: String], Data)? {
        let cors = ["Access-Control-Allow-Origin": "*"]
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if parts == ["css"] {
            let asked = Fonts.requests(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            let css = Fonts.css(asked.compactMap { a in family(a.family).map { ($0.0, a.weights) } })
            return (200, cors.merging(["Content-Type": "text/css; charset=utf-8"]) { a, _ in a }, Data(css.utf8))
        }
        guard parts.count == 2, let (f, folder) = family(parts[0]), f.faces.contains(where: { $0.file == parts[1] }),
              let data = regular(folder.appendingPathComponent(parts[1]), in: folder) else { return nil }
        let type = parts[1].hasSuffix(".woff2") ? "font/woff2" : parts[1].hasSuffix(".otf") ? "font/otf" : "font/ttf"
        return (200, cors.merging(["Content-Type": type, "Cache-Control": "no-cache"]) { a, _ in a }, data)
    }

    /// A family and its folder: downloaded (a real folder, not a link), else bundled (only the faces present).
    private func family(_ name: String) -> (FontFamily, URL)? {
        guard Fonts.validFamily(name) else { return nil }
        if let d = downloadedFonts {
            let folder = d.appendingPathComponent(name)
            if (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory,
               let f = Fonts.downloaded(name, in: d) { return (f, folder) }
        }
        guard let b = bundledFonts, var f = Fonts.bundled.first(where: { $0.family == name }) else { return nil }
        f.faces = f.faces.filter { FileManager.default.fileExists(atPath: b.appendingPathComponent($0.file).path) }
        return f.faces.isEmpty ? nil : (f, b)
    }

    /// `f`'s bytes when it is a regular file (not a link) whose real path is inside `dir`.
    private func regular(_ f: URL, in dir: URL) -> Data? {
        guard f.resolvingSymlinksInPath().path.hasPrefix(dir.path + "/"),
              (try? FileManager.default.attributesOfItem(atPath: f.path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return try? Data(contentsOf: f)
    }

    /// The manifest file `key`: a regular file (not a link), its real path inside the dir.
    private func file(_ key: String) -> Data? {
        guard let dir, keys.contains(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let d = cache[key] { return d }
        let f = dir.appendingPathComponent(key)
        guard f.resolvingSymlinksInPath().path.hasPrefix(dir.path + "/"),   // a linked folder that leaves the dir: refused
              (try? FileManager.default.attributesOfItem(atPath: f.path)[.type] as? FileAttributeType) == .typeRegular,
              let d = try? Data(contentsOf: f) else { return nil }
        cache[key] = d
        return d
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let (status, headers, data) = serve(task.request)
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: headers.merging(["Content-Length": "\(data.count)"]) { a, _ in a }) else {
            return task.didFailWithError(URLError(.badURL))
        }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered synchronously in `start`
}
