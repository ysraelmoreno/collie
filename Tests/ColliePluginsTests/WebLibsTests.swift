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
}
