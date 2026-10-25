import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// `artifact new`'s starter pages: slugs, tokens (seed and a real system's), offline and escaped.
@Suite struct ArtifactTemplateTests {
    @Test func slugCases() {
        #expect(ArtifactTemplates.slug("Meu Deck 2026!") == "meu-deck-2026")
        #expect(ArtifactTemplates.slug("../x") == "x")
        #expect(ArtifactTemplates.slug("!!!") == nil)
        #expect(ArtifactTemplates.slug("") == nil)
        #expect(ArtifactTemplates.slug(String(repeating: "a", count: 60)) == String(repeating: "a", count: 48))
        #expect(ArtifactTemplates.slug("Ação  Já") == "a-o-j")   // non-ASCII letters become `-` (ASCII slug)
        let long = ArtifactTemplates.slug(String(repeating: "a", count: 47) + " b")
        #expect(long == String(repeating: "a", count: 47), "\(String(describing: long))")   // no trailing `-` after the cut
    }

    @Test func seedTokensHaveLightAndDark() {
        let css = ArtifactTemplates.tokensCSS(variables: nil)
        #expect(css.contains(":root {") && css.contains("--accent: #2F6F4F;") && css.contains("--space-m: 16px;"), "\(css)")
        #expect(css.contains("[data-theme=\"light\"]") && css.contains("[data-theme=\"dark\"]"))
        #expect(css.contains("--accent: #7BD3A2;"))   // the dark value
    }

    @Test func systemVariablesOverrideSeed() {
        func s(_ x: String) -> JSONValue { .string(x) }
        func color(_ r: Double, _ g: Double, _ b: Double) -> JSONValue {
            .object(["type": s("color"), "value": .object(["r": .number(r), "g": .number(g), "b": .number(b), "a": .number(1)])])
        }
        let three: JSONValue = .object(["type": s("number"), "value": .number(3)])
        let list: JSONValue = .object([
            "collections": .array([.object(["id": s("c1"), "name": s("Tokens"),
                                            "modes": .array([.object(["id": s("m1"), "name": s("Light")]), .object(["id": s("m2"), "name": s("Dark")])])])]),
            "variables": .array([
                .object(["id": s("v1"), "name": s("accent"), "collection": s("c1"), "values": .object(["m1": color(1, 0, 0), "m2": color(0, 0, 1)])]),
                .object(["id": s("v2"), "name": s("brand/extra"), "collection": s("c1"), "values": .object(["m1": three, "m2": three])]),
            ]),
        ])
        let css = ArtifactTemplates.tokensCSS(variables: list)
        let root = String(css[css.range(of: ":root {")!.lowerBound...].prefix { $0 != "}" })
        #expect(root.contains("--accent: #FF0000;") && !root.contains("#2F6F4F") && root.contains("--brand-extra: 3px;"), "\(root)")
        #expect(root.contains("--bg: #FAFAF7;"))   // the seed's other names stay
        #expect(css.contains("--accent: #0000FF;"))   // its dark value in the dark theme
    }

    @Test func everyKindIsOffline() throws {
        let allowed: Set<String> = ["bg", "surface", "text", "muted", "accent", "space-s", "space-m", "space-l", "space-xl",
                                    "radius-card", "type-body", "type-h1", "type-h2", "type-h3"]
        for kind in ArtifactTemplates.Kind.allCases { for libs in [[], Self.libs] {
            let full = ArtifactTemplates.render(kind, title: "Título", tokensCSS: ArtifactTemplates.tokensCSS(variables: nil), libs: libs)
            #expect(full.hasPrefix("<!doctype html>") && full.contains("<html lang=\"pt-BR\">") && full.contains("<title>Título</title>"), "\(kind)")
            // the only external sources: <script src="collie-lib://…">
            let html = full.replacing(/<script src="collie-lib:\/\/lib\/[a-z0-9.@\/-]+"><\/script>/, with: "")
            #expect(!html.lowercased().contains("http") && !html.contains("//"), "\(kind)")
            #expect(!html.contains("<script src") && html.components(separatedBy: "<style>").count == 2, "\(kind)")
            for m in html.matches(of: /(?:src|href)\s*=\s*["']?([^"' >]*)/) { #expect(m.1.hasPrefix("#"), "\(kind): \(m.0)") }
            let used = Set(html.matches(of: /var\(--([a-z0-9-]+)\)/).map { String($0.1) })
            #expect(used.isSubset(of: allowed), "\(kind): \(used.subtracting(allowed))")
        } }
        let deck = ArtifactTemplates.render(.deck, title: "D", tokensCSS: "")
        #expect(deck.components(separatedBy: "<section class=\"slide").count == 5)
        #expect(ArtifactTemplates.render(.dashboard, title: "D", tokensCSS: "").contains("const data = ["))
    }

    static let libs: [WebLibEntry] = [("react", "18.3.1", "react.production.min.js", "React"), ("react-dom", "18.3.1", "react-dom.production.min.js", "ReactDOM"),
                                      ("htm", "3.1.1", "htm.umd.js", "htm"), ("chart.js", "4.4.9", "chart.umd.js", "Chart"),
                                      ("lucide", "0.469.0", "lucide.min.js", "lucide")]
        .map { WebLibEntry(name: $0.0, version: $0.1, files: [$0.2], licence: "MIT", global: $0.3) }

    @Test func templatesUseVersionedLibURLs() {
        func srcs(_ k: ArtifactTemplates.Kind) -> [String] {
            ArtifactTemplates.render(k, title: "T", tokensCSS: "", libs: Self.libs).matches(of: /<script src="([^"]+)">/).map { String($0.1) }
        }
        let lucide = "collie-lib://lib/lucide@0.469.0/lucide.min.js"
        #expect(srcs(.dashboard) == ["collie-lib://lib/chart.js@4.4.9/chart.umd.js", lucide])
        #expect(srcs(.prototype) == ["collie-lib://lib/react@18.3.1/react.production.min.js", "collie-lib://lib/react-dom@18.3.1/react-dom.production.min.js",
                                     "collie-lib://lib/htm@3.1.1/htm.umd.js", lucide])
        #expect(srcs(.deck) == [lucide] && srcs(.doc) == [lucide])
        let p = ArtifactTemplates.render(.prototype, title: "T", tokensCSS: "", libs: Self.libs)
        #expect(p.contains("html`<${App}") && p.contains("Bibliotecas offline indisponíveis") && p.contains("lucide.createIcons("))
        #expect(ArtifactTemplates.render(.dashboard, title: "T", tokensCSS: "", libs: Self.libs).contains("new Chart("))
        // only the libraries the manifest has
        #expect(!ArtifactTemplates.render(.dashboard, title: "T", tokensCSS: "", libs: Array(Self.libs.prefix(3))).contains("<script src"))
    }

    @Test func templatesWithoutLibsUnchanged() {
        for kind in ArtifactTemplates.Kind.allCases {
            let css = ArtifactTemplates.tokensCSS(variables: nil)
            #expect(ArtifactTemplates.render(kind, title: "T", tokensCSS: css, libs: []) == ArtifactTemplates.render(kind, title: "T", tokensCSS: css), "\(kind)")
            #expect(!ArtifactTemplates.render(kind, title: "T", tokensCSS: css, libs: []).contains("collie-lib"))
        }
    }

    @Test func titleIsEscaped() {
        for kind in ArtifactTemplates.Kind.allCases {
            let html = ArtifactTemplates.render(kind, title: "<script>alert(\"x\")</script>&", tokensCSS: "")
            #expect(html.contains("&lt;script&gt;") && !html.contains("<script>alert"), "\(kind)")
        }
    }
}
