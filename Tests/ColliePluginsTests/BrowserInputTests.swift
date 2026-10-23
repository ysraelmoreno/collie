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
        let b: BrowserPanel, window: NSWindow
        init(_ b: BrowserPanel, _ w: NSWindow) { self.b = b; window = w }
        func close() { b.close(); window.close() }
    }

    func browser(_ html: String, slot: CGSize = CGSize(width: 600, height: 400), window: Bool = true) async throws -> Hosted {
        _ = NSApplication.shared
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

    @Test func tabMovesFocusVisible() async throws {
        let h = try await browser(Self.tabbables); defer { h.close() }
        for _ in 0..<3 { #expect(try await run(h.b, "key", ["key": .string("Tab")])["trusted"] == .bool(true)) }
        #expect(try await eval(h.b, focused) == .string("three/three"))
    }

    @Test func shiftTabBack() async throws {
        let h = try await browser(Self.tabbables); defer { h.close() }
        for _ in 0..<3 { _ = try await run(h.b, "key", ["key": .string("Tab")]) }
        _ = try await run(h.b, "key", ["key": .string("Shift+Tab")])
        #expect(try await eval(h.b, focused) == .string("two/two"))
    }

    @Test func hoverAppliesHoverStyle() async throws {
        let h = try await browser("""
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

    @Test func clickIsTrusted() async throws {
        let h = try await browser("""
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

    @Test func typeInsertsText() async throws {
        let h = try await browser("""
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

    @Test func enterSubmitsForm() async throws {
        let h = try await browser(#"<form onsubmit="event.preventDefault(); window.sent = this.q.value"><input name="q" aria-label="Q"></form>"#)
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
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!)
        #expect(leaks.keys == ["q"])
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
        #expect(await pollUntil { (try? await eval(h.b, "n.selectionStart + ',' + n.selectionEnd")) == .string("0,3") })
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
