import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// Trusted keyboard and mouse input: the page hosted headless in a `BrowserInput.HostWindow` (local HTML only).
@MainActor @Suite(.serialized) struct BrowserInputTests {
    @MainActor final class Hosted {
        let b: BrowserPanel, window: NSWindow, done: () -> Void
        init(_ b: BrowserPanel, _ w: NSWindow, done: @escaping () -> Void = {}) { self.b = b; window = w; self.done = done }
        func close() { b.close(); window.close(); done() }
    }

    /// `headless`: hosted the way production hosts a headless panel (`PanelViewStore`), not in a slot-sized window.
    func browser(headless: Bool = false, _ html: String, slot: CGSize = CGSize(width: 600, height: 400), window: Bool = true) async throws -> Hosted {
        _ = NSApplication.shared
        if headless {
            PluginViews.register("browser", BrowserPanel.self)
            let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .headless, state: [:])
            let store = PanelViewStore(panels: { [panel] }) {
                PanelHostContext(panel: $0, root: FileManager.default.temporaryDirectory, workspaceId: nil, call: { _, _ in .null }, emit: { _, _ in })
            }
            let b = try #require(store.instance(for: panel.id) as? BrowserPanel)
            let w = try #require(b.webView?.window)
            try await b.load(html: html)
            return Hosted(b, w) { store.closeAll() }
        }
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight, state: [:])
        let b = BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory,
                                                                  workspaceId: nil, call: { _, _ in .null }) { _, _ in })
        let w = BrowserInput.HostWindow(contentRect: CGRect(x: -10000, y: -10000, width: slot.width, height: slot.height),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        if window {
            b.container.frame = CGRect(origin: .zero, size: slot)
            w.contentView?.addSubview(b.container)
            w.contentView?.layoutSubtreeIfNeeded()
        }
        try await b.load(html: html)
        return Hosted(b, w)
    }

    func run(_ b: BrowserPanel, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        guard case .object(let o) = try await b.handle("browser.\(cmd)", args) else { Issue.record("not an object"); return [:] }
        return o
    }

    func eval(_ b: BrowserPanel, _ js: String) async throws -> JSONValue? { try await run(b, "eval", ["js": .string(js)])["value"] }

    func ref(_ b: BrowserPanel, _ needle: String) async throws -> String {
        guard case .string(let s)? = try await run(b, "snapshot")["output"],
              let line = s.split(separator: "\n").first(where: { $0.contains(needle) }),
              let r = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else { throw ProtocolError(code: .notFound, message: needle) }
        return String(line[r].dropFirst(5).dropLast())
    }

    static let tabbables = """
        <style>:focus-visible { outline: 3px solid rgb(0, 200, 0) }</style>
        <input id="one" aria-label="One"><button id="two">Two</button><a id="three" href="#x">Three</a><button id="four">Four</button>
        """
    let focused = "document.activeElement.id + '/' + (document.querySelector(':focus-visible') || {}).id"
    // ponytail: in a window, R8 gives first responder back after each command: the page keeps `activeElement` but is
    // unfocused, so `:focus-visible` no longer matches; checked headless only

    @Test(arguments: [false, true]) func tabMovesFocusVisible(headless: Bool) async throws {
        let h = try await browser(headless: headless, Self.tabbables); defer { h.close() }
        for _ in 0..<3 { #expect(try await run(h.b, "key", ["key": .string("Tab")])["trusted"] == .bool(true)) }
        #expect(try await eval(h.b, headless ? focused : "document.activeElement.id") == .string(headless ? "three/three" : "three"))
    }

    @Test(arguments: [false, true]) func shiftTabBack(headless: Bool) async throws {
        let h = try await browser(headless: headless, Self.tabbables); defer { h.close() }
        for _ in 0..<3 { _ = try await run(h.b, "key", ["key": .string("Tab")]) }
        _ = try await run(h.b, "key", ["key": .string("Shift+Tab")])
        #expect(try await eval(h.b, headless ? focused : "document.activeElement.id") == .string(headless ? "two/two" : "two"))
    }

    @Test(arguments: [false, true]) func hoverAppliesHoverStyle(headless: Bool) async throws {
        let h = try await browser(headless: headless, """
            <style>#t { width: 100px; height: 40px } #t:hover { color: rgb(255, 0, 0) }</style>
            <script>window.moves = []; addEventListener('mousemove', e => moves.push(e.isTrusted))</script>
            <p>x</p><button id="t">Target</button>
            """)
        defer { h.close() }
        #expect(try await eval(h.b, "getComputedStyle(t).color") != .string("rgb(255, 0, 0)"))
        let r = try await run(h.b, "hover", ["ref": .string(try await ref(h.b, "Target"))])
        #expect(r["trusted"] == .bool(true))
        #expect(try await eval(h.b, "getComputedStyle(t).color") == .string("rgb(255, 0, 0)"))
        #expect(try await eval(h.b, "moves.length > 0 && moves.every(x => x)") == .bool(true))
    }

    /// Final review I1: once the page has focus (Tab, a click into a field, a page `focus()`), the web view is the host
    /// window's first responder and WebKit drops moves outside its `visibleRect`: the headless host must be big.
    @Test(arguments: ["tab", "click", "js"]) func headlessHoverAfterFocus(focus: String) async throws {
        let h = try await browser(headless: true, """
            <style>#t { width: 100px; height: 40px } #t:hover { color: rgb(255, 0, 0) }</style>
            <input aria-label="Field"><button id="o">Other</button><button id="t">Target</button>
            """)
        defer { h.close() }
        switch focus {
        case "tab": _ = try await run(h.b, "key", ["key": .string("Tab")])
        case "click": _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Field"))])
        default: _ = try await eval(h.b, "document.querySelector('input').focus()")
        }
        _ = try await run(h.b, "hover", ["ref": .string(try await ref(h.b, "Other"))])
        #expect(try await run(h.b, "hover", ["ref": .string(try await ref(h.b, "Target"))])["settled"] == .bool(true))
        #expect(try await eval(h.b, "getComputedStyle(t).color") == .string("rgb(255, 0, 0)"))
        #expect(try await eval(h.b, "innerWidth") == .number(1280))   // the big host never becomes the viewport
    }

    /// Ruling R8: agent input on a visible panel never takes the user's keyboard focus (their terminal keeps it), and
    /// the page keeps its own focus.
    @Test(arguments: ["tab", "click", "fill", "eval"]) func visiblePanelGivesFocusBack(path: String) async throws {
        _ = NSApplication.shared
        let panel = Panel(id: UUID(), name: "v", pluginId: "browser", placement: .canvas, state: [:])
        let b = BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory,
                                                                  workspaceId: nil, call: { _, _ in .null }) { _, _ in })
        let w = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { b.close(); w.close() }
        let terminal = NSTextView(frame: CGRect(x: 610, y: 0, width: 280, height: 400))
        b.container.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        w.contentView?.addSubview(b.container); w.contentView?.addSubview(terminal)
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(w.makeFirstResponder(terminal))
        try await b.load(html: #"<input id="one" aria-label="One"><button id="two">Two</button>"#)
        switch path {
        case "tab": _ = try await run(b, "key", ["key": .string("Tab")])
        case "click": _ = try await run(b, "click", ["ref": .string(try await ref(b, "One"))])
        case "fill": _ = try await run(b, "fill", ["ref": .string(try await ref(b, "One")), "text": .string("x")])
        default: _ = try await eval(b, "one.focus()")
        }
        try await Task.sleep(for: .milliseconds(50))   // past the late re-check
        #expect(w.firstResponder === terminal)
        #expect(try await eval(b, "document.activeElement.id") == .string("one"))
        // keys still edit the page's field (the web view holds first responder only while they settle); its caret
        // survives, though WebKit reports `selectionStart` 0 while the page is unfocused
        _ = try await run(b, "type", ["text": .string("q")])
        #expect(try await eval(b, "one.value") == .string(path == "fill" ? "xq" : "q"))
        _ = try await run(b, "key", ["key": .string("Meta+a")])
        _ = try await run(b, "type", ["text": .string("Z")])
        #expect(try await eval(b, "one.value") == .string("Z"))
        #expect(terminal.string.isEmpty)
        #expect(w.firstResponder === terminal)
    }

    @Test(arguments: [false, true]) func clickIsTrusted(headless: Bool) async throws {
        let h = try await browser(headless: headless, """
            <script>window.seen = []</script>
            <button onclick="seen.push(event.isTrusted)" onmousedown="seen.push('down')">Go</button>
            """)
        defer { h.close() }
        let r = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Go"))])
        #expect(r["trusted"] == .bool(true))
        #expect(try await eval(h.b, "seen") == .array([.string("down"), .bool(true)]))
    }

    /// Review Focus 2: a 360-wide page shown at 0.5 in a 600×400 slot; the click lands on the ref, below the fold too.
    @Test func clickScaledViewport() async throws {
        let h = try await browser("""
            <style>body { margin: 0 } button { position: absolute; width: 60px; height: 30px }</style>
            <script>window.hits = []</script>
            <button style="left: 10px; top: 10px" onclick="hits.push('a')">A</button>
            <button style="left: 290px; top: 700px" onclick="hits.push('b')">B</button>
            <button style="left: 150px; top: 1500px" onclick="hits.push('c')">C</button>
            """)
        defer { h.close() }
        let size = try await run(h.b, "resize", ["width": .number(360), "height": .number(800)])
        #expect(size["scale"] == .number(0.5))
        #expect(h.b.container.page.frame == CGRect(x: 210, y: 0, width: 180, height: 400))
        // the mapping itself: CSS (20, 30) → container point page.origin + (20, 30) * 0.5
        let web = try #require(h.b.webView)
        let p = BrowserInput.windowPoint(web, CGPoint(x: 20, y: 30))
        #expect(h.b.container.convert(p, from: nil) == CGPoint(x: 220, y: 15))
        for name in ["B", "A", "C"] { _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, name))]) }
        #expect(try await eval(h.b, "hits") == .array([.string("b"), .string("a"), .string("c")]))
    }

    @Test(arguments: [false, true]) func typeInsertsText(headless: Bool) async throws {
        let h = try await browser(headless: headless, """
            <script>window.keys = []; addEventListener('keydown', e => keys.push(e.isTrusted))</script>
            <input aria-label="Name" id="n">
            """)
        defer { h.close() }
        _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Name"))])
        #expect(try await run(h.b, "type", ["text": .string("héllo wörld")])["trusted"] == .bool(true))
        #expect(try await eval(h.b, "n.value") == .string("héllo wörld"))
        _ = try await run(h.b, "key", ["key": .string("Backspace")])
        #expect(try await eval(h.b, "n.value") == .string("héllo wörl"))
        #expect(try await eval(h.b, "keys.length == 12 && keys.every(x => x)") == .bool(true))
    }

    @Test(arguments: [false, true]) func enterSubmitsForm(headless: Bool) async throws {
        let h = try await browser(headless: headless, #"<form onsubmit="event.preventDefault(); window.sent = this.q.value"><input name="q" aria-label="Q"></form>"#)
        defer { h.close() }
        _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Q"))])
        _ = try await run(h.b, "type", ["text": .string("ab")])
        _ = try await run(h.b, "key", ["key": .string("Enter")])
        #expect(try await eval(h.b, "window.sent") == .string("ab"))
    }

    /// A key the page doesn't handle comes back to NSApp.sendEvent; it must not reach the app's key window.
    @Test func unhandledKeyIsDropped() async throws {
        let h = try await browser("<p>nothing editable</p>"); defer { h.close() }
        let before = BrowserInput.dropped
        _ = try await run(h.b, "key", ["key": .string("x")])
        #expect(await pollUntil { BrowserInput.dropped > before })
    }

    /// Records keyDowns other local monitors see. AppKit calls monitors in no fixed order (both seen), so one may see
    /// our re-send before ours drops it; what matters is that ours drops it before the key window: every keyDown
    /// seen here must be either sentinel-stamped (ours returns nil for it) or not ours.
    @MainActor final class Leaks {
        var seen: [(String, TimeInterval)] = []
        var keys: [String] { seen.filter { $0.1 != BrowserInput.sentinel }.map(\.0) }   // what ours lets through
        private var m: Any?
        init() {
            m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
                let c = e.characters ?? "", t = e.timestamp
                MainActor.assumeIsolated { self?.seen.append((c, t)) }
                return e
            }
        }
        func stop() { if let m { NSEvent.removeMonitor(m) }; m = nil }
    }

    static let stalls = "<script>addEventListener('keydown', e => { const t = Date.now(); while (Date.now() - t < 1500); })</script><p>x</p>"

    /// C2: a command that timed out on a busy page, then another one: every late re-send is still dropped.
    @Test func stalledPageNeverLeaks() async throws {
        let h = try await browser(Self.stalls); defer { h.close() }
        _ = try await run(h.b, "key", ["key": .string("Escape")])   // monitors in order: ours first
        let leaks = Leaks(); defer { leaks.stop() }
        let before = BrowserInput.dropped
        #expect(try await run(h.b, "key", ["key": .string("x")])["settled"] == .bool(false))
        _ = try await run(h.b, "type", ["text": .string("y")])
        #expect(await pollUntil(10) { BrowserInput.dropped >= before + 2 })   // x and y came back unhandled, stamped, dropped
        try await Task.sleep(for: .milliseconds(500))
        #expect(leaks.keys.isEmpty)
    }

    /// I2: typing into a focused iframe (keyups don't reach the top window: never settles) is never refused and never leaks.
    @Test func iframeTypingNeverRefusedNorLeaks() async throws {
        let h = try await browser(#"<iframe srcdoc="<input id=i>" style="width:300px;height:80px"></iframe>"#); defer { h.close() }
        _ = try await run(h.b, "key", ["key": .string("Escape")])
        let leaks = Leaks(); defer { leaks.stop() }
        _ = try await eval(h.b, "new Promise(r => { const f = document.querySelector('iframe'); const go = () => { f.contentDocument.getElementById('i').focus(); r(1) }; f.contentDocument.readyState === 'complete' ? go() : f.onload = go })")
        for _ in 0..<3 { _ = try await run(h.b, "type", ["text": .string(String(repeating: "a", count: 100))]) }
        #expect(await pollUntil(10) { (try? await eval(h.b, "document.querySelector('iframe').contentDocument.getElementById('i').value.length")) == .number(300) })
        #expect(leaks.keys.isEmpty)
    }

    /// The monitor drops only our sentinel-stamped events: a real key event passes.
    @Test func realKeyEventsPassTheMonitor() async throws {
        let h = try await browser("<p>x</p>"); defer { h.close() }
        _ = try await run(h.b, "key", ["key": .string("Escape")])
        let leaks = Leaks(); defer { leaks.stop() }
        let before = BrowserInput.dropped
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!)
        #expect(leaks.keys == ["q"])
        #expect(BrowserInput.dropped == before)
        #expect(BrowserInput.sentinel < ProcessInfo.processInfo.systemUptime / 1000)
    }

    @Test func typeOver1024IsRefused() async throws {
        let h = try await browser("<input>"); defer { h.close() }
        do { _ = try await run(h.b, "type", ["text": .string(String(repeating: "a", count: 1025))]); Issue.record("expected invalidArgs") }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains("--text")) }
    }

    @Test func metaASelectsAllAndClipboardIsRefused() async throws {
        let h = try await browser(#"<input aria-label="Name" id="n">"#); defer { h.close() }
        _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Name"))])
        _ = try await run(h.b, "type", ["text": .string("abc")])
        let r = try await run(h.b, "key", ["key": .string("Meta+a")])
        #expect(r["settled"] == .bool(true))
        // typed over: the selection is all (R8 gives first responder back, and WebKit reports `selectionStart` 0 then)
        _ = try await run(h.b, "type", ["text": .string("Z")])
        #expect(await pollUntil { (try? await eval(h.b, "n.value")) == .string("Z") })
        for k in ["Meta+c", "Meta+x", "Meta+V"] {
            do { _ = try await run(h.b, "key", ["key": .string(k)]); Issue.record("expected invalidArgs for \(k)") }
            catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message.contains(k)) }
        }
    }

    @Test func replyTellsWhetherInputSettled() async throws {
        let h = try await browser("<input aria-label='In'>"); defer { h.close() }
        _ = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "In"))])
        #expect(try await run(h.b, "type", ["text": .string(String(repeating: "a", count: 200))])["settled"] == .bool(true))
        #expect(try await eval(h.b, "document.querySelector('input').value.length") == .number(200))
    }

    @Test func noWindowFallsBackToScript() async throws {
        let h = try await browser("<script>window.n = 0</script><button onclick=\"n++\">Inc</button>", window: false); defer { h.close() }
        let r = try await run(h.b, "click", ["ref": .string(try await ref(h.b, "Inc"))])
        #expect(r["trusted"] == .bool(false))
        #expect(try await eval(h.b, "n") == .number(1))
        #expect(try await run(h.b, "hover", ["ref": .string(try await ref(h.b, "Inc"))])["trusted"] == .bool(false))
    }

    @Test func keySpecs() throws {
        #expect(try BrowserInput.parse("Shift+Tab") == BrowserInput.Key(name: "Tab", chars: "\t", code: 48, mods: .shift))
        #expect(try BrowserInput.parse("meta+a") == BrowserInput.Key(name: "a", chars: "a", code: 0, mods: .command))
        #expect(try BrowserInput.parse("escape").name == "Escape")
        #expect(try BrowserInput.parse("Ctrl++") == BrowserInput.Key(name: "+", chars: "+", code: 0, mods: .control))
        #expect(try BrowserInput.parse("ArrowDown").mods.contains(.function))
        for bad in ["Foo", "Hyper+a", ""] {
            do { _ = try BrowserInput.parse(bad); Issue.record("expected invalidArgs for \(bad)") }
            catch { #expect(error.code == .invalidArgs) }
        }
    }
}
