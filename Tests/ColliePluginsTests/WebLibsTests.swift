import Foundation
import Testing
import CollieCore
@testable import ColliePlugins

/// A fixture weblibs dir: manifest with react 18.3.1, its file, a stray file and a secret one level up.
func webLibsFixture() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("weblibs-\(UUID().uuidString)")
    let dir = base.appendingPathComponent("weblibs"), react = dir.appendingPathComponent("react@18.3.1")
    try FileManager.default.createDirectory(at: react, withIntermediateDirectories: true)
    try Data(#"[{"name":"react","version":"18.3.1","files":["react.production.min.js"],"licence":"MIT","global":"React"}]"#.utf8)
        .write(to: dir.appendingPathComponent("manifest.json"))
    try Data("window.React = {ok:1}".utf8).write(to: react.appendingPathComponent("react.production.min.js"))
    try Data("stray".utf8).write(to: react.appendingPathComponent("LICENSE"))
    try Data("secret".utf8).write(to: base.appendingPathComponent("secret.txt"))
    return dir
}

@MainActor @Suite struct WebLibsTests {
    func req(_ u: String, main: String? = "collie-artifact://app/abc/v1/index.html", method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: u)!); r.mainDocumentURL = main.flatMap(URL.init(string:)); r.httpMethod = method; return r
    }
    static let react = "collie-lib://lib/react@18.3.1/react.production.min.js"

    @Test func servesManifestFile() throws {
        let h = WebLibSchemeHandler(directory: try webLibsFixture())
        let (s, headers, body) = h.serve(req(Self.react))
        #expect(s == 200 && body == Data("window.React = {ok:1}".utf8))
        #expect(headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(headers["Access-Control-Allow-Origin"] == "*" && headers["Cache-Control"] == "immutable")
        #expect(h.serve(req(Self.react)).2 == body)   // cached
    }

    @Test func refusesTraversal() throws {
        let h = WebLibSchemeHandler(directory: try webLibsFixture())
        for u in ["collie-lib://lib/react@18.3.1/../../manifest.json", "collie-lib://lib/react@18.3.1/%2e%2e/%2e%2e/secret.txt",
                  "collie-lib://lib/../secret.txt", "collie-lib://lib/manifest.json", "collie-lib://other/react@18.3.1/react.production.min.js"] {
            #expect(h.serve(req(u)).0 == 404, "\(u)")
        }
    }

    @Test func refusesUnknownVersion() throws {
        #expect(WebLibSchemeHandler(directory: try webLibsFixture()).serve(req("collie-lib://lib/react@18.3.0/react.production.min.js")).0 == 404)
    }

    @Test func refusesFileNotInManifest() throws {
        #expect(WebLibSchemeHandler(directory: try webLibsFixture()).serve(req("collie-lib://lib/react@18.3.1/LICENSE")).0 == 404)
    }

    @Test func refusesSymlink() throws {
        let dir = try webLibsFixture(), f = dir.appendingPathComponent("react@18.3.1/react.production.min.js")
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createSymbolicLink(at: f, withDestinationURL: dir.deletingLastPathComponent().appendingPathComponent("secret.txt"))
        #expect(WebLibSchemeHandler(directory: dir).serve(req(Self.react)).0 == 404)
        // a linked library folder that points outside the dir
        let outside = dir.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("react.production.min.js"))
        try FileManager.default.removeItem(at: f.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: f.deletingLastPathComponent(), withDestinationURL: outside)
        #expect(WebLibSchemeHandler(directory: dir).serve(req(Self.react)).0 == 404)
    }

    @Test func refusesPost() throws {
        #expect(WebLibSchemeHandler(directory: try webLibsFixture()).serve(req(Self.react, method: "POST")).0 == 405)
    }

    @Test func missingDirectoryIs404() {
        #expect(WebLibSchemeHandler(directory: nil).serve(req(Self.react)).0 == 404)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("weblibs-none-\(UUID().uuidString)")
        #expect(WebLibSchemeHandler(directory: empty).serve(req(Self.react)).0 == 404)
    }

    @Test func httpDocumentRefused() throws {
        let h = WebLibSchemeHandler(directory: try webLibsFixture())
        for main in ["https://x/", "http://x/", "about:blank", nil] { #expect(h.serve(req(Self.react, main: main)).0 == 403, "\(main ?? "nil")") }
    }

    @Test func previewDocumentAllowed() throws {
        #expect(WebLibSchemeHandler(directory: try webLibsFixture()).serve(req(Self.react, main: "collie-preview://app/docs/index.html")).0 == 200)
    }

    @Test func manifestAndURL() throws {
        let entries = WebLibs.manifest(in: try webLibsFixture())
        #expect(entries.map(\.global) == ["React"])
        #expect(WebLibs.url("react", in: entries) == Self.react && WebLibs.url("htm", in: entries) == nil)
        #expect(WebLibs.manifest(in: URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }

    // MARK: fonts (collie-lib://fonts)

    /// A bundled fonts dir (flat, as Resources/Fonts) and a downloaded one (`<root>/fonts/<family>/`), plus a secret beside them.
    func fontsFixture() throws -> (bundled: URL, downloaded: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID().uuidString)")
        let bundled = base.appendingPathComponent("Fonts"), inter = base.appendingPathComponent("fonts/Inter")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inter, withIntermediateDirectories: true)
        try Data("ttf-regular".utf8).write(to: bundled.appendingPathComponent("DMMono-Regular.ttf"))
        try Data("woff2-700".utf8).write(to: inter.appendingPathComponent("normal-700-0.woff2"))
        try Data("stray".utf8).write(to: inter.appendingPathComponent("stray.woff2"))
        try JSONEncoder().encode(FontFamily(family: "Inter", faces: [.init(style: "normal", weight: "700", file: "normal-700-0.woff2", unicodeRange: "U+0000-00FF")]))
            .write(to: inter.appendingPathComponent(Fonts.metaFile))
        try Data("secret".utf8).write(to: base.appendingPathComponent("secret.woff2"))
        return (bundled, inter.deletingLastPathComponent())
    }

    @Test func servesFontsCSS() throws {
        let (b, d) = try fontsFixture()
        let h = WebLibSchemeHandler(directory: nil, bundledFonts: b, downloadedFonts: d)
        let (s, headers, body) = h.serve(req("collie-lib://fonts/css?family=Inter:700&family=DM%20Mono&family=Nope", main: "collie-preview://app/docs/index.html"))
        let css = String(decoding: body, as: UTF8.self)
        #expect(s == 200 && headers["Content-Type"] == "text/css; charset=utf-8", "\(s)")
        #expect(css.contains(#"url("collie-lib://fonts/Inter/normal-700-0.woff2") format("woff2")"#) && css.contains("unicode-range: U+0000-00FF;"), "\(css)")
        #expect(css.contains(#"url("collie-lib://fonts/DM%20Mono/DMMono-Regular.ttf")"#))
        #expect(!css.contains("DMMono-Medium"))   // not in the bundled dir
        #expect(!css.contains("Nope"))
        #expect(h.serve(req("collie-lib://fonts/css?family=Inter")).0 == 200)
        #expect(h.serve(req("collie-lib://fonts/css?family=Inter", main: "https://x/")).0 == 403)
    }

    @Test func servesFontFiles() throws {
        let (b, d) = try fontsFixture()
        let h = WebLibSchemeHandler(directory: nil, bundledFonts: b, downloadedFonts: d)
        let (s, headers, body) = h.serve(req("collie-lib://fonts/Inter/normal-700-0.woff2"))
        #expect(s == 200 && body == Data("woff2-700".utf8) && headers["Content-Type"] == "font/woff2" && headers["Access-Control-Allow-Origin"] == "*")
        let mono = h.serve(req("collie-lib://fonts/DM%20Mono/DMMono-Regular.ttf"))
        #expect(mono.0 == 200 && mono.1["Content-Type"] == "font/ttf" && mono.2 == Data("ttf-regular".utf8))
        #expect(h.serve(req("collie-lib://fonts/Inter/normal-700-0.woff2", method: "POST")).0 == 405)
    }

    @Test func fontsRefuseTraversalAndUnlisted() throws {
        let (b, d) = try fontsFixture()
        let h = WebLibSchemeHandler(directory: nil, bundledFonts: b, downloadedFonts: d)
        for u in ["collie-lib://fonts/Inter/stray.woff2", "collie-lib://fonts/Inter/font.json", "collie-lib://fonts/Inter/../../secret.woff2",
                  "collie-lib://fonts/Inter/%2e%2e/%2e%2e/secret.woff2", "collie-lib://fonts/../secret.woff2", "collie-lib://fonts/Inter",
                  "collie-lib://fonts/DM%20Mono/DMMono-Medium.ttf", "collie-lib://fonts/Lato/normal-700-0.woff2", "collie-lib://fonts/Inter/x/normal-700-0.woff2"] {
            #expect(h.serve(req(u)).0 == 404, "\(u)")
        }
        #expect(WebLibSchemeHandler(directory: nil).serve(req("collie-lib://fonts/Inter/normal-700-0.woff2")).0 == 404)
    }

    @Test func fontsRefuseSymlinks() throws {
        let (b, d) = try fontsFixture()
        let f = d.appendingPathComponent("Inter/normal-700-0.woff2"), secret = d.deletingLastPathComponent().appendingPathComponent("secret.woff2")
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createSymbolicLink(at: f, withDestinationURL: secret)
        let h = WebLibSchemeHandler(directory: nil, bundledFonts: b, downloadedFonts: d)
        #expect(h.serve(req("collie-lib://fonts/Inter/normal-700-0.woff2")).0 == 404)
        // a linked family folder that leaves the dir
        let outside = d.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: d.appendingPathComponent("Inter"), to: outside)
        try FileManager.default.removeItem(at: outside.appendingPathComponent("normal-700-0.woff2"))
        try Data("x".utf8).write(to: outside.appendingPathComponent("normal-700-0.woff2"))
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("Inter"), withDestinationURL: outside)
        #expect(h.serve(req("collie-lib://fonts/Inter/normal-700-0.woff2")).0 == 404)
        #expect(!String(decoding: h.serve(req("collie-lib://fonts/css?family=Inter")).2, as: UTF8.self).contains("normal-700"))
    }
}
