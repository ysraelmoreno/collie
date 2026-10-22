import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// Fixtures captured from the real engine by scripts/capture-html-fixtures.sh.
private let htmlFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/html-export")

private func json(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: htmlFixtures.appendingPathComponent(name))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct HTMLExportTests {
    @Test func fixtureHasHyperlinkAndModes() throws {
        let kids = try #require(try json("node.json")["children"] as? [[String: Any]])
        let link = try #require(kids.first { $0["name"] as? String == "Link" })
        #expect(link["hyperlink"] as? String == "https://example.com")

        let collections = try #require(try json("variables.json")["collections"] as? [[String: Any]])
        let modes = collections.first.flatMap { $0["modes"] as? [[String: Any]] }?.compactMap { $0["name"] as? String }
        #expect(modes == ["Light", "Dark"])

        let assets = try #require(try json("assets.json")["assets"] as? [[String: Any]])
        #expect(assets.contains { $0["kind"] as? String == "icon" && $0["name"] as? String == "Icon Star" })
        #expect(assets.contains { $0["kind"] as? String == "image" && $0["name"] as? String == "Photo" })

        let html = try String(contentsOf: htmlFixtures.appendingPathComponent("code.html"), encoding: .utf8)
        #expect(html.contains("class=\"landing\""))
        #expect(!html.contains("secret"))
    }

    private func fixtureTree() throws -> (MarkupNode, Layer) {
        let code = try String(contentsOf: htmlFixtures.appendingPathComponent("code.html"), encoding: .utf8)
        let root = try #require(try ExportMarkup.parse(ExportMarkup.split(code).markup).first)
        let data = try Data(contentsOf: htmlFixtures.appendingPathComponent("node.json"))
        let layer = try #require(ExportMarkup.layer(try JSONDecoder().decode(JSONValue.self, from: data)))
        return (root, layer)
    }

    private func find(_ n: MarkupNode, _ cls: String) -> MarkupNode? {
        n.cls == cls ? n : n.children.lazy.compactMap { find($0, cls) }.first
    }

    private func all(_ n: MarkupNode) -> [MarkupNode] { [n] + n.children.flatMap(all) }

    @Test func classNamesMatchFigcraft() {
        var used: [String] = []
        let out = ["Card", "Card", "", "Seção", "2024", "Card / Title", "--x--"].map { ExportMarkup.className($0, used: &used) }
        #expect(out == ["card", "card-2", "layer-", "se-o", "layer-2024", "card-title", "x"])
    }

    @Test func parsesFixtureMarkup() throws {
        let (root, _) = try fixtureTree()
        #expect(root.cls == "landing" && root.tag == "div")
        #expect(find(root, "title")?.tag == "p")
        #expect(find(root, "title")?.text == "Hello")
        #expect(find(root, "items")?.text == "One<br>Two")
    }

    @Test func attachHandlesDuplicatesAndHidden() throws {
        var (root, layer) = try fixtureTree()
        #expect(ExportMarkup.attach(&root, layer))
        #expect(find(root, "card-3")?.layer?.name == "Card")
        #expect(!all(root).contains { $0.layer?.name == "Hidden" })
        #expect(find(root, "link")?.layer?.hyperlink == "https://example.com")
        let f = try #require(find(root, "features")?.layer)
        #expect(f.layoutMode == "grid" && f.gridColumns == 3 && f.columnTracks.count == 3)
    }

    @Test func attachMismatchAttachesNothing() throws {
        var (root, layer) = try fixtureTree()
        layer.children[0].name = "Top"
        #expect(!ExportMarkup.attach(&root, layer))
        #expect(all(root).allSatisfy { $0.layer == nil })
    }

    @Test func attachCapsVisibleChildrenAt200() {
        func leaf(_ i: Int) -> Layer {
            Layer(id: "\(i)", name: "N\(i)", type: "RECTANGLE", visible: true, columnTracks: [], children: [])
        }
        let layer = Layer(id: "0", name: "Root", type: "FRAME", visible: true, columnTracks: [],
                          children: (1...201).map(leaf))
        var root = MarkupNode(tag: "div", cls: "root", attrs: [], children: (1...200).map {
            MarkupNode(tag: "div", cls: "n\($0)", attrs: [], children: [], layer: nil)
        }, layer: nil)
        #expect(ExportMarkup.attach(&root, layer))
        #expect(root.children.last?.layer?.id == "200")
    }
}

@Suite struct ExportSemanticsTests {
    private func tree(attach: Bool) throws -> MarkupNode {
        let code = try String(contentsOf: htmlFixtures.appendingPathComponent("code.html"), encoding: .utf8)
        var root = try #require(try ExportMarkup.parse(ExportMarkup.split(code).markup).first)
        if attach {
            let data = try Data(contentsOf: htmlFixtures.appendingPathComponent("node.json"))
            let layer = try #require(ExportMarkup.layer(try JSONDecoder().decode(JSONValue.self, from: data)))
            #expect(ExportMarkup.attach(&root, layer))
        }
        return root
    }

    @Test func semanticTagsFromFixture() throws {
        var root = try tree(attach: true)
        var w: [String] = []
        ExportSemantics.apply(&root, warnings: &w)
        let h = ExportSemantics.html(root, depth: 0)
        for s in ["<main class=\"landing\">", "<section class=\"hero\">", "<h1 class=\"title\">Hello</h1>",
                  "<h2 class=\"subtitle\">Sub</h2>", "<p class=\"body\">Body text one</p>", "<ul class=\"items\">",
                  "<li>One</li>", "<li>Two</li>", "<ul class=\"collie-list\">", "<li class=\"bullet\">• Alpha</li>",
                  "<p class=\"link\"><a href=\"https://example.com\">Site</a></p>", "<footer class=\"footer\">"] {
            #expect(h.contains(s), "missing \(s)")
        }
    }

    @Test func unsafeLinksDropped() throws {
        var root = try tree(attach: true)
        var w: [String] = []
        ExportSemantics.apply(&root, warnings: &w)
        let h = ExportSemantics.html(root, depth: 0)
        #expect(h.contains("<p class=\"bad-link\">x</p>"))
        #expect(w == ["link dropped: Bad link"])
        #expect(ExportSemantics.safeHref("javascript:alert(1)") == nil)
        #expect(ExportSemantics.safeHref(" https://a.b/?q=\"x\" ") == "https://a.b/?q=&quot;x&quot;")
        #expect(ExportSemantics.safeHref("docs/a.html") == "docs/a.html")
        #expect(ExportSemantics.safeHref("data:text/html,x") == nil)
    }

    @Test func unmappedUsesStructuralRulesOnly() throws {
        var root = try tree(attach: false)
        var w: [String] = []
        ExportSemantics.apply(&root, warnings: &w)
        let h = ExportSemantics.html(root, depth: 0)
        #expect(h.contains("<main") && h.contains("<section") && h.contains("<ul class=\"collie-list\">"))
        #expect(!h.contains("<h1") && !h.contains("<a"))
    }

    @Test func textStaysEscaped() {
        var root = MarkupNode(tag: "div", cls: "r", attrs: [], text: nil, children: [
            MarkupNode(tag: "p", cls: "", attrs: [], text: "&lt;script&gt;", children: [], layer: nil)], layer: nil)
        var w: [String] = []
        ExportSemantics.apply(&root, warnings: &w)
        #expect(ExportSemantics.html(root, depth: 0).contains("<p>&lt;script&gt;</p>"))
    }
}

@Suite struct HTMLDocumentTests {
    private func value(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: htmlFixtures.appendingPathComponent(name)))
    }

    private func assets() throws -> [ExportAsset] {
        let meta = try #require(try json("assets.json")["assets"] as? [[String: Any]])
        let files = try #require(try json("export-files.json")["files"] as? [[String: Any]])
        return try meta.map { m in
            let id = try #require(m["id"] as? Int)
            let f = try #require(files.first { $0["id"] as? Int == id })
            let b64 = try #require(f["data"] as? String)
            let data = try #require(Data(base64Encoded: b64))
            let name = try #require(m["name"] as? String), kind = try #require(m["kind"] as? String)
            return ExportAsset(id: "\(id)", name: name, kind: kind, data: data)
        }
    }

    private func input(roots: Int = 1, variables: [JSONValue]? = nil, assets: [ExportAsset]? = nil) throws -> ExportInput {
        let code = try String(contentsOf: htmlFixtures.appendingPathComponent("code.html"), encoding: .utf8)
        return ExportInput(title: "Landing", code: Array(repeating: code, count: roots),
                           layers: Array(repeating: try value("node.json"), count: roots),
                           variables: try variables ?? [value("variables.json")], assets: try assets ?? self.assets())
    }

    /// The body of the first rule `selector {` in `css`.
    private func rule(_ css: String, _ selector: String) -> String? {
        guard let r = css.range(of: "\n\(selector) {\n") else { return nil }
        let rest = css[r.upperBound...]
        return rest.range(of: "}").map { String(rest[..<$0.lowerBound]) }
    }

    @Test func buildsCompleteDocument() throws {
        let b = HTMLExport.build(try input())
        #expect(b.html.hasPrefix("<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"))
        #expect(b.html.contains("<meta name=\"viewport\""))
        #expect(b.html.contains("<title>Landing</title>"))
        #expect(b.html.contains("<style>\n" + ExportStyles.reset))
        #expect(b.html.contains("font-family: \"Inter\", system-ui"))
        #expect(b.html.hasSuffix("</body>\n</html>\n"))
        let rest = b.html.replacingOccurrences(of: "https://example.com", with: "")
            .replacingOccurrences(of: "http://www.w3.org/2000/svg", with: "")
        #expect(!rest.contains("http"))
        #expect(b.warnings == ["link dropped: Bad link"])
        #expect(ExportStyles.fallback("JetBrains Mono").hasPrefix("ui-monospace"))
    }

    @Test func themesFromVariables() throws {
        let h = HTMLExport.build(try input()).html
        let light = try #require(rule(h, "[data-theme=\"light\"]"))
        let dark = try #require(rule(h, "[data-theme=\"dark\"]"))
        #expect(light.contains("--color-bg: #FAFAF7;") && light.contains("--space-m: 16px;"))
        #expect(dark.contains("--color-bg: #111317;") && dark.contains("--color-text: #ECEDEF;") && dark.contains("--space-m: 16px;"))
        #expect(h.contains("@media (prefers-color-scheme: dark) {\n  :root:not([data-theme]) {\n    --space-m: 16px;\n    --color-bg: #111317;"))

        let ds: JSONValue = .object([
            "collections": .array([.object(["id": .string("C"), "name": .string("DS"), "modes": .array([
                .object(["id": .string("C/l"), "name": .string("Light")]), .object(["id": .string("C/d"), "name": .string("Dark")])])])]),
            "variables": .array([
                .object(["id": .string("V1"), "collection": .string("C"), "name": .string("base/black"), "resolvedType": .string("color"),
                         "values": .object(["C/l": .object(["type": .string("color"), "value": .object(["r": .number(0), "g": .number(0), "b": .number(0), "a": .number(1)])])])]),
                .object(["id": .string("V2"), "collection": .string("C"), "name": .string("color/bg"), "resolvedType": .string("color"),
                         "values": .object(["C/l": .object(["type": .string("color"), "value": .object(["r": .number(1), "g": .number(1), "b": .number(1), "a": .number(0.5)])]),
                                            "C/d": .object(["type": .string("alias"), "value": .string("V1")])])]),
            ]),
        ])
        let h2 = HTMLExport.build(try input(variables: [try value("variables.json"), ds])).html
        #expect(try #require(rule(h2, "[data-theme=\"dark\"]")).contains("--color-bg: #000000;"))
        #expect(try #require(rule(h2, "[data-theme=\"light\"]")).contains("--color-bg: #FFFFFF80;"))
    }

    @Test func gridAndResponsive() throws {
        let h = HTMLExport.build(try input()).html
        let features = try #require(rule(h, ".features"))
        #expect(features.contains("display: grid;") && features.contains("grid-template-columns: 1fr 1fr 200px;"))
        #expect(features.contains("column-gap: 0px;") && features.contains("row-gap: 10px;"))
        #expect(!features.contains("flex-direction") && !features.contains("width:"))
        let landing = try #require(rule(h, ".landing"))
        #expect(landing.contains("max-width: 800px;") && landing.contains("width: 100%;") && landing.contains("margin: 0 auto;"))
        #expect(!(try #require(rule(h, ".title"))).contains("width:"))
        #expect(try #require(rule(h, ".list")).contains("width: 100px;"))
        #expect(h.contains("@media (max-width: 640px) {\n  .features { grid-template-columns: 1fr; }\n}\n"))
    }

    @Test func assetsInlinedOrFiled() throws {
        let b = HTMLExport.build(try input())
        #expect(b.html.contains("<div class=\"icon-star\"><svg "))
        #expect(!(try #require(rule(b.html, ".icon-star"))).contains("background"))
        #expect(b.html.contains("<img class=\"photo\" src=\"assets/photo-19.png\" alt=\"Photo\">"))
        #expect(b.files.map(\.path) == ["assets/photo-19.png"])
        let photo = try #require(rule(b.html, ".photo"))
        #expect(!photo.contains("url(image.png)") && photo.contains("object-fit: cover;"))
    }

    @Test func unsafeSVGBecomesImg() throws {
        let bad = ExportAsset(id: "18", name: "Icon Star", kind: "icon", data: Data("<svg onload=\"x()\"></svg>".utf8))
        let b = HTMLExport.build(try input(assets: [bad]))
        #expect(b.html.contains("<img class=\"icon-star\" src=\"assets/icon-star-18.svg\" alt=\"Icon Star\">"))
        #expect(!b.html.contains("onload"))
        #expect(b.files.map(\.path) == ["assets/icon-star-18.svg"])
        #expect(b.warnings.first == "unsafe svg exported as file: Icon Star")
    }

    @Test func svgSanitizerCatchesBypasses() throws {
        for svg in ["<svg/onload=alert(1)>", "<svg x=\"\"onload=\"alert(1)\">", "<svg><a href=\"&#106;avascript:x\">",
                    "<svg><a href=\"java\tscript:x\">", "<svg><image href=\"https://evil.test/a.png\"/></svg>",
                    "<svg><style>@import url(//x.test/a.css)</style></svg>",
                    "<svg><image href=\"data:image/svg+xml;base64,PHN2Zz4=\"/></svg>", "<svg><use href=\"DATA :x\"/></svg>"] {
            let a = ExportAsset(id: "18", name: "Icon Star", kind: "icon", data: Data(svg.utf8))
            let b = HTMLExport.build(try input(assets: [a]))
            #expect(b.html.contains("<img class=\"icon-star\" src=\"assets/icon-star-18.svg\""), "\(svg)")
            #expect(b.files.count == 1 && b.warnings.first == "unsafe svg exported as file: Icon Star")
        }
        #expect(!HTMLExport.unsafeSVG("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><path d=\"M0 0\"/></svg>"))
    }

    @Test func assetsKeepTagsAndSafePaths() throws {
        var i = try input(assets: [ExportAsset(id: "19", name: "Photo", kind: "image", data: Data())])
        guard case .object(var o) = i.layers[0], case .array(var kids)? = o["children"] else { Issue.record(); return }
        for k in kids.indices { if case .object(var c) = kids[k], c["name"] == .string("Photo") { c["name"] = .string("Header image"); kids[k] = .object(c) } }
        o["children"] = .array(kids)
        i.layers = [.object(o)]
        i.code = [i.code[0].replacingOccurrences(of: "photo", with: "header-image")]
        let h = HTMLExport.build(i).html
        #expect(h.contains("<img class=\"header-image\" src=\"assets/photo-19.png\""))
        #expect(!h.contains("<header"))

        let odd = ExportAsset(id: "../1:2", name: "Photo", kind: "image", data: Data())
        var j = try input(assets: [odd])
        j.layers = [try value("node.json")].map { v in
            guard case .object(var o) = v, case .array(var kids)? = o["children"] else { return v }
            for k in kids.indices { if case .object(var c) = kids[k], c["name"] == .string("Photo") { c["id"] = .string("../1:2"); kids[k] = .object(c) } }
            o["children"] = .array(kids); return .object(o)
        }
        #expect(HTMLExport.build(j).files.map(\.path) == ["assets/photo----1-2.png"])
    }

    @Test func stretchAndGrowApplyIndependently() {
        let tree = MarkupNode(tag: "main", cls: "r", attrs: [], children: [
            MarkupNode(tag: "div", cls: "a", attrs: [], children: [], layer: nil)], layer: nil)
        var rules = [CSSRule(selector: ".a", decls: [Attr(name: "align-self", value: "stretch"), Attr(name: "flex", value: "1 1 0"),
                                                      Attr(name: "width", value: "10px")])]
        _ = ExportStyles.adapt(&rules, tree: tree)
        #expect(rules[0].decls == [Attr(name: "align-self", value: "stretch"), Attr(name: "flex", value: "1 1 0"), Attr(name: "min-width", value: "0")])
    }

    @Test func pageWithTwoRootsPrefixesClasses() throws {
        let b = HTMLExport.build(try input(roots: 2))
        #expect(b.html.contains("<main class=\"r2-landing\">") && b.html.contains("\n.r2-landing {\n"))
        #expect(b.html.components(separatedBy: "\n.landing {\n").count == 2)
        #expect(b.html.components(separatedBy: ":root {").count == 2)
        #expect(b.html.contains("<ul class=\"collie-list\">"))
        #expect(b.html.contains("  .r2-features { grid-template-columns: 1fr; }"))
        #expect(b.files.map(\.path) == ["assets/photo-19.png"])
    }

    @Test func hostileFontFamilyCannotInject() throws {
        var i = try input()
        // as figcraft writes them: `font-family: "<family>";` with only `"` made `'`
        i.code[0] = i.code[0].replacingOccurrences(of: "font-family: \"Inter\";\n  font-size: 48px;",
                                                   with: "font-family: \"</style><script>alert(1)</script>\";\n  font-size: 48px;")
        i.code[0] = i.code[0].replacingOccurrences(of: "font-family: \"Inter\";\n  font-size: 20px;",
                                                   with: "font-family: \"x\n}\n@font-face{src: url(https://x)}\n@font-face {\n  src: url(https://x);\n}\n.y {\n  background: url(https://x/a.png);\n  z: \";\n  font-size: 20px;")
        let b = HTMLExport.build(i)
        #expect(!b.html.contains("</style><script") && !b.html.contains("<script"))
        #expect(!b.html.contains("https://x") && !b.html.contains("@font-face"))
        #expect(b.html.contains("font-family: \"\\3c /style>\\3c script>alert(1)\\3c /script>\""))
        #expect(b.warnings.contains("unsafe css rule dropped") && b.warnings.contains("unsafe css dropped: .y background"))
        for v in ["\"Inter\"", "url(image.png) center / cover", "var(--x, #FFF)", "linear-gradient(90deg, #000 0%, #FFF 100%)",
                  "0px 4px 8px 0px rgba(0, 0, 0, 0.25)", "rotate(-45deg)", "url(pattern.png) repeat"] {
            #expect(ExportStyles.safeValue(v) == v, "\(v)")
        }
        for v in ["a;b", "a}b", "a{b", "a\\b", "@import x", "a\nb", "/* x", "url(https://x)", "URL(x.png)", "image-set(\"x.png\" 1x)"] {
            #expect(ExportStyles.safeValue(v) == nil, "\(v)")
        }
    }

    @Test func hugeNumbersDoNotTrap() throws {
        func grid(_ id: Double, _ cols: Double) -> Layer? {
            ExportMarkup.layer(.object(["id": .number(id), "name": .string("G"), "type": .string("FRAME"),
                                        "layout": .object(["mode": .string("grid"), "gridColumns": .number(cols)])]))
        }
        let big = try #require(grid(1e300, 1e12))
        #expect(big.gridColumns == 1000 && !big.id.isEmpty)
        #expect(try #require(grid(.infinity, .nan)).gridColumns == 1)
        #expect(try #require(grid(7, 2.5)).gridColumns == 1 && grid(7, 3)?.id == "7")
    }

    @Test func mismatchWarnsAndParsesCSS() throws {
        var i = try input(assets: [])
        i.layers = [.object(["id": .number(1), "name": .string("Other"), "type": .string("FRAME")])]
        #expect(HTMLExport.build(i).warnings == ["layer map mismatch: Other"])
        let p = ExportStyles.parse(":root {\n  --a: 1px;\n}\n.x {\n  color: red;\n}\n")
        #expect(p.root == [Attr(name: "--a", value: "1px")])
        #expect(p.rules == [CSSRule(selector: ".x", decls: [Attr(name: "color", value: "red")])])
        #expect(ExportStyles.cssVarName("Colors/Brand 500") == "--colors-brand-500")
        #expect(ExportStyles.cssVarName("x", web: "var(--brand, #fff)") == "--brand")
        #expect(ExportStyles.cssVarName("/") == "--variable")
    }
}
