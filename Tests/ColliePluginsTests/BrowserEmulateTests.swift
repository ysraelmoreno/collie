import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// `browser.emulate`: color scheme (web view appearance) and reduced motion (user script). Local HTML only.
@MainActor @Suite(.serialized) struct BrowserEmulateTests {
    func browser() async throws -> BrowserPanel {
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight, state: [:])
        return BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory,
                                                                 workspaceId: nil, call: { _, _ in .null }) { _, _ in })
    }

    func emulate(_ b: BrowserPanel, _ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard case .object(let o) = try await b.handle("browser.emulate", args) else { return [:] }
        return o
    }

    func js(_ b: BrowserPanel, _ code: String) async throws -> JSONValue? {
        guard case .object(let o) = try await b.handle("browser.eval", ["js": .string(code)]) else { return nil }
        return o["value"]
    }

    static let page = """
    <style>
      body { background: rgb(1, 2, 3); }
      @media (prefers-color-scheme: dark) { body { background: rgb(10, 20, 30); } }
      @media (prefers-reduced-motion: reduce) { body { color: rgb(9, 9, 9); } }
    </style><p>x</p>
    """
    let bg = "getComputedStyle(document.body).backgroundColor"
    let fg = "getComputedStyle(document.body).color"
    let dark = "matchMedia('(prefers-color-scheme: dark)').matches"
    let reduce = "matchMedia('(prefers-reduced-motion: reduce)').matches"

    @Test func colorSchemeDark() async throws {
        let b = try await browser(); defer { b.close() }
        try await b.load(html: Self.page)
        let r = try await emulate(b, ["color-scheme": .string("dark")])
        #expect(r["colorScheme"] == .string("dark"))
        #expect(try await js(b, dark) == .bool(true))
        #expect(try await js(b, bg) == .string("rgb(10, 20, 30)"))
        _ = try await emulate(b, ["color-scheme": .string("light")])
        #expect(try await js(b, dark) == .bool(false))
        #expect(try await js(b, bg) == .string("rgb(1, 2, 3)"))
    }

    @Test func colorSchemeSystemResets() async throws {
        let b = try await browser(); defer { b.close() }
        try await b.load(html: Self.page)
        let before = try await js(b, dark)
        _ = try await emulate(b, ["color-scheme": .string("dark")])
        let r = try await emulate(b, ["color-scheme": .string("system")])
        #expect(r["colorScheme"] == .string("system"))
        #expect(b.webView?.appearance == nil)
        #expect(try await js(b, dark) == before)
    }

    @Test func reducedMotionMatchMedia() async throws {
        let b = try await browser(); defer { b.close() }
        try await b.load(html: Self.page)
        #expect(try await js(b, reduce) == .bool(false))
        let r = try await emulate(b, ["reduced-motion": .string("reduce")])
        #expect(r["reducedMotion"] == .string("reduce"))
        #expect(try await js(b, reduce) == .bool(true))
        #expect(try await js(b, "matchMedia('(prefers-reduced-motion: no-preference)').matches") == .bool(false))
        _ = try await emulate(b, ["reduced-motion": .string("no-preference")])
        #expect(try await js(b, reduce) == .bool(false))
        #expect(try await js(b, "matchMedia('(prefers-reduced-motion: no-preference)').matches") == .bool(true))
    }

    @Test func reducedMotionCSSRule() async throws {
        let b = try await browser(); defer { b.close() }
        try await b.load(html: Self.page)
        _ = try await emulate(b, ["reduced-motion": .string("reduce")])
        #expect(try await js(b, fg) == .string("rgb(9, 9, 9)"))
        let r = try await emulate(b, ["reduced-motion": .string("system")])
        #expect(r["reducedMotion"] == .string("system"))
        #expect(try await js(b, fg) != .string("rgb(9, 9, 9)"))
        #expect(try await js(b, reduce) == .bool(false))
    }

    @Test func survivesNavigation() async throws {
        let b = try await browser(); defer { b.close() }
        _ = try await emulate(b, ["color-scheme": .string("dark"), "reduced-motion": .string("reduce")])
        try await b.load(html: Self.page)   // a navigation after the emulation: the user script runs from the start
        #expect(try await js(b, reduce) == .bool(true))
        #expect(try await js(b, fg) == .string("rgb(9, 9, 9)"))
        #expect(try await js(b, dark) == .bool(true))
        try await b.load(html: Self.page + "<link media='(prefers-reduced-motion: reduce)' rel=stylesheet href='data:text/css,p{color:rgb(7,7,7)}'>")
        #expect(try await js(b, fg) == .string("rgb(9, 9, 9)"))
        let r = try await emulate(b, [:])
        #expect(r["reducedMotion"] == .string("reduce") && r["colorScheme"] == .string("dark"))
    }

    @Test func invalidValueNamesFlag() async throws {
        let b = try await browser(); defer { b.close() }
        do { _ = try await emulate(b, ["color-scheme": .string("sepia")]); Issue.record("expected invalidArgs") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains("--color-scheme")) }
    }
}
