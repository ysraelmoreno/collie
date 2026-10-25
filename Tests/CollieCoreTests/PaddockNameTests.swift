import Testing
import CollieCore

struct PaddockNameTests {
    @Test func slugs() {
        #expect(PaddockName.slug("ShowOn") == "showon")
        #expect(PaddockName.slug("Meu Cercado_2") == "meu-cercado-2")
        #expect(PaddockName.slug("  ação!! ") == "acao")
        #expect(PaddockName.slug("--a--b--") == "a-b")
        #expect(PaddockName.slug("!!!") == nil)
        #expect(PaddockName.slug(String(repeating: "x", count: 50))?.count == 40)
        #expect(PaddockName.slug(String(repeating: "a", count: 39) + " b") == String(repeating: "a", count: 39))   // no trailing dash
    }
}
