import AppKit
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// `diagram.*` against the vendored draw.io build (each test is skipped, with a message, when `vendor/drawio/web` is missing).
@MainActor @Suite(.serialized) struct DiagramPanelTests {
    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/drawio/web")
    static var built: Bool {
        let ok = FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path)
        if !ok { print("skipped: vendor/drawio/web missing (run scripts/build-drawio.sh)") }
        return ok
    }

    @MainActor final class Rig {
        let root: URL, panel: DiagramPanel, window: NSWindow
        init(root: URL, panel: DiagramPanel, window: NSWindow) { self.root = root; self.panel = panel; self.window = window }
        var file: URL { root.appendingPathComponent("docs/diagrams/arq.drawio") }
        func text() throws -> String { try String(contentsOf: file, encoding: .utf8) }
        func call(_ c: String, _ a: [String: JSONValue] = [:]) async throws(ProtocolError) -> JSONValue { try await panel.handle(c, a) }
        func done() { panel.close(); window.close() }
    }

    /// A panel on a fresh project, in a window, with the editor loaded (`shown: false` leaves it unmounted).
    func rig(shown: Bool = true) async throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: DiagramFile.real(base).path)
        let p = Panel(id: UUID(), name: "arq", pluginId: "diagram", placement: .canvas, state: ["root": .string(root.path)])
        let host = PanelHostContext(panel: p, root: root.appendingPathComponent(".collie"), workspaceId: nil,
                                    call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let panel = DiagramPanel(panel: p, host: host, webRoot: Self.web)
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        if shown {
            panel.view.frame = w.contentView!.bounds
            w.contentView!.addSubview(panel.view)
            let end = Date().addingTimeInterval(30)
            while !panel.editorReady, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
            #expect(panel.editorReady, "\(panel.seen) \(panel.failure ?? "")")
        }
        return Rig(root: root, panel: panel, window: w)
    }
    func count(_ s: String, _ sub: String) -> Int { s.components(separatedBy: sub).count - 1 }
    let two = #"<mxfile><diagram id="p1" name="Um"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="A" vertex="1" parent="1"><mxGeometry x="10" y="10" width="80" height="40" as="geometry"/></mxCell></root></mxGraphModel></diagram><diagram id="p2" name="Dois"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/></root></mxGraphModel></diagram></mxfile>"#

    @Test func getReturnsFileXml() async throws {
        guard Self.built else { return }
        let r = try await rig(shown: false); defer { r.done() }
        try DiagramFile.write(two, to: r.file, root: r.root)
        guard case .object(let o) = try await r.call("diagram.get") else { Issue.record("not an object"); return }
        #expect(o["file"] == .string("docs/diagrams/arq.drawio") && o["xml"] == .string(two))
        #expect(o["pages"] == .array([.object(["id": .string("p1"), "name": .string("Um")]), .object(["id": .string("p2"), "name": .string("Dois")])]))
    }

    @Test func setReplacesAndPanelReloads() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        let merges = r.panel.seen.count(where: { $0 == "merge" })
        guard case .object(let o) = try await r.call("diagram.set", ["xml": .string(two)]) else { Issue.record("not an object"); return }
        #expect(o["bytes"] == .number(Double(two.utf8.count)) && o["file"] == .string("docs/diagrams/arq.drawio"))
        #expect(try r.text() == two)
        #expect(r.panel.seen.count(where: { $0 == "merge" }) == merges + 1)
        #expect(r.panel.lastUserEditAt == nil)   // the merge's autosave is not the user's
    }

    @Test func setMalformedRefused() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        let before = try r.text()
        do { _ = try await r.call("diagram.set", ["xml": .string("<mxfile>\n<diagram>\n</mxfile>")]); Issue.record("accepted") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("linha"), "\(error.message)") }
        #expect(try r.text() == before)
    }

    @Test func setConflictWhileUserEditing() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        let before = try r.text()
        r.panel.lastUserEditAt = Date()
        do { _ = try await r.call("diagram.set", ["xml": .string(two)]); Issue.record("accepted") }
        catch { #expect(error.code == .conflict && error.message == "o usuário está editando; tente de novo", "\(error)") }
        #expect(try r.text() == before)
        r.panel.lastUserEditAt = Date().addingTimeInterval(-3)
        _ = try await r.call("diagram.set", ["xml": .string(two)])
        #expect(try r.text() == two)
    }

    @Test func mermaidInsertsFlowchart() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        guard case .object(let o) = try await r.call("diagram.mermaid", ["text": .string("graph TD; A-->B")]) else { Issue.record("not an object"); return }
        #expect(o["editable"] == .bool(true))
        let x = try r.text()
        #expect(count(x, #"vertex="1""#) == 2 && count(x, #"edge="1""#) == 1, "\(x)")
        #expect(!x.contains("shape=image"))
        try DiagramFile.validate(xml: x)
        // a second insert keeps the first and lands below it, with fresh ids
        _ = try await r.call("diagram.mermaid", ["text": .string("graph TD; C-->D")])
        let y = try r.text()
        #expect(count(y, #"vertex="1""#) == 4 && count(y, #"edge="1""#) == 2)
    }

    @Test func mermaidOnNamedPage() throws {
        let model = #"<mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="n" value="X" vertex="1" parent="1"><mxGeometry x="0" y="0" width="10" height="10" as="geometry"/></mxCell></root></mxGraphModel>"#
        let (xml, cells) = try DiagramPanel.insert(model: model, into: two, page: "Um", current: 1)
        #expect(cells == 1)
        let um = try #require(xml.components(separatedBy: #"name="Dois""#).first)
        #expect(count(um, #"vertex="1""#) == 2)                       // landed on Um, not the page on screen
        #expect(xml.contains(#"y="90.0""#))                            // below A (10 + 40 + 40)
        #expect(throws: ProtocolError.self) { try DiagramPanel.insert(model: model, into: two, page: "Três", current: 0) }
    }

    @Test func mermaidBadLineRefused() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        let before = try r.text()
        for bad in ["isto não é mermaid", "sequenceDiagram\n  Alice->>: oi"] {
            do { _ = try await r.call("diagram.mermaid", ["text": .string(bad)]); Issue.record("accepted \(bad)") }
            catch { #expect(error.code == .invalidArgs && error.message.hasPrefix("Mermaid não reconhecido"), "\(error.message)") }
        }
        #expect(try r.text() == before)
    }

    @Test func exportPngIsPng() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        _ = try await r.call("diagram.set", ["xml": .string(two)])
        guard case .object(let o) = try await r.call("diagram.export", ["format": .string("png")]),
              case .string(let path)? = o["path"], case .number(let w)? = o["width"] else { Issue.record("bad reply"); return }
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(d.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && w > 0)
        #expect(path.hasPrefix(r.root.appendingPathComponent(".collie/screens").path))
        _ = try await r.call("diagram.export", ["format": .string("png"), "page": .string("Dois")])
        do { _ = try await r.call("diagram.export", ["format": .string("gif")]); Issue.record("gif accepted") } catch { #expect(error.code == .invalidArgs) }
    }

    @Test func exportSvgIsSvg() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        _ = try await r.call("diagram.set", ["xml": .string(two)])
        guard case .object(let o) = try await r.call("diagram.export", ["format": .string("svg")]), case .string(let path)? = o["path"] else {
            Issue.record("bad reply"); return
        }
        let svg = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(path.hasSuffix(".svg") && svg.contains("<svg"))
        guard case .object(let s) = try await r.call("diagram.screenshot"), case .number(let sw)? = s["width"] else { Issue.record("no screenshot"); return }
        #expect(sw > 0)
    }

    @Test func noNetworkRequests() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        let web = try #require(r.panel.webView)
        let res = try await web.callAsyncJavaScript(
            "const w = document.getElementById('f').contentWindow; try { await w.fetch('https://example.com/', {mode: 'no-cors'}); return 'open' } catch (e) { return 'blocked' }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(res == "blocked")
    }

    /// R13/C1+H1: a file on disk with a DTD (XXE to a file outside the project, an entity bomb) is refused by every
    /// command that reads it, fast, without expanding anything; the file is left as it was.
    @Test func doctypeOnDiskRefused() async throws {
        guard Self.built else { return }
        let r = try await rig(shown: false); defer { r.done() }
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("segredo-\(UUID().uuidString).txt")
        try Data("SEGREDO".utf8).write(to: secret)
        let xxe = #"<?xml version="1.0"?><!DOCTYPE mxfile [<!ENTITY x SYSTEM ""# + "\"\(secret.absoluteString)\"" + #">]><mxfile><diagram id="p1" name="Um"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="&x;" vertex="1" parent="1"><mxGeometry width="80" height="40" as="geometry"/></mxCell></root></mxGraphModel></diagram></mxfile>"#
        var bomb = "<!DOCTYPE mxfile [<!ENTITY a0 \"ha\">"
        for i in 1...9 { bomb += "<!ENTITY a\(i) \"" + String(repeating: "&a\(i - 1);", count: 10) + "\">" }
        bomb += #"]><mxfile><diagram id="p1" name="&a9;"/></mxfile>"#
        try FileManager.default.createDirectory(at: r.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for doc in [xxe, bomb] {
            try Data(doc.utf8).write(to: r.file)
            let t0 = Date()
            for (c, a) in [("diagram.get", [:]), ("diagram.mermaid", ["text": JSONValue.string("graph TD; A-->B")]),
                           ("diagram.export", ["format": .string("png"), "page": .string("Um")])] as [(String, [String: JSONValue])] {
                do { let v = try await r.call(c, a); Issue.record("\(c) answered \(v)") } catch {
                    #expect(error.code == .invalidArgs && error.message.contains("DOCTYPE"), "\(c): \(error)")
                    #expect(!error.message.contains("SEGREDO"))
                }
            }
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(try r.text() == doc)
        }
        do { _ = try await r.call("diagram.set", ["xml": .string(xxe)]); Issue.record("set accepted a DOCTYPE") }
        catch { #expect(error.code == .invalidArgs) }
        _ = try await r.call("diagram.set", ["xml": .string(two)])   // an agent can still fix the file
        #expect(try r.text() == two)
    }

    /// R13/M2: the Mermaid text is capped (64 KiB).
    @Test func mermaidTextCapped() async throws {
        let r = try await rig(shown: false); defer { r.done() }
        do { _ = try await r.call("diagram.mermaid", ["text": .string("graph TD; " + String(repeating: "A-->B;", count: 12_000))]); Issue.record("accepted") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("64"), "\(error)") }
    }

    /// R13/M2: a JS call that never settles (a promise, or a synchronous loop) times out, and the next command runs.
    @Test func hungMermaidDoesNotBlockLaterCommands() async throws {
        guard Self.built else { return }
        let r = try await rig(); defer { r.done() }
        r.panel.jsTimeout = 1
        for hang in ["() => new Promise(() => {})", "() => { for (;;) {} }"] {
            let web = try #require(r.panel.webView)
            _ = try await web.callAsyncJavaScript("document.getElementById('f').contentWindow.mxMermaidToDrawio.parseText = \(hang); return 1",
                                                  arguments: [:], in: nil, contentWorld: .page)
            do { _ = try await r.call("diagram.mermaid", ["text": .string("graph TD; A-->B")]); Issue.record("answered") }
            catch { #expect(error.code == .timeout, "\(error)") }
            let t0 = Date()
            _ = try await r.call("diagram.get")
            #expect(Date().timeIntervalSince(t0) < 1)
            let end = Date().addingTimeInterval(30)   // a fresh editor comes up
            while !r.panel.editorReady, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
            #expect(r.panel.editorReady)
        }
        r.panel.jsTimeout = 15
        guard case .object(let o) = try await r.call("diagram.mermaid", ["text": .string("graph TD; A-->B")]) else { Issue.record("no reply"); return }
        #expect(o["editable"] == .bool(true))
    }

    /// R13/L3: an export payload over the cap is refused, not decoded.
    @Test func exportPayloadCapped() {
        let uri = "data:image/png;base64," + Data(repeating: 1, count: 300).base64EncodedString()
        #expect(DiagramPanel.decodeDataURI(uri, max: 1000)?.count == 300)
        #expect(DiagramPanel.decodeDataURI(uri, max: 100) == nil)
        #expect(DiagramPanel.exportMaxBytes == 32 << 20)
    }
}
