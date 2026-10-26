import Testing
import Foundation
@testable import CollieCore

@Suite struct FontsTests {
    @Test func familyNames() {
        for ok in ["Inter", "DM Mono", "Noto Sans JP", String(repeating: "a", count: 64)] { #expect(Fonts.validFamily(ok), "\(ok)") }
        for bad in ["", " Inter", "Inter ", "../x", "In\"ter", "Inter;", "Açaí", String(repeating: "a", count: 65), "a/b"] {
            #expect(!Fonts.validFamily(bad), "\(bad)")
        }
        #expect(Fonts.validFile("SpaceGrotesk[wght].ttf") && Fonts.validFile("normal-400-0.woff2"))
        for bad in [".x.woff2", "a/b.woff2", "x.js", "font.json", "..", "a b.ttf"] { #expect(!Fonts.validFile(bad), "\(bad)") }
    }

    @Test func requestsParseWeights() {
        let q = URLComponents(string: "collie-lib://fonts/css?family=DM%20Mono:400,500&family=Space+Grotesk&family=../x&family=DM%20Mono")!.queryItems!
        let r = Fonts.requests(q)
        #expect(r.map(\.family) == ["DM Mono", "Space Grotesk"])
        #expect(r[0].weights == [400, 500] && r[1].weights == nil)
    }

    @Test func cssFiltersWeightsAndRanges() {
        let mono = Fonts.bundled[1], grotesk = Fonts.bundled[0]
        let css = Fonts.css([(mono, [500]), (grotesk, [400])])
        #expect(css.contains(#"src: url("collie-lib://fonts/DM%20Mono/DMMono-Medium.ttf") format("truetype");"#), "\(css)")
        #expect(!css.contains("DMMono-Regular") && css.contains("font-weight: 300 700;") && css.contains("SpaceGrotesk%5Bwght%5D.ttf"))
        #expect(Fonts.css([(grotesk, [900])]).isEmpty)
        let g = FontFamily(family: "Inter", faces: [.init(style: "italic", weight: "700", file: "italic-700-0.woff2", unicodeRange: "U+0000-00FF, U+0131"),
                                                     .init(style: "normal", weight: "400", file: "x.woff2", unicodeRange: "U+0000;} body{color:red")])
        let c = Fonts.css([(g, nil)])
        #expect(c.contains("font-style: italic;") && c.contains("unicode-range: U+0000-00FF, U+0131;") && c.contains(#"format("woff2")"#))
        #expect(!c.contains("color:red"))
        #expect(Fonts.cssURL(["Space Grotesk", "DM Mono"]) == "collie-lib://fonts/css?family=Space%20Grotesk&family=DM%20Mono")
    }

    @Test func downloadedReadsItsFamilyOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID().uuidString)")
        let f = dir.appendingPathComponent("Inter")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(FontFamily(family: "Inter", faces: [])).write(to: f.appendingPathComponent(Fonts.metaFile))
        #expect(Fonts.downloaded("Inter", in: dir)?.family == "Inter")
        #expect(Fonts.downloaded("Lato", in: dir) == nil && Fonts.downloaded("../Inter", in: dir) == nil)
        try JSONEncoder().encode(FontFamily(family: "Other", faces: [])).write(to: f.appendingPathComponent(Fonts.metaFile))
        #expect(Fonts.downloaded("Inter", in: dir) == nil)
    }
}
