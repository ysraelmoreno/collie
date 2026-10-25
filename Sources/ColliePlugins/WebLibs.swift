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
}

/// `collie-lib://lib/<name>@<version>/<file>`: read-only, GET only, and only the files the manifest lists (looked up
/// by exact key, never as a path). Only for main documents on `collie-preview`/`collie-artifact`: any other page
/// (http, https, about, none) gets 403. A file is read once per handler and kept in memory.
public final class WebLibSchemeHandler: NSObject, WKURLSchemeHandler {
    static let documents: Set<String> = [PreviewSchemeHandler.scheme, BrowserPanel.artifactScheme]
    private let dir: URL?
    /// "<name>@<version>/<file>" for each manifest file.
    private let keys: Set<String>
    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    public init(directory: URL?) {
        dir = directory?.standardizedFileURL.resolvingSymlinksInPath()
        keys = Set((dir.map(WebLibs.manifest(in:)) ?? []).flatMap { e in e.files.map { "\(e.name)@\(e.version)/\($0)" } })
    }

    /// Status, headers and body for a request.
    func serve(_ r: URLRequest) -> (Int, [String: String], Data) {
        let plain = ["Content-Type": "text/plain"]
        guard (r.httpMethod ?? "GET") == "GET" else { return (405, plain, Data()) }
        guard let doc = r.mainDocumentURL?.scheme?.lowercased(), Self.documents.contains(doc) else { return (403, plain, Data()) }
        guard let url = r.url, url.host == "lib", let data = file(String(url.path.dropFirst())) else { return (404, plain, Data()) }
        return (200, ["Content-Type": "text/javascript; charset=utf-8", "Access-Control-Allow-Origin": "*",
                      "Cache-Control": "immutable"], data)
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
