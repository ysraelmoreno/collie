import Foundation
import Testing
import CollieTheme

private let example = """
{
  "name": "Tinta",
  "extends": "dark",
  "colors": {
    "background": "#15171C",
    "surface": "#1F232B",
    "accent": "#6E9BFF"
  }
}
"""

private func failure(_ json: String) -> String? {
    do { _ = try ThemeFile.parse(Data(json.utf8)); return nil } catch { return error.message }
}

@Test func parsesDesignExample() throws {
    let t = try ThemeFile.parse(Data(example.utf8))
    #expect(t.name == "Tinta")
    #expect(t.extends == .dark)
    #expect(t.colors.count == 3)
    #expect(t.colors["accent"] == RGB(hex: 0x6E9BFF))
}

@Test func rgbHexString() throws {
    #expect(RGB(hexString: "#6e9bff") == RGB(hex: 0x6E9BFF))
    #expect(RGB(hexString: "#6E9BFF") == RGB(hex: 0x6E9BFF))
    #expect(RGB(hex: 0x6E9BFF).hexString == "#6E9BFF")
    #expect(RGB(hex: 0x00000A).hexString == "#00000A")
    for bad in ["6E9BFF", "#6E9BF", "#6E9BFFF", "#GGGGGG", "#+12345", ""] { #expect(RGB(hexString: bad) == nil) }
}

@Test func reportsEachError() {
    #expect(failure("nope") == "JSON inválido")
    #expect(failure("[1]") == "JSON inválido")
    #expect(failure(#"{"extends":"dark"}"#) == #"falta "name""#)
    #expect(failure(#"{"name":"A"}"#) == #"falta "extends""#)
    #expect(failure(#"{"name":"","extends":"dark"}"#) == #""name": use de 1 a 48 caracteres, sem controle"#)
    #expect(failure(#"{"name":"a\nb","extends":"dark"}"#) == #""name": use de 1 a 48 caracteres, sem controle"#)
    #expect(failure(#"{"name":"A","extends":"blue"}"#) == #""extends": use "dark" ou "light""#)
    #expect(failure(#"{"name":"A","extends":"dark","colors":{"fundo":"#000000"}}"#) == #"papel desconhecido: "fundo""#)
    #expect(failure(#"{"name":"A","extends":"dark","colors":{"accent":"red"}}"#) == #""accent": use #RRGGBB"#)
    #expect(failure(#"{"name":"A","extends":"dark","colors":{"accent":5}}"#) == #""accent": use #RRGGBB"#)
    #expect(failure(#"{"name":"A","extends":"dark","colors":[]}"#) == #""colors": use um objeto"#)
}

@Test func nameLimits() {
    #expect(failure(#"{"name":"\#(String(repeating: "a", count: 48))","extends":"dark"}"#) == nil)
    #expect(failure(#"{"name":"\#(String(repeating: "a", count: 49))","extends":"dark"}"#) != nil)
}

@Test func ignoresUnknownTopLevelAndTerminal() throws {
    let t = try ThemeFile.parse(Data(#"{"name":"A","extends":"light","terminal":{"x":1},"futuro":true}"#.utf8))
    #expect(t.colors.isEmpty)
}

@Test func refusesOver64KiB() {
    #expect(failure(String(repeating: " ", count: 64 * 1024 + 1)) == "arquivo grande demais")
}

@Test func roundTripAndKeyOrder() throws {
    let t = try ThemeFile.parse(Data(example.utf8))
    #expect(try ThemeFile.parse(t.data) == t)
    #expect(String(decoding: t.data, as: UTF8.self) == example + "\n")
    let empty = ThemeFile(name: "Vazio", extends: .light)
    #expect(try ThemeFile.parse(empty.data) == empty)
}

@Test func paletteInheritsFromBase() throws {
    let dark = try ThemeFile.parse(Data(example.utf8)).palette
    #expect(dark.background == RGB(hex: 0x15171C))
    #expect(dark.text == Palette.dark.text)
    let light = ThemeFile(name: "L", extends: .light, colors: ["accent": RGB(hex: 0x112233)]).palette
    #expect(light.accent == RGB(hex: 0x112233))
    #expect(light.background == Palette.light.background)
}

@Test func validIds() {
    for ok in ["tinta", "meu-tema-2", "0", String(repeating: "a", count: 48)] { #expect(ThemeFile.validId(ok)) }
    for bad in ["", "Tinta", "../x", "-a", "a b", String(repeating: "a", count: 49)] { #expect(!ThemeFile.validId(bad)) }
}

@Test func readingsFlagLowContrast() throws {
    let t = ThemeFile(name: "M", extends: .dark, colors: ["muted": Palette.dark.surface])
    let r = t.readings
    #expect(r.count == 8)
    let muted = try #require(r.first { $0.role == "muted" })
    #expect(muted.low)
    #expect(abs(muted.ratio - 1) < 0.001)
    let text = try #require(r.first { $0.role == "text" })
    #expect(!text.low)
}
