import Testing
import Foundation
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
        for kind in ArtifactTemplates.Kind.allCases {
            let html = ArtifactTemplates.render(kind, title: "Título", tokensCSS: ArtifactTemplates.tokensCSS(variables: nil))
            #expect(html.hasPrefix("<!doctype html>") && html.contains("<html lang=\"pt-BR\">") && html.contains("<title>Título</title>"), "\(kind)")
            #expect(!html.lowercased().contains("http") && !html.contains("//"), "\(kind)")
            #expect(!html.contains("<script src") && html.components(separatedBy: "<style>").count == 2, "\(kind)")
            for m in html.matches(of: /(?:src|href)\s*=\s*["']?([^"' >]*)/) { #expect(m.1.hasPrefix("#"), "\(kind): \(m.0)") }
            let used = Set(html.matches(of: /var\(--([a-z0-9-]+)\)/).map { String($0.1) })
            #expect(used.isSubset(of: allowed), "\(kind): \(used.subtracting(allowed))")
        }
        let deck = ArtifactTemplates.render(.deck, title: "D", tokensCSS: "")
        #expect(deck.components(separatedBy: "<section class=\"slide").count == 5)
        #expect(ArtifactTemplates.render(.dashboard, title: "D", tokensCSS: "").contains("const data = ["))
    }

    @Test func titleIsEscaped() {
        for kind in ArtifactTemplates.Kind.allCases {
            let html = ArtifactTemplates.render(kind, title: "<script>alert(\"x\")</script>&", tokensCSS: "")
            #expect(html.contains("&lt;script&gt;") && !html.contains("<script>alert"), "\(kind)")
        }
    }
}
