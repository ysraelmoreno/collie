import Foundation
import CollieCore

/// An imported page made to work offline, in the copy Collie keeps (never the original): `<script src>` of React,
/// ReactDOM, Chart.js, Lucide and htm on unpkg, jsDelivr or cdnjs → their `collie-lib://lib/…` file (the same version,
/// else the one vendored, with a warning); Google Fonts `<link>`/`@import` → `collie-lib://fonts/css` (the families
/// then downloaded with `font add`); anything else remote stays and is listed ("precisa de rede").
enum OfflineRewrite {
    struct FontAsk: Equatable, Sendable { var family: String; var weights: [Int]? }
    struct Report: Equatable, Sendable {
        var warnings: [String] = [], remote: [String] = [], fonts: [FontAsk] = []
        mutating func merge(_ o: Report) {
            // capped: a page of a million distinct tags never grows these (each add scans them)
            for w in o.warnings where !warnings.contains(w) && warnings.count < maxRemote { warnings.append(w) }
            for u in o.remote where !remote.contains(u) && remote.count < maxRemote { remote.append(u) }
            for f in o.fonts where !fonts.contains(where: { $0.family == f.family }) && fonts.count < maxRemote { fonts.append(f) }
        }
    }
    static let maxRemote = 20
    /// Package names on the CDNs (lowercased) → the manifest's.
    private static let names = ["react": "react", "react-dom": "react-dom", "htm": "htm", "chart.js": "chart.js", "lucide": "lucide"]
    private static let fontHosts: Set<String> = ["fonts.googleapis.com", "fonts.gstatic.com"]

    private static func absolute(_ s: String) -> String { s.hasPrefix("//") ? "https:" + s : s }

    /// The `collie-lib://` file for a CDN script URL (and a warning when the version differs), or nil: not one of ours,
    /// or an ES module / server build the UMD file can't stand in for.
    static func lib(for raw: String, libs: [WebLibEntry]) -> (url: String, warning: String?)? {
        guard let c = URLComponents(string: absolute(raw.replacingOccurrences(of: "&amp;", with: "&"))),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host?.lowercased(),
              c.query?.lowercased().contains("module") != true else { return nil }
        let path = c.path.split(separator: "/").map(String.init)
        func split(_ s: String) -> (String, String?) {
            guard let at = s.lastIndex(of: "@"), at != s.startIndex else { return (s, nil) }
            return (String(s[..<at]), String(s[s.index(after: at)...]))
        }
        let pkg: String, ver: String?, file: [String]
        switch host {
        case "unpkg.com":
            guard let f = path.first else { return nil }
            (pkg, ver) = split(f); file = Array(path.dropFirst())
        case "cdn.jsdelivr.net":
            guard path.count >= 2, path[0] == "npm" else { return nil }
            (pkg, ver) = split(path[1]); file = Array(path.dropFirst(2))
        case "cdnjs.cloudflare.com":
            guard path.count >= 4, path[0] == "ajax", path[1] == "libs" else { return nil }
            pkg = path[2]; ver = path[3]; file = Array(path.dropFirst(4))
        default: return nil
        }
        let f = file.joined(separator: "/").lowercased()
        guard let name = names[pkg.lowercased()], let e = libs.first(where: { $0.name == name }), let first = e.files.first,
              !["esm", "module", "server", "preact"].contains(where: f.contains), !f.hasSuffix(".mjs"), !f.hasSuffix(".cjs"),
              f.isEmpty || f.hasSuffix(".js") else { return nil }
        let want = (ver ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "^~=v")).split(separator: ".")
        let have = e.version.split(separator: ".")
        let same = !want.isEmpty && want.count <= have.count && zip(want, have).allSatisfy { $0 == $1 }
        return ("\(WebLibs.scheme)://lib/\(e.name)@\(e.version)/\(first)",
                same ? nil : "\(e.name) \(ver ?? "sem versão") trocado pela versão offline \(e.version)")
    }

    /// A Google Fonts css/css2 URL as `collie-lib://fonts/css` and its families (valid names only; nil: none).
    static func googleFonts(_ raw: String) -> (css: String, fonts: [FontAsk])? {
        let s = absolute(raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "|", with: "%7C"))
        guard let c = URLComponents(string: s), c.host?.lowercased() == "fonts.googleapis.com", ["/css", "/css2"].contains(c.path) else { return nil }
        var out: [FontAsk] = []
        func weights(_ ws: [Int]) -> [Int]? {   // 100, 200 … 900: at most 9
            let w = Array(Set(ws.filter { (100...900).contains($0) && $0 % 100 == 0 })).sorted(); return w.isEmpty ? nil : w
        }
        for q in c.percentEncodedQueryItems ?? [] where q.name == "family" {
            let v = (q.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            for part in c.path == "/css" ? v.split(separator: "|").map(String.init) : [v] {
                let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard let fam = bits.first?.trimmingCharacters(in: .whitespaces), Fonts.validFamily(fam), !out.contains(where: { $0.family == fam }) else { continue }
                var ws: [Int]?
                if bits.count > 1 {
                    if c.path == "/css" {
                        ws = weights(bits[1].split(separator: ",").compactMap { Int($0.prefix { $0.isNumber }) })
                    } else if let at = bits[1].firstIndex(of: "@") {
                        let tuples = bits[1][bits[1].index(after: at)...].split(separator: ";")
                        ws = tuples.contains { $0.contains("..") } ? nil : weights(tuples.compactMap { $0.split(separator: ",").last.flatMap { Int($0) } })
                    }
                }
                out.append(FontAsk(family: fam, weights: ws))
            }
        }
        guard !out.isEmpty else { return nil }
        let enc = { (f: String) in f.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? f }
        return ("\(WebLibs.scheme)://fonts/css?" + out.map { "family=" + enc($0.family) + ($0.weights.map { ":" + $0.map(String.init).joined(separator: ",") } ?? "") }
            .joined(separator: "&"), out)
    }

    // MARK: attributes

    /// One attribute of a tag: its name (lowercased), value, and range (from the space before it through its value).
    struct Attr { let name: String; let value: String; let range: Range<String.Index> }

    /// `tag`'s attributes, read in one pass (linear: no regex over the tag, which may be huge and never close).
    static func attributes(_ tag: String) -> [Attr] {
        var out: [Attr] = [], i = tag.startIndex
        func at(_ j: String.Index) -> Character? { j < tag.endIndex ? tag[j] : nil }
        func skip(_ j: inout String.Index, while ok: (Character) -> Bool) { while let c = at(j), ok(c) { j = tag.index(after: j) } }
        if at(i) == "<" { i = tag.index(after: i) }
        skip(&i) { !$0.isWhitespace && $0 != ">" && $0 != "/" }   // the tag's name
        while i < tag.endIndex {
            let start = i
            skip(&i) { $0.isWhitespace || $0 == "/" }
            guard let c = at(i), c != ">" else { break }
            let ns = i
            skip(&i) { !$0.isWhitespace && $0 != "=" && $0 != ">" }
            if i == ns { i = tag.index(after: i); continue }   // a stray "="
            let name = tag[ns..<i].lowercased()
            var j = i
            skip(&j) { $0.isWhitespace }
            var value = ""
            if at(j) == "=" {
                j = tag.index(after: j)
                skip(&j) { $0.isWhitespace }
                if let q = at(j), q == "\"" || q == "'" {
                    j = tag.index(after: j)
                    let vs = j
                    skip(&j) { $0 != q }
                    value = String(tag[vs..<j])
                    if j < tag.endIndex { j = tag.index(after: j) }
                } else {
                    let vs = j
                    skip(&j) { !$0.isWhitespace && $0 != ">" }
                    value = String(tag[vs..<j])
                }
                i = j
            }
            out.append(Attr(name: name, value: value, range: start..<i))
        }
        return out
    }

    /// `tag` with attribute `a` set to `v`, and no `integrity`/`crossorigin` (the file is no longer the CDN's).
    private static func replaced(_ tag: String, _ attrs: [Attr], _ a: Attr, with v: String) -> String {
        var out = "", from = tag.startIndex
        for x in attrs where x.range == a.range || ["integrity", "crossorigin"].contains(x.name) {
            out += tag[from..<x.range.lowerBound]
            if x.range == a.range { out += " \(a.name)=\"\(v)\"" }
            from = x.range.upperBound
        }
        return out + tag[from...]
    }
    private static func host(_ u: String) -> String? { URLComponents(string: absolute(u))?.host?.lowercased() }

    // MARK: rewrite

    // compiled once; `[^<>]*`: a tag that never closes fails at the next `<` (linear, never quadratic).
    // nonisolated(unsafe): Regex is an immutable value (its lazy program is built atomically), only read here
    nonisolated(unsafe) private static let linkTag = /(?i)<link\b[^<>]*>/, scriptTag = /(?i)<script\b[^<>]*>/, anyTag = /<([a-zA-Z][a-zA-Z0-9-]*)\b[^<>]*>/
    nonisolated(unsafe) private static let fontImport = /(?i)@import\s+(?:url\(\s*)?["']?((?:https?:)?\/\/fonts\.googleapis\.com\/[^"')\s;<>]+)["']?\s*\)?/
    nonisolated(unsafe) private static let remoteRefs = [/(?i)url\(\s*["']?((?:https?:)?\/\/[^"'\s)<>]+)/, /(?i)@import\s+["']((?:https?:)?\/\/[^"'\s)<>]+)/,
                                     /\bfrom\s*["']((?:https?:)?\/\/[^"'\s)<>]+)/, /\bimport\(\s*["']((?:https?:)?\/\/[^"'\s)<>]+)/]

    /// `s` made offline, or nil once past `deadline` (checked between the passes).
    static func html(_ s: String, libs: [WebLibEntry], deadline: ContinuousClock.Instant = .now + .seconds(3600)) -> (String, Report)? {
        var r = Report()
        var out = s.replacing(linkTag) { m -> String in
            let tag = String(m.0), attrs = attributes(tag)
            guard let href = attrs.first(where: { $0.name == "href" }), let h = host(href.value), fontHosts.contains(h) else { return tag }
            let rel = attrs.first { $0.name == "rel" }?.value.lowercased() ?? ""
            if ["preconnect", "dns-prefetch", "preload"].contains(where: rel.contains) { return "" }
            guard let g = googleFonts(href.value) else { return tag }
            r.merge(Report(fonts: g.fonts))
            return replaced(tag, attrs, href, with: g.css)
        }
        guard ContinuousClock.now < deadline else { return nil }
        out = out.replacing(scriptTag) { m -> String in
            let tag = String(m.0), attrs = attributes(tag)
            guard let src = attrs.first(where: { $0.name == "src" }), let l = lib(for: src.value, libs: libs) else { return tag }
            if let w = l.warning { r.merge(Report(warnings: [w])) }
            return replaced(tag, attrs, src, with: l.url)
        }
        guard ContinuousClock.now < deadline else { return nil }
        let (css, cr) = imports(out)
        r.merge(cr)
        guard ContinuousClock.now < deadline else { return nil }
        r.merge(Report(remote: remote(css)))
        guard ContinuousClock.now < deadline else { return nil }
        return (css, r)
    }

    static func css(_ s: String) -> (String, Report) {
        var (out, r) = imports(s)
        r.merge(Report(remote: remote(out)))
        return (out, r)
    }

    /// `@import` of Google Fonts (in CSS or a `<style>`) → `collie-lib://fonts/css`.
    private static func imports(_ s: String) -> (String, Report) {
        var r = Report()
        let out = s.replacing(fontImport) { m -> String in
            guard let g = googleFonts(String(m.1)) else { return String(m.0) }
            r.merge(Report(fonts: g.fonts))
            return "@import url(\"\(g.css)\")"
        }
        return (out, r)
    }

    /// The remote resources still in `s`, in order, without query or fragment: tag attributes (not `<a>`, `<area>`,
    /// `<form>`, `<base>`), CSS `url()` and `@import`, JS `import`s.
    static func remote(_ s: String) -> [String] {
        var found: [(String.Index, String)] = []
        for m in s.matches(of: anyTag) where !["a", "area", "form", "base"].contains(m.1.lowercased()) {
            for a in attributes(String(m.0)) where ["src", "href", "poster", "data"].contains(a.name) {
                let v = a.value.lowercased()
                if v.hasPrefix("//") || v.hasPrefix("http://") || v.hasPrefix("https://") { found.append((m.range.lowerBound, a.value)) }
            }
        }
        for re in remoteRefs { for m in s.matches(of: re) { found.append((m.range.lowerBound, String(m.1))) } }
        var out: [String] = []
        for (_, u) in found.sorted(by: { $0.0 < $1.0 }) {
            let clean = String(absolute(u).prefix { $0 != "?" && $0 != "#" })
            if !out.contains(clean) { out.append(clean) }
            if out.count == maxRemote { break }
        }
        return out
    }
}

/// One import's rewrite over its files (the store calls it on its io queue), the report gathered. Each page gets
/// `budget` (2 s): past it, that file is kept as it is, with a warning.
/// ponytail: the budget is checked between the passes (each pass is linear), not inside one.
final class OfflineRewriter: @unchecked Sendable {
    private let libs: [WebLibEntry]
    /// A warning for a Google Fonts family the page asks for (nil: none, e.g. bundled, downloaded or about to be).
    private let fontWarning: @Sendable (String) -> String?
    private let budget: Duration
    private let lock = NSLock()
    private var _report = OfflineRewrite.Report()
    init(libs: [WebLibEntry], budget: Duration = .seconds(2), fontWarning: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.libs = libs; self.budget = budget; self.fontWarning = fontWarning
    }

    var report: OfflineRewrite.Report { lock.withLock { _report } }

    /// An .html/.htm/.css file rewritten (others, and non-UTF-8 text, as they are).
    func rewrite(_ data: Data, ext: String) -> Data {
        let e = ext.lowercased(), deadline = ContinuousClock.now + budget
        guard ["html", "htm", "css"].contains(e), let s = String(data: data, encoding: .utf8) else { return data }
        let done = e == "css" ? OfflineRewrite.css(s) : OfflineRewrite.html(s, libs: libs, deadline: deadline)
        guard let (out, r0) = done, ContinuousClock.now < deadline else {
            lock.withLock { _report.merge(OfflineRewrite.Report(warnings: ["página grande demais para deixar offline a tempo: guardada como veio"])) }
            return data
        }
        var r = r0
        r.warnings += r.fonts.compactMap { fontWarning($0.family) }
        lock.withLock { _report.merge(r) }
        return out == s ? data : Data(out.utf8)
    }
}
