import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// The landing page's snapshot (Task 1's fixture) and its payload files.
let landingImport = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/html-import/landing-import")

func landingSnapshot() throws -> (DOMSnapshot, [String: Data]) {
    let s = try JSONDecoder().decode(DOMSnapshot.self, from: Data(contentsOf: landingImport.appendingPathComponent("snapshot.json")))
    var payloads: [String: Data] = [:]
    for f in ["img-1.png", "svg-1.svg"] { payloads[f] = try Data(contentsOf: landingImport.appendingPathComponent(f)) }
    return (s, payloads)
}

private let inter = FontBook(families: ["Inter": ["Regular", "Italic", "SemiBold", "Bold"]])

private func node(_ tag: String, _ x: Double = 0, _ y: Double = 0, _ w: Double = 100, _ h: Double = 20,
                  style: [String: String] = [:], text: String? = nil, href: String? = nil, cls: String? = nil,
                  runs: [DOMRun]? = nil, children: [DOMNode] = []) -> DOMNode {
    DOMNode(tag: tag, x: x, y: y, w: w, h: h, style: style, children: children, text: text, runs: runs, href: href, cls: cls)
}

private func page(_ children: [DOMNode]) -> DOMSnapshot {
    DOMSnapshot(title: "t", width: 800, height: 600, truncated: false, blocked: [],
                root: node("html", 0, 0, 800, 600, children: [node("body", 0, 0, 800, 600, children: children)]))
}

private func params(_ step: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = step, case .object(let p)? = o["params"] else { return [:] }
    return p
}
private func command(_ step: JSONValue) -> String? {
    guard case .object(let o) = step, case .string(let c)? = o["command"] else { return nil }
    return c
}
private func props(_ step: JSONValue) -> [String: JSONValue] {
    guard case .object(let p)? = params(step)["props"] else { return [:] }
    return p
}
/// Every `{"$step": n}` inside `v`.
private func refs(_ v: JSONValue) -> [Int] {
    switch v {
    case .object(let o):
        if o.count == 1, case .number(let n)? = o["$step"] { return [Int(n)] }
        return o.values.flatMap(refs)
    case .array(let a): return a.flatMap(refs)
    default: return []
    }
}

@Suite struct HTMLImportTests {
    @Test func colorUsesRecorded() throws {
        let (s, payloads) = try landingSnapshot()
        let (steps, _, uses) = HTMLImport.steps(s, payloads: payloads, fonts: inter, name: "Landing")
        #expect(uses.contains { $0 == (0, "fill", "#FFFFFF") }, "\(uses)")   // the body's background on the screen
        let h1 = try #require(steps.firstIndex { params($0)["type"] == .string("text")
            && params($0)["text"].map { "\($0)".contains("Construa telas") } == true })
        #expect(uses.contains { $0 == (h1, "textFill", "#1F2430") }, "\(uses)")
        let button = try #require(steps.firstIndex { props($0)["fills"] == .array([.string("#3B5BDB")]) })
        #expect(uses.contains { $0 == (button, "fill", "#3B5BDB") }, "\(uses)")
        // (step 1: the body) translucent: literal; a border: stroke; gradients and runs: none
        let (s2, _, u2) = HTMLImport.steps(page([node("div", style: ["backgroundColor": "rgba(255, 0, 0, 0.5)", "borderTopWidth": "1px",
                                                                      "borderTopColor": "rgb(0, 0, 255)"]),
                                                  node("div", style: ["backgroundImage": "linear-gradient(rgb(0, 0, 0), rgb(255, 255, 255))"]),
                                                  node("p", text: "ab", runs: [DOMRun(start: 0, end: 1, color: "rgb(1, 2, 3)")])]),
                                           payloads: [:], fonts: inter, name: "p")
        #expect(!u2.contains { $0.step == 2 && $0.field == "fill" } && u2.contains { $0 == (2, "stroke", "#0000FF") }, "\(u2)")
        #expect(!u2.contains { $0.hex == "#010203" || $0.step == 3 }, "\(u2) \(s2)")
    }

    @Test func bindingIsDeterministic() {
        let rgba = { (r: Double, g: Double, b: Double, a: Double) -> JSONValue in
            ["type": "color", "value": ["r": .number(r), "g": .number(g), "b": .number(b), "a": .number(a)]]
        }
        let list: JSONValue = [
            "collections": [["id": "c", "modes": [["id": "m1", "name": "Light"], ["id": "m2", "name": "Dark"]]]],
            "variables": [
                ["id": "z", "name": "zeta", "collection": "c", "values": ["m1": rgba(1, 1, 1, 1), "m2": rgba(0, 0, 0, 1)]],
                ["id": "a", "name": "alpha", "collection": "c", "values": ["m1": rgba(1, 1, 1, 1)]],
                ["id": "d", "name": "dark-only", "collection": "c", "values": ["m2": rgba(0, 0, 0, 1)]],
                ["id": "h", "name": "half", "collection": "c", "values": ["m1": rgba(1, 0, 0, 0.5)]],
                ["id": "p", "name": "_private", "collection": "c", "values": ["m1": rgba(0, 1, 0, 1)]],
                ["id": "g", "name": "gap", "collection": "c", "values": ["m1": ["type": "number", "value": 8]]],
            ],
        ]
        let names = HTMLImport.colorNames(list, published: ["z", "a", "d", "h", "g"]).mapValues { "\($0.id) \($0.name)" }
        #expect(names == ["#FFFFFF": "a alpha", "#FF000080": "h half"])   // _private: not published
        #expect(HTMLImport.colorNames(list, published: ["z"]).mapValues(\.name) == ["#FFFFFF": "zeta"])
        #expect(HTMLImport.normHex("#ffffffff") == "#FFFFFF" && HTMLImport.normHex("#ff000080") == "#FF000080")
    }

    @Test func landingMapsToSteps() throws {
        let (s, payloads) = try landingSnapshot()
        let (steps, warnings, _) = HTMLImport.steps(s, payloads: payloads, fonts: inter, name: "Landing")
        #expect(command(steps[0]) == "node.create")
        #expect(params(steps[0])["width"] == .number(1440))
        #expect(params(steps[0])["name"] == .string("Landing"))
        #expect(steps.contains { props($0)["layout"] == .string("horizontal") })
        #expect(steps.contains { props($0)["layout"] == .string("grid") && props($0)["gridColumns"] == .number(3) })
        #expect(steps.contains { params($0)["type"] == .string("text") && props($0)["fontSize"] == .number(48) })
        #expect(steps.contains { command($0) == "text.style" && params($0)["hyperlink"] == .string("https://example.com") })
        #expect(steps.contains { command($0) == "image.place" && params($0)["mode"] == .string("fill") })
        #expect(steps.contains { command($0) == "file.import" })
        for (i, step) in steps.enumerated() { #expect(refs(step).allSatisfy { $0 < i }) }
        #expect(warnings.contains("blocked network resource: https://example.com/remote.png"))
        #expect(warnings.contains { $0.hasPrefix("image not imported") })
    }

    @Test func flexAndAlignMapping() {
        let col = node("div", 0, 0, 200, 100, style: ["display": "flex", "flexDirection": "column", "justifyContent": "space-between",
                                                   "alignItems": "center", "rowGap": "12px"],
                       children: [node("p", 10, 0, 50, 20, text: "a")])
        let (steps, _, _) = HTMLImport.steps(page([col]), payloads: [:], fonts: inter, name: "p")
        let f = try! #require(steps.first { props($0)["layout"] == .string("vertical") })
        #expect(props(f)["mainAlign"] == .string("spaceBetween"))
        #expect(props(f)["crossAlign"] == .string("center"))
        #expect(props(f)["gap"] == .number(12))
    }

    @Test func flexOffsetsBecomeSpacers() {
        // [a] gap [b], b 300px further right than auto layout would put it (a flex: 1 spacer or a margin)
        let header = node("header", 0, 0, 800, 40, style: ["display": "flex", "columnGap": "10px", "paddingLeft": "20px"],
                          children: [node("div", 20, 0, 50, 40, cls: "a"), node("div", 380, 0, 50, 40, cls: "b")])
        let (steps, _, _) = HTMLImport.steps(page([header]), payloads: [:], fonts: inter, name: "p")
        let i = try! #require(steps.firstIndex { props($0)["layout"] == "horizontal" })
        #expect(props(steps[i])["gap"] == 10 && props(steps[i])["mainAlign"] == "min")
        let kids = steps.filter { params($0)["parent"] == .object(["$step": .number(Double(i))]) }
        #expect(kids.map { params($0)["name"] } == [".a", "spacer", ".b"])
        // 380 = 20 + 50 + 10 + spacer + 10
        #expect(params(kids[1])["width"] == 290 && params(kids[1])["height"] == 0 && props(kids[1])["fills"] == [])

        // centred, closer than the gap: gap 0, spacers carry every distance
        let row = node("div", 0, 0, 800, 40, style: ["display": "flex", "columnGap": "10px", "justifyContent": "center"],
                       children: [node("div", 345, 0, 50, 40, cls: "a"), node("div", 400, 0, 50, 40, cls: "b")])
        let (s2, _, _) = HTMLImport.steps(page([row]), payloads: [:], fonts: inter, name: "p")
        let j = try! #require(s2.firstIndex { props($0)["layout"] == "horizontal" })
        #expect(props(s2[j])["gap"] == 0 && props(s2[j])["mainAlign"] == "min")
        let k2 = s2.filter { params($0)["parent"] == .object(["$step": .number(Double(j))]) }
        #expect(k2.map { params($0)["width"] } == [345, 50, 5, 50])

        // in place already: untouched
        let fits = node("div", 0, 0, 800, 40, style: ["display": "flex", "columnGap": "10px", "justifyContent": "center"],
                        children: [node("div", 0, 0, 395, 40), node("div", 405, 0, 395, 40)])
        let (s3, _, _) = HTMLImport.steps(page([fits]), payloads: [:], fonts: inter, name: "p")
        #expect(!s3.contains { params($0)["name"] == "spacer" })
        #expect(s3.contains { props($0)["mainAlign"] == "center" })

        // overlapping kids (negative margin): no auto layout, a warning
        let overlap = node("div", 0, 0, 800, 40, style: ["display": "flex"], cls: "o",
                           children: [node("div", 0, 0, 100, 40), node("div", 50, 0, 100, 40)])
        let (s4, w4, _) = HTMLImport.steps(page([overlap]), payloads: [:], fonts: inter, name: "p")
        #expect(!s4.contains { props($0)["layout"] != nil })
        #expect(w4.contains("flex children overlap, placed by position: .o"))
    }

    @Test func insetClipPathShrinksTheBox() {
        let bar = node("div", 100, 10, 400, 8, style: ["display": "flex"], children: [
            node("div", 100, 10, 200, 8, style: ["backgroundColor": "rgb(255, 0, 0)", "clipPath": "inset(0px 75% 0px 0px)"], cls: "played"),
            node("div", 300, 10, 200, 8, style: ["backgroundColor": "rgb(0, 0, 0)", "clipPath": "circle(50%)"], cls: "c"),
        ])
        let (steps, warnings, _) = HTMLImport.steps(page([bar]), payloads: [:], fonts: inter, name: "p")
        let played = try! #require(steps.first { params($0)["name"] == ".played" })
        #expect(params(played)["width"] == 50 && params(played)["height"] == 8 && props(played)["clip"] == true)
        #expect(warnings.contains("clip-path circle(50%) not imported: .c"))
        // the box it no longer fills is kept by a spacer
        #expect(steps.contains { params($0)["name"] == "spacer" && params($0)["width"] == 150 })
        // children move with the inset: 10px down, 20% in
        let inner = node("div", 0, 0, 100, 50, style: ["clipPath": "inset(10px 0px 0px 20%)"], children: [node("div", 30, 20, 10, 10, cls: "k")])
        let (s2, _, _) = HTMLImport.steps(page([inner]), payloads: [:], fonts: inter, name: "p")
        let k = try! #require(s2.first { params($0)["name"] == ".k" })
        #expect(params(k)["x"] == 10 && params(k)["y"] == 10)
    }

    @Test func radialGradientsAndTransparentStops() {
        let st = ["backgroundImage": "radial-gradient(50% 25% at 25% 100%, rgb(255, 0, 0) 0%, rgba(0, 0, 0, 0) 60%), "
                  + "linear-gradient(rgb(0, 0, 255), rgba(0, 0, 0, 0) 50%, rgb(0, 255, 0))"]
        let (steps, _, _) = HTMLImport.steps(page([node("div", 0, 0, 400, 200, style: st)]), payloads: [:], fonts: inter, name: "p")
        let f = props(try! #require(steps.first { params($0)["name"] == "div" }))
        guard case .array(let fills)? = f["fills"], fills.count == 2 else { Issue.record("fills: \(String(describing: f["fills"]))"); return }
        // engine order: last CSS layer first
        #expect(fills[1] == ["type": "radialGradient", "stops": [["color": "#FF0000", "position": 0], ["color": "#FF000000", "position": .number(0.6)]],
                             "from": [.number(0.25), 1], "to": [.number(0.75), 1], "width": [.number(0.25), .number(1.25)]])
        if case .object(let lin) = fills[0] {
            #expect(lin["stops"] == [["color": "#0000FF", "position": 0], ["color": "#0000FF00", "position": .number(0.5)],
                                     ["color": "#00FF0000", "position": .number(0.5)], ["color": "#00FF00", "position": 1]])
        }
        // no size: farthest corner; circle px radius
        let g = HTMLImport.radial("at 0% 0%", 400, 200)
        #expect(g.cx == 0 && g.cy == 0 && abs(g.rx - 400 * 2.0.squareRoot()) < 1e-9 && abs(g.ry - 200 * 2.0.squareRoot()) < 1e-9)
        let c = HTMLImport.radial("circle 30px at center top", 400, 200)
        #expect(c == (200, 0, 30, 30))
    }

    @Test func overflowAutoClipsAndPaddedLeavesAreFrames() {
        let (steps, _, _) = HTMLImport.steps(page([
            node("div", 0, 0, 100, 100, style: ["overflow": "visible auto"], cls: "scroll"),
            node("p", 0, 100, 200, 40, style: ["paddingLeft": "16px", "paddingTop": "10px", "paddingBottom": "10px"], text: "pad", cls: "pad"),
        ]), payloads: [:], fonts: inter, name: "p")
        #expect(props(try! #require(steps.first { params($0)["name"] == ".scroll" }))["clip"] == true)
        let i = try! #require(steps.firstIndex { params($0)["name"] == ".pad" && params($0)["type"] == "frame" })
        #expect(props(steps[i])["fills"] == [])
        let t = try! #require(steps.first { params($0)["type"] == "text" && params($0)["parent"] == .object(["$step": .number(Double(i))]) })
        #expect(params(t)["x"] == 16 && params(t)["y"] == 10)
        #expect(props(t)["textAutoResize"] == "widthAndHeight")   // 20px inside the padding: one line
    }

    @Test func fontsFallBackWithWarning() {
        let st = ["fontFamily": "\"Archivo\", sans-serif", "fontWeight": "800"]
        let (steps, warnings, _) = HTMLImport.steps(page([node("p", style: st, text: "one"), node("p", 0, 30, style: st, text: "two")]),
                                                 payloads: [:], fonts: inter, name: "p")
        let texts = steps.filter { params($0)["type"] == .string("text") }
        #expect(texts.count == 2)
        for t in texts {
            #expect(props(t)["fontFamily"] == .string("Inter"))
            #expect(props(t)["fontStyle"] == .string("Bold"))
        }
        #expect(warnings.filter { $0 == "font Archivo replaced by Inter" }.count == 1)
    }

    @Test func hostileContentStaysData() {
        let (steps, warnings, _) = HTMLImport.steps(page([
            node("a", text: "click", href: "javascript:alert(1)"),
            node("p", 0, 30, text: "<script>x</script>", runs: [DOMRun(start: 0, end: 3, href: "javascript:x")]),
            node("div", 0, 60, cls: "a\"b"),
        ]), payloads: ["../etc/passwd": Data()], fonts: inter, name: "p")
        #expect(!steps.contains { params($0)["hyperlink"] != nil })
        #expect(warnings.contains("link dropped: click"))
        #expect(warnings.contains("link dropped: <sc"))
        #expect(steps.contains { params($0)["text"] == .string("<script>x</script>") })
        #expect(steps.contains { params($0)["name"] == .string(".a\"b") })
        let allowed: Set = ["node.create", "node.set", "text.style", "image.place", "file.import", "node.reparent"]
        #expect(steps.allSatisfy { command($0).map(allowed.contains) == true })
    }

    @Test func unknownPayloadNamesAreIgnored() {
        var img = node("img", 0, 0, 10, 10)
        img.image = DOMImage(file: "../img-1.png", w: 1, h: 1, fit: "fill")
        let (steps, warnings, _) = HTMLImport.steps(page([img]), payloads: ["../img-1.png": Data([1])], fonts: inter, name: "p")
        #expect(!steps.contains { command($0) == "image.place" })
        #expect(warnings.contains { $0.hasPrefix("image not imported") })
    }

    @Test func boxStylesMapping() {
        let card = node("div", 0, 0, 200, 100, style: [
            "backgroundColor": "rgba(255, 0, 0, 0.5)",
            "backgroundImage": "linear-gradient(90deg, rgb(255, 0, 0) 0%, rgba(0, 0, 255, 0.5) 100%)",
            "borderTopWidth": "2px", "borderRightWidth": "2px", "borderBottomWidth": "2px", "borderLeftWidth": "2px",
            "borderTopColor": "rgb(0, 0, 0)", "borderRightColor": "rgb(0, 0, 0)", "borderBottomColor": "rgb(0, 0, 0)",
            "borderLeftColor": "rgb(0, 0, 0)", "borderTopStyle": "dashed",
            "borderTopLeftRadius": "50%", "borderTopRightRadius": "50%", "borderBottomRightRadius": "50%",
            "borderBottomLeftRadius": "50%",
            "boxShadow": "rgba(0, 0, 0, 0.5) 1px 2px 3px 4px inset", "overflow": "hidden",
        ])
        let (steps, warnings, _) = HTMLImport.steps(page([card]), payloads: [:], fonts: inter, name: "p")
        let p = props(try! #require(steps.first { params($0)["name"] == "div" }))
        #expect(p["fills"] == [["type": "solid", "color": "#FF0000", "opacity": .number(0.5)],
                               ["type": "linearGradient", "stops": [["color": "#FF0000", "position": 0], ["color": "#0000FF80", "position": 1]],
                                "from": [0, .number(0.5)], "to": [1, .number(0.5)]]])
        #expect(p["strokes"] == ["#000000"] && p["strokeWeight"] == 2 && p["strokeAlign"] == "inside")
        #expect(p["cornerRadius"] == 50)
        #expect(p["effects"] == [["type": "innerShadow", "offset": [1, 2], "radius": 3, "spread": 4, "color": "#00000080"]])
        #expect(p["clip"] == true)
        #expect(warnings.contains("border style dashed drawn solid: div"))
        let (_, w2, _) = HTMLImport.steps(page([node("div", style: ["borderLeftWidth": "1px", "borderLeftStyle": "dotted"])]),
                                       payloads: [:], fonts: inter, name: "p")
        #expect(w2.contains("border style dotted drawn solid: div"))
    }

    @Test func runOffsetsAreScalars() {
        let (steps, _, _) = HTMLImport.steps(page([node("p", text: "😀 link", runs: [DOMRun(start: 3, end: 7, href: "https://x.com")])]),
                                          payloads: [:], fonts: inter, name: "p")
        let st = try! #require(steps.first { params($0)["hyperlink"] != nil })
        #expect(params(st)["start"] == 2 && params(st)["end"] == 6)
    }

    @Test func textLeavesStartFromInitialValues() {
        let div = node("div", 0, 0, 200, 100, style: ["fontSize": "24px", "color": "rgb(255, 0, 0)"],
                       children: [node("p", text: "small")])
        let (steps, _, _) = HTMLImport.steps(page([div]), payloads: [:], fonts: inter, name: "p")
        let t = try! #require(steps.first { params($0)["type"] == "text" })
        #expect(props(t)["fontSize"] == 16)
        #expect(props(t)["fills"] == ["#000000"])
    }

    @Test func singleLineTextGrowsSideways() {
        let (steps, _, _) = HTMLImport.steps(page([node("p", 0, 0, 100, 20, text: "one"), node("p", 0, 30, 100, 60, text: "three lines")]),
                                          payloads: [:], fonts: inter, name: "p")
        let texts = steps.filter { params($0)["type"] == "text" }
        #expect(props(texts[0])["textAutoResize"] == "widthAndHeight" && params(texts[0])["width"] == nil)
        #expect(props(texts[1])["textAutoResize"] == "height" && params(texts[1])["width"] == 100)
        // a button: its content box decides, not the padded one
        let button = node("button", 0, 0, 160, 42, style: ["backgroundColor": "rgb(0, 0, 255)", "paddingTop": "12px",
                                                          "paddingBottom": "12px"], text: "Go")
        let (b, _, _) = HTMLImport.steps(page([button]), payloads: [:], fonts: inter, name: "p")
        #expect(b.contains { params($0)["type"] == "text" && props($0)["textAutoResize"] == "widthAndHeight" })
    }

    @Test func hostileNumbersStayFinite() throws {
        var n = node("p", .nan, .infinity, 1e300, -.infinity, style: [
            "fontWeight": "1e300", "fontSize": "nan", "lineHeight": "infpx", "color": "rgb(1e300, nan, -inf)",
            "backgroundColor": "rgba(1, 2, 3, nan)", "borderTopWidth": "1e300px", "borderTopColor": "rgb(inf, 0, 0)",
            "borderTopLeftRadius": "1e300%", "boxShadow": "rgb(0, 0, 0) 1e300px nanpx infpx 1px", "opacity": "nan",
            "backgroundImage": "linear-gradient(infdeg, rgb(0, 0, 0) nan%, rgb(1, 1, 1) 1e300%)",
        ], text: "x", runs: [DOMRun(start: Int.max, end: Int.min, fontWeight: "-1e300"), DOMRun(start: -5, end: Int.max, color: "rgb(nan, 0, 0)")])
        n.children = [node("div", -1e300, 1e300, .nan, .nan, style: ["display": "flex", "rowGap": "1e300px", "fontWeight": "450.5"])]
        let wrap = node("div", 0, 0, 10, 10, style: ["display": "grid", "gridTemplateColumns": "1e300px infpx"], children: [n])
        let (steps, _, _) = HTMLImport.steps(page([wrap]), payloads: [:], fonts: inter, name: "p")
        _ = try JSONEncoder().encode(steps)
        #expect(!steps.isEmpty)
    }

    @Test func tooLargeRefused() {
        let leaves = (0..<3001).map { node("p", 0, Double($0) * 20, text: "t\($0)") }
        let (steps, warnings, _) = HTMLImport.steps(page(leaves), payloads: [:], fonts: inter, name: "p")
        #expect(steps.isEmpty)
        #expect(warnings.contains("page too large to import (3003 layers; max 3000)"))
    }
}

extension DesignCommandTests {
    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func realEngineAcceptsLandingSteps() async throws {
        let cli = vendorFigcraft.appendingPathComponent("bin/figcraft-cli")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ steps: [JSONValue]) async throws -> [[String: JSONValue]] {
            let script = dir.appendingPathComponent("s.json")
            try JSONEncoder().encode(steps).write(to: script)
            let r = try await BoundedProcess.run(executable: cli, args: ["run", script.path, "--no-system-fonts",
                                                                       "--out", dir.appendingPathComponent("x.figcraft").path],
                                                 in: dir, env: [:], timeout: .seconds(120), cap: 64 << 20)
            #expect(r.status == 0, "\(r.stderr)")
            return r.stdout.split(separator: "\n").compactMap {
                guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) else { return nil }
                return o
            }
        }
        let call = { (c: String, p: [String: JSONValue]) in JSONValue.object(["command": .string(c), "params": .object(p)]) }
        // the FontBook the way the engine lists it
        let families = try await run([call("text.fonts", [:])])
        guard case .array(let names)? = families.first?["result"] else { Issue.record("no fonts"); return }
        let fams = names.compactMap { if case .string(let n) = $0 { n } else { nil } }
        let styles = try await run(fams.map { call("text.fonts", ["family": .string($0)]) })
        var book = FontBook(families: [:])
        for (f, r) in zip(fams, styles) {
            if case .array(let st)? = r["result"] { book.families[f] = st.compactMap { if case .string(let n) = $0 { n } else { nil } } }
        }

        let (s, payloads) = try landingSnapshot()
        let (steps, _, _) = HTMLImport.steps(s, payloads: payloads, fonts: book, name: "Landing")
        // read a shadowed card back: its effect keeps the engine's offset/radius
        let card = try #require(steps.firstIndex { props($0)["effects"] != nil })
        let results = try await run(steps + [call("node.get", ["id": .object(["$step": .number(Double(card))])])])
        #expect(results.count == steps.count + 1)
        if case .object(let got)? = results.last?["result"], case .array(let fx)? = got["effects"], case .object(let e)? = fx.first {
            #expect(e["offset"] == [0, 4] && e["radius"] == 12)
        } else { Issue.record("no effects read back: \(String(describing: results.last))") }
        for (i, r) in results.enumerated() { #expect(r["ok"] == .bool(true), "step \(i): \(r)") }
        // the page holds only the screen: every other layer is under it
        let info = try await BoundedProcess.run(executable: cli, args: ["info", dir.appendingPathComponent("x.figcraft").path, "--json"],
                                                in: dir, env: [:], timeout: .seconds(60))
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(info.stdout.utf8)),
              case .array(let pages)? = o["pages"], case .object(let p)? = pages.first,
              case .number(let nodes)? = p["nodes"], case .number(let top)? = p["topLevel"] else { Issue.record("info: \(info.stdout)"); return }
        #expect(top == 1)
        #expect(nodes - 1 >= 20)
    }
}
