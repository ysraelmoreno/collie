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

    // MARK: coverage fixture

    /// Each probe `<p id=…>` is black (the default) unless; its rule turns it the named color when the media query holds.
    static let fixture = """
    <style>@import url("data:text/css,%23imp%7Bcolor%3Argb(5%2C5%2C5)%7D") (prefers-reduced-motion: reduce);</style>
    <style>
      @media not (prefers-reduced-motion: reduce) { #not { color: rgb(1, 1, 1); } }
      @media screen and (prefers-reduced-motion: reduce) { #and { color: rgb(2, 2, 2); } }
      @supports (display: block) { @media (prefers-reduced-motion: reduce) { #sup { color: rgb(3, 3, 3); } } }
      @layer l { @media (prefers-reduced-motion: reduce) { #layer { color: rgb(4, 4, 4); } } }
    </style>
    <link rel=stylesheet media="(prefers-reduced-motion: reduce)" href="data:text/css,%23cross%7Bcolor%3Argb(6%2C6%2C6)%7D">
    <p id=not>.</p><p id=and>.</p><p id=sup>.</p><p id=layer>.</p><p id=imp>.</p><p id=cross>.</p>
    <p id=late>.</p><p id=adopt>.</p><p id=shadowHost></p>
    <script>
      const sh = document.getElementById('shadowHost').attachShadow({ mode: 'open' });
      sh.innerHTML = '<style>@media (prefers-reduced-motion: reduce) { b { color: rgb(8, 8, 8); } }</style><b id=inShadow>.</b>';
      const sheet = new CSSStyleSheet();
      sheet.replaceSync('@media (prefers-reduced-motion: reduce) { #adopt { color: rgb(9, 9, 9); } }');
      document.adoptedStyleSheets = [sheet];
    </script>
    """
    func color(_ id: String) -> String { "getComputedStyle(document.getElementById('\(id)')).color" }
    func rgb(_ n: Int) -> JSONValue { .string("rgb(\(n), \(n), \(n))") }
    func settle(_ b: BrowserPanel, _ id: String, _ want: JSONValue) async throws -> Bool {
        for _ in 0..<50 {
            if try await js(b, color(id)) == want { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func combosNestedImportAdoptedShadowAndRuntimeSheets() async throws {
        let b = try await browser(); defer { b.close() }
        try await b.load(html: Self.fixture)
        let black = rgb(0)
        // system: originals
        #expect(try await js(b, color("not")) == rgb(1))
        #expect(try await js(b, color("and")) == black)
        let r = try await emulate(b, ["reduced-motion": .string("reduce")])
        #expect(try await js(b, color("not")) == black)          // `not (...)` flips
        for (id, n) in [("and", 2), ("sup", 3), ("layer", 4), ("adopt", 9)] { #expect(try await js(b, color(id)) == rgb(n), "\(id)") }
        #expect(try await js(b, "getComputedStyle(document.getElementById('shadowHost').shadowRoot.getElementById('inShadow')).color") == rgb(8))
        #expect(try await settle(b, "imp", rgb(5)))             // @import ... media
        #expect(try await settle(b, "cross", rgb(6)))           // link media attribute (sheet itself unreadable)
        let settled = try await emulate(b, [:])   // all sheets loaded by now
        // the opaque-origin data: <link> is unreadable: reported, though its media attribute was still rewritten
        if case .number(let n)? = settled["uncoveredSheets"] { #expect(n >= 1 && n <= 2) } else { Issue.record("no uncoveredSheets") }
        #expect(settled["uncoveredShadowRoots"] == .number(0))
        _ = r
        // a sheet added after the emulation
        _ = try await js(b, "document.head.insertAdjacentHTML('beforeend', '<style>@media (prefers-reduced-motion: reduce) { #late { color: rgb(7, 7, 7); } }</style>'); 1")
        #expect(try await settle(b, "late", rgb(7)))
        // idempotent
        _ = try await emulate(b, ["reduced-motion": .string("reduce")])
        for (id, n) in [("and", 2), ("sup", 3), ("late", 7), ("adopt", 9)] { #expect(try await js(b, color(id)) == rgb(n), "\(id) again") }
        // no-preference: the opposite
        _ = try await emulate(b, ["reduced-motion": .string("no-preference")])
        #expect(try await js(b, color("not")) == rgb(1))
        #expect(try await js(b, color("and")) == black)
        // system restores every original
        _ = try await emulate(b, ["reduced-motion": .string("system")])
        #expect(try await js(b, color("not")) == rgb(1))
        for id in ["and", "sup", "layer", "adopt", "late", "imp", "cross"] { #expect(try await js(b, color(id)) == black, "\(id) restored") }
    }

    @Test func unreadableSheetsAndClosedShadowRootsAreCounted() async throws {
        let b = try await browser(); defer { b.close() }
        _ = try await emulate(b, ["reduced-motion": .string("reduce")])   // before the load: attachShadow is seen
        try await b.load(html: """
        <style id=x>p{color:red}</style><p>x</p><div id=h></div>
        <script>
        // simulates a cross-origin sheet: reading its rules throws SecurityError
        const real = Object.getOwnPropertyDescriptor(CSSStyleSheet.prototype, 'cssRules').get;
        Object.defineProperty(CSSStyleSheet.prototype, 'cssRules', { get() {
          if (this.ownerNode && this.ownerNode.id === 'x') throw new DOMException('blocked', 'SecurityError');
          return real.call(this);
        } });
        document.getElementById('h').attachShadow({ mode: 'closed' })</script>
        """)
                var r: [String: JSONValue] = [:]
        for _ in 0..<50 {
            r = try await emulate(b, [:])
            if r["uncoveredSheets"] != .number(0) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(r["uncoveredSheets"] != .number(0))
        #expect(r["uncoveredShadowRoots"] == .number(1))
    }

    /// Emulation already on when the page creates its shadow root / adopts a sheet: the wrapper and setter paths.
    @Test func emulationBeforeShadowRootAndAdoptedSheet() async throws {
        let b = try await browser(); defer { b.close() }
        _ = try await emulate(b, ["reduced-motion": .string("reduce")])
        try await b.load(html: """
        <p id=adopt>.</p><div id=h></div>
        <script>
          const sh = document.getElementById('h').attachShadow({ mode: 'open' });
          sh.innerHTML = '<b id=s>.</b>';
          const sty = document.createElement('style');   // a sheet added to the root after it exists
          sty.textContent = '@media (prefers-reduced-motion: reduce) { b { color: rgb(8, 8, 8); } }';
          sh.appendChild(sty);
          const sheet = new CSSStyleSheet();
          sheet.replaceSync('@media (prefers-reduced-motion: reduce) { #adopt { color: rgb(9, 9, 9); } }');
          document.adoptedStyleSheets = [sheet];
        </script>
        """)
        let inShadow = "getComputedStyle(document.getElementById('h').shadowRoot.getElementById('s')).color"
        var ok = false
        for _ in 0..<50 {
            if try await js(b, inShadow) == rgb(8), try await js(b, color("adopt")) == rgb(9) { ok = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ok)
        _ = try await emulate(b, ["reduced-motion": .string("system")])
        #expect(try await js(b, inShadow) == rgb(0))
        #expect(try await js(b, color("adopt")) == rgb(0))
    }
}
