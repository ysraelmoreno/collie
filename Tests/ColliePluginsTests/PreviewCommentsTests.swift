import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// What the fake daemon answered and was asked.
final class PreviewFakeDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String: JSONValue])] = []
    private var _list: [JSONValue] = []
    var calls: [(String, [String: JSONValue])] { lock.withLock { _calls } }
    var list: [JSONValue] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    func call(_ c: String, _ a: [String: JSONValue]) -> JSONValue {
        lock.withLock { _calls.append((c, a)) }
        switch c {
        case "comment.list": return .array(list)
        case "artifact.get": return .object(["url": .string("collie-artifact://app/x/source.html")])
        default: return .object([:])
        }
    }
}

private func comment(_ id: String, selector: String?, x: Double, y: Double, resolved: Bool = false, to: String? = "t1",
                     undeliverable: Bool = false, body: String = "deixe maior") -> JSONValue {
    var anchor: [String: JSONValue] = ["x": .number(x), "y": .number(y), "text": .string("Oi")]
    if let selector { anchor["selector"] = .string(selector) }
    return .object(["id": .string(id), "short": .string(String(id.prefix(8))), "title": .string("T"), "anchor": .object(anchor),
                    "to": to.map(JSONValue.string) ?? .null, "toName": .string("A"), "undeliverable": .bool(undeliverable),
                    "resolved": .bool(resolved),
                    "messages": .array([.object(["id": .string("m1"), "byTerminal": .null, "byName": .string("você"),
                                                 "body": .string(body), "at": .string("2026-10-25T10:00:00Z")])])])
}

@MainActor @Suite(.serialized) struct PreviewCommentsTests {
    func project(_ html: String) throws -> URL {
        let u = DiagramFile.real(FileManager.default.temporaryDirectory.appendingPathComponent("preview-cm-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: u.appendingPathComponent("p.html"), options: .atomic)
        return u
    }
    func mount(root: URL, state extra: [String: JSONValue] = ["file": .string("p.html")], daemon: PreviewFakeDaemon) -> (PreviewPanel, NSWindow) {
        var state: [String: JSONValue] = ["root": .string(root.path)]
        state.merge(extra) { _, b in b }
        let p = Panel(id: UUID(), name: "Prévia", pluginId: "preview", placement: .canvas, state: state)
        let host = PanelHostContext(panel: p, root: root, workspaceId: nil, call: { c, a throws(ProtocolError) in daemon.call(c, a) }, emit: { _, _ in })
        let panel = PreviewPanel(panel: p, host: host)
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        panel.view.frame = w.contentView!.bounds
        w.contentView!.addSubview(panel.view)
        return (panel, w)
    }
    func page(_ panel: PreviewPanel, _ expr: String) async -> Any? {
        try? await panel.webView?.callAsyncJavaScript("return \(expr)", contentWorld: .page)
    }
    func pins(_ panel: PreviewPanel, _ expr: String) async -> Any? {
        try? await panel.webView?.callAsyncJavaScript("return \(expr)", contentWorld: PreviewComments.world)
    }
    func loaded(_ panel: PreviewPanel, _ n: Int = 1) async -> Bool { await pollUntil(10) { panel.loads >= n } }
    /// A real (trusted) click on the element's top-left corner + 5 pt: mouse events sent to the web view.
    func realClick(_ panel: PreviewPanel, _ w: NSWindow, _ sel: String) async throws {
        let r = try #require(await page(panel, "(() => { const r = document.querySelector('\(sel)').getBoundingClientRect(); return [r.left + 5, r.top + 5] })()") as? [NSNumber])
        let web = try #require(panel.webView)
        let local = NSPoint(x: r[0].doubleValue, y: web.isFlipped ? r[1].doubleValue : web.bounds.height - r[1].doubleValue)
        let at = web.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { web.mouseDown(with: e) } else { web.mouseUp(with: e) }
        }
    }
    /// A synthetic click the page itself could dispatch (`isTrusted` false).
    func click(_ panel: PreviewPanel, _ sel: String) async {
        _ = await page(panel, "(() => { const r = document.querySelector('\(sel)').getBoundingClientRect();"
                      + " document.querySelector('\(sel)').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true,"
                      + " clientX: r.left + 5, clientY: r.top + 5})); return 1 })()")
    }

    @Test func clickInCommentModeReportsAnchor() async throws {
        let root = try project("<body style='margin:0'><div id='main'><p>a</p><p class='t' style='margin-top:300px'>alvo</p></div>"
                               + "<script>window.hit = 0; document.addEventListener('click', () => window.hit++)</script></body>")
        let d = PreviewFakeDaemon()
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        panel.comments.setMode(true)
        try await realClick(panel, w, ".t")
        #expect(await pollUntil(3) { panel.comments.draft != nil })
        let draft = try #require(panel.comments.draft)
        let sel = try #require(draft.selector)
        #expect(sel.hasPrefix("#main"), "\(sel)")
        #expect(await page(panel, "document.querySelector(\(String(reflecting: sel))) === document.querySelector('.t')") as? Bool == true)
        #expect((0...1).contains(draft.x) && (0...1).contains(draft.y) && draft.y > 0.1 && draft.text == "alvo")
        #expect(await page(panel, "window.hit") as? Int == 0)   // swallowed
        #expect(!panel.comments.mode)   // one click per comment
        // the composer sends it as the app, with the page, the Prévia and the anchor
        await panel.comments.send("deixe maior")
        let add = try #require(d.calls.first { $0.0 == "comment.add" }?.1)
        #expect(add["root"] == .string(root.path) && add["path"] == .string("p.html") && add["panel"] == .string("Prévia"))
        #expect(add["body"] == .string("deixe maior") && add["selector"] == .string(sel) && add["text"] == .string("alvo"))
        #expect(panel.comments.draft == nil)
    }

    /// A click the page dispatches itself never sets the comment's point (nor is swallowed: comment mode stays on).
    @Test func syntheticClickIgnoredInCommentMode() async throws {
        let root = try project("<body><p class='t'>alvo</p><script>window.hit = 0; document.addEventListener('click', () => window.hit++)</script></body>")
        let (panel, w) = mount(root: root, daemon: PreviewFakeDaemon())
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        panel.comments.setMode(true)
        await click(panel, ".t")
        #expect(await pollUntil(2) { await page(panel, "window.hit") as? Int == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(panel.comments.draft == nil && panel.comments.mode)
    }

    /// A pin at the document's edge never grows the page's scroll size.
    @Test func edgePinKeepsScrollSize() async throws {
        let root = try project("<body style='margin:0'><div style='height:1000px;width:400px'></div></body>")
        let d = PreviewFakeDaemon(); d.list = [comment("c1aaaaaa-1", selector: nil, x: 1, y: 1)]
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        let before = (await page(panel, "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") as? [NSNumber])?.map(\.intValue)
        await panel.comments.refresh()
        #expect(await pollUntil(3) { await pins(panel, "collieComments.positions().length") as? Int == 1 })
        let after = (await page(panel, "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") as? [NSNumber])?.map(\.intValue)
        #expect(before != nil && before == after)
        // drawn again (resize, reload): the same point, not pushed further out
        let top1 = ((await pins(panel, "collieComments.positions()[0].top")) as? NSNumber)?.doubleValue
        _ = await pins(panel, "collieComments.show(collieComments.positions().length ? [{id: 'c1aaaaaa-1', n: 1, selector: null, x: 1, y: 1}] : [])")
        let top2 = ((await pins(panel, "collieComments.positions()[0].top")) as? NSNumber)?.doubleValue
        #expect(top1 != nil && top1 == top2)
    }

    @Test func clickOutsideCommentModePassesThrough() async throws {
        let root = try project("<body><p class='t'>alvo</p><script>window.hit = 0; document.addEventListener('click', () => window.hit++)</script></body>")
        let (panel, w) = mount(root: root, daemon: PreviewFakeDaemon())
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        await click(panel, ".t")
        #expect(await pollUntil(2) { await page(panel, "window.hit") as? Int == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(panel.comments.draft == nil)
    }

    @Test func pinsDrawnInClosedShadowRoot() async throws {
        let root = try project("<body><h1 id='h'>Oi</h1></body>")
        let d = PreviewFakeDaemon(); d.list = [comment("c1aaaaaa-1", selector: "#h", x: 0.1, y: 0.1), comment("c2bbbbbb-2", selector: nil, x: 0.5, y: 0.5, resolved: true)]
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        await panel.comments.refresh()
        #expect(await pollUntil(3) { await pins(panel, "collieComments.positions().length") as? Int == 2 })
        #expect(await page(panel, "document.querySelectorAll('[data-collie-pin]').length") as? Int == 0)
        #expect(await page(panel, "Array.from(document.querySelectorAll('*')).some(e => e.shadowRoot)") as? Bool == false)
        #expect(await page(panel, "typeof window.collieComments") as? String == "undefined")
        #expect(panel.comments.openCount == 1 && panel.header.comments == 1)
        // a pin click opens its thread
        _ = await pins(panel, "collieComments.clickPin('c1aaaaaa-1')")
        #expect(await pollUntil(2) { panel.comments.selected == "c1aaaaaa-1" && panel.comments.drawer })
    }

    @Test func pinReanchorsToSelectorAfterReload() async throws {
        let root = try project("<body style='margin:0'><div id='box' style='margin-top:100px;height:20px'>x</div><div style='height:2000px'></div></body>")
        let d = PreviewFakeDaemon(); d.list = [comment("c1aaaaaa-1", selector: "#box", x: 0.9, y: 0.9)]
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        await panel.comments.refresh()
        func top() async -> Double? {
            ((await pins(panel, "collieComments.positions()") as? [[String: Any]])?.first?["top"] as? NSNumber)?.doubleValue
        }
        #expect(await pollUntil(3) { await top().map { abs($0 - 100) < 2 } ?? false })
        try Data("<body style='margin:0'><div id='box' style='margin-top:400px;height:20px'>x</div><div style='height:2000px'></div></body>".utf8)
            .write(to: root.appendingPathComponent("p.html"), options: .atomic)
        #expect(await loaded(panel, 2))
        #expect(await pollUntil(5) { await top().map { abs($0 - 400) < 2 } ?? false })
        #expect(panel.comments.approximate.isEmpty)
    }

    @Test func pinFallsBackWhenSelectorGone() async throws {
        let root = try project("<body style='margin:0'><div style='height:1000px;width:500px'></div></body>")
        let d = PreviewFakeDaemon(); d.list = [comment("c1aaaaaa-1", selector: "#gone", x: 0.5, y: 0.25)]
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        #expect(await loaded(panel))
        await panel.comments.refresh()
        #expect(await pollUntil(3) { panel.comments.approximate == ["c1aaaaaa-1"] })
        let p = try #require((await pins(panel, "collieComments.positions()") as? [[String: Any]])?.first)
        let hv = await page(panel, "document.documentElement.scrollHeight")
        let h = try #require((hv as? NSNumber)?.doubleValue)
        #expect(abs(((p["top"] as? NSNumber)?.doubleValue ?? -1) - 0.25 * h) < 2 && p["approx"] as? Bool == true)
        #expect(panel.comments.threads.count == 1)   // never dropped
    }

    @Test func artifactModeComments() async throws {
        let root = try project("<body></body>")
        let d = PreviewFakeDaemon()
        let id = UUID().uuidString.lowercased()
        let (panel, w) = mount(root: root, state: ["artifact": .string(id)], daemon: d)
        defer { panel.close(); w.close() }
        await panel.comments.refresh()
        let list = try #require(d.calls.first { $0.0 == "comment.list" }?.1)
        #expect(list["artifact"] == .string(id) && list["root"] == nil && list["path"] == nil)
    }

    @Test func changedEventRefreshesDrawer() async throws {
        let root = try project("<body></body>")
        let d = PreviewFakeDaemon(); d.list = [comment("c1aaaaaa-1", selector: nil, x: 0, y: 0, to: nil)]
        let (panel, w) = mount(root: root, daemon: d)
        defer { panel.close(); w.close() }
        await panel.comments.refresh()
        #expect(panel.comments.threads.map(\.id) == ["c1aaaaaa-1"] && panel.comments.threads[0].notice == PreviewComments.noAddressee)
        d.list = [comment("c2bbbbbb-2", selector: nil, x: 0, y: 0, undeliverable: true), d.list[0]]
        panel.receive(event: "comment.changed", payload: .object(["page": .string("k"), "id": .string("c2bbbbbb-2")]))
        #expect(await pollUntil(3) { panel.comments.threads.count == 2 })
        #expect(panel.comments.threads[0].notice == "Não entregue: o terminal A não existe mais" && panel.comments.threads[0].n == 2)
    }
}
