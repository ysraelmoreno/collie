import Foundation
import Testing
@testable import CollieTerminal

@Suite struct PromptInjectorTests {
    @Test func sanitizesPasteTerminator() {
        #expect(PromptInjector.sanitize("a\u{1B}[201~b\u{03}c\nd ✓") == "ab" + "c\nd ✓")
    }

    @Test func payloadWrapsBracketedPaste() {
        #expect(PromptInjector.payload("hi", raw: false) == Data("\u{1B}[200~hi\u{1B}[201~\r".utf8))
        #expect(PromptInjector.payload("x\\n", raw: true) == Data("x\n".utf8))
        #expect(PromptInjector.payload("\\t\\e\\x41\\\\\\q", raw: true) == Data("\t\u{1B}A\\\\q".utf8))
    }
}

@Suite struct PromptInjectorBracketedTests {
    @Test func plainPayloadWhenBracketedPasteDisabled() {
        #expect(PromptInjector.payload("a\u{1B}[201~b", raw: false, bracketed: false) == Data("ab\r".utf8))
        #expect(PromptInjector.payload("hi", raw: false, bracketed: true) == Data("\u{1B}[200~hi\u{1B}[201~\r".utf8))
    }
}
