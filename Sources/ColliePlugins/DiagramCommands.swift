import AppKit
import CollieCore
import CollieProtocol
import WebKit

/// `diagram.*` (agents, through `ui.host`): read and replace the panel's `.drawio` file, insert Mermaid as editable
/// shapes, export a page to PNG/SVG, screenshot the panel. One command at a time per panel.
extension DiagramPanel {
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let previous = queue
        let mine = Task { @MainActor [weak self] () -> Result<JSONValue, ProtocolError> in
            await previous?.value
            guard let self else { return .failure(ProtocolError(code: .notFound, message: "painel fechado")) }
            do throws(ProtocolError) { return .success(try await self.run(command, args)) } catch { return .failure(error) }
        }
        queue = Task { _ = await mine.value }
        return try await mine.value.get()
    }

    private func run(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        switch command {
        case "diagram.get":
            let (url, xml) = try current()
            return .object(["file": .string(relative(url)), "xml": .string(xml),
                            "pages": .array(Self.pages(xml).map { .object(["id": .string($0.id), "name": .string($0.name)]) })])
        case "diagram.set":
            guard case .string(let xml)? = args["xml"] else { throw ProtocolError(code: .invalidArgs, message: "diagram.set: give --xml or --from") }
            try DiagramFile.validate(xml: xml)
            let url = try await replace(xml)
            return .object(["file": .string(relative(url)), "bytes": .number(Double(xml.utf8.count))])
        case "diagram.mermaid":
            guard case .string(let text)? = args["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProtocolError(code: .invalidArgs, message: "diagram.mermaid: falta o texto Mermaid")
            }
            try await ensureEditor()
            let model = try await mermaidModel(text)
            let (_, xml) = try current()
            let merged = try Self.insert(model: model, into: xml, page: string(args, "page"), current: currentPage)
            try DiagramFile.validate(xml: merged.xml)
            _ = try await replace(merged.xml)
            return .object(["inserted": .number(Double(merged.cells)), "editable": .bool(true)])
        case "diagram.export":
            let format = string(args, "format") ?? ""
            guard format == "png" || format == "svg" else { throw ProtocolError(code: .invalidArgs, message: "--format must be png|svg") }
            try await ensureEditor()
            return try await export(format, page: string(args, "page"))
        case "diagram.screenshot":
            try await ensureEditor()
            guard let web = webView else { throw ProtocolError(code: .unavailable, message: "o editor de diagramas não está aberto") }
            let image: NSImage
            do { image = try await web.takeSnapshot(configuration: nil) } catch {
                throw ProtocolError(code: .unavailable, message: "screenshot failed: \(error.localizedDescription)")
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ProtocolError(code: .unavailable, message: "screenshot: o painel não tem tamanho")
            }
            return try BrowserPanel.savePNG(cg, in: screens, prefix: panel.id.uuidString + "-").get()
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
        }
    }

    private func string(_ args: [String: JSONValue], _ k: String) -> String? { if case .string(let s)? = args[k], !s.isEmpty { s } else { nil } }
    var screens: URL { host.root.appendingPathComponent("screens", isDirectory: true) }

    /// The panel's file and its XML (resolved again if the view never started).
    private func current() throws(ProtocolError) -> (URL, String) {
        let url: URL
        if let file { url = file } else {
            guard let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem pasta de projeto") }
            url = try DiagramFile.resolve(requestedFile, panelName: panel.name, projectRoot: root)
        }
        guard let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem pasta de projeto") }
        return (url, try DiagramFile.read(url, root: root) ?? DiagramFile.empty)
    }
    private func relative(_ url: URL) -> String {
        guard let root = projectRoot.map(DiagramFile.real) else { return url.path }
        return url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    }

    /// Writes an agent's version (Review Focus 1: only when the user made no edit in the last 2 s) and merges it into a
    /// live editor (zoom and scroll kept).
    private func replace(_ xml: String) async throws(ProtocolError) -> URL {
        guard DiagramFile.mayOverwrite(lastUserEditAt: lastUserEditAt, now: Date()) else {
            throw ProtocolError(code: .unavailable, message: "o usuário está editando; tente de novo")   // no `conflict` code in the protocol
        }
        let (url, _) = try current()
        guard let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem pasta de projeto") }
        try DiagramFile.write(xml, to: url, root: root)
        noteWritten(xml)
        if editorReady {
            send(["action": "merge", "xml": xml])
            _ = await next("merge", timeout: 10)
        }
        return url
    }

    /// The editor is up (starting it if the panel was never shown), or why not.
    private func ensureEditor() async throws(ProtocolError) {
        startIfNeeded()
        let end = Date().addingTimeInterval(30)
        while !editorReady, failure == nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        if let failure { throw ProtocolError(code: .unavailable, message: failure) }
        guard editorReady else { throw ProtocolError(code: .timeout, message: "o editor de diagramas não abriu em 30 s") }
    }

    /// Mermaid → `<mxGraphModel>` by draw.io's own converter, in the editor's frame (offline). R7: an error or a result
    /// without shapes is refused, with the converter's message when it gives one.
    private func mermaidModel(_ text: String) async throws(ProtocolError) -> String {
        guard let web = webView else { throw ProtocolError(code: .unavailable, message: "o editor de diagramas não está aberto") }
        let js = """
            const w = document.getElementById('f').contentWindow;
            if (!w || !w.mxMermaidToDrawio || !w.mxMermaidToDrawio.parseText) return {error: 'conversor Mermaid indisponível'};
            try { return {xml: String(await w.mxMermaidToDrawio.parseText(text))} } catch (e) { return {error: String((e && e.message) || e)} }
            """
        let r: [String: Any]?
        do { r = try await web.callAsyncJavaScript(js, arguments: ["text": text], in: nil, contentWorld: .page) as? [String: Any] }
        catch { throw ProtocolError(code: .internal, message: "Mermaid: \(BrowserAutomation.jsMessage(error))") }
        if let e = r?["error"] as? String { throw ProtocolError(code: .invalidArgs, message: "Mermaid não reconhecido: \(e)") }
        guard let xml = r?["xml"] as? String, xml.contains("vertex=\"1\"") else {
            throw ProtocolError(code: .invalidArgs, message: "Mermaid não reconhecido: nenhuma forma (\(Self.firstLine(text)))")
        }
        return xml
    }
    static func firstLine(_ s: String) -> String {
        let l = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return "linha 1: " + String(l.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    private func export(_ format: String, page: String?) async throws(ProtocolError) -> JSONValue {
        let (_, xml) = try current()
        var msg: [String: Any] = ["action": "export", "format": format, "border": 10]
        if let page {
            let all = Self.pages(xml)
            guard let i = all.firstIndex(where: { $0.name == page }) else {
                throw ProtocolError(code: .invalidArgs, message: "página '\(page)' não existe (\(all.map(\.name).joined(separator: ", ")))")
            }
            if format == "png" { msg["pageId"] = all[i].id }
            else if i != currentPage {   // draw.io's SVG export is always of the page on screen
                throw ProtocolError(code: .invalidArgs, message: "SVG só da página aberta no painel; use --format png para '\(page)'")
            }
        } else if format == "png" { msg["currentPage"] = true }
        send(msg)
        guard let r = await next("export", timeout: 50), case .string(let uri)? = r["data"] else {
            throw ProtocolError(code: .timeout, message: "a exportação não respondeu")
        }
        guard let data = Self.decodeDataURI(uri), !data.isEmpty else { throw ProtocolError(code: .internal, message: "exportação vazia") }
        let size = format == "png" ? Self.pngSize(data) : Self.svgSize(data)
        let out = screens.appendingPathComponent("\(panel.id.uuidString)-\(UUID().uuidString).\(format)")
        do {
            try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: screens.path)
            try data.write(to: out, options: .atomic)
        } catch { throw ProtocolError(code: .internal, message: "exportação: \(error.localizedDescription)") }
        return .object(["path": .string(out.path), "width": .number(size.0), "height": .number(size.1)])
    }

    // MARK: pure helpers

    /// `<diagram id name>` of an `mxfile` (none for a bare `mxGraphModel`).
    static func pages(_ xml: String) -> [(id: String, name: String)] {
        guard let doc = try? XMLDocument(xmlString: xml), let root = doc.rootElement(), root.name == "mxfile" else { return [] }
        return root.elements(forName: "diagram").map { ($0.attribute(forName: "id")?.stringValue ?? "", $0.attribute(forName: "name")?.stringValue ?? "") }
    }

    /// Adds the converted model's shapes to a page of `file` (`page` by name, else the one on screen): fresh ids, on the
    /// page's first layer, below what is already there. Returns the new document and how many cells were added.
    /// ponytail: compressed pages (draw.io's older default) are refused, not inflated; add raw-deflate decoding if one shows up.
    static func insert(model: String, into file: String, page: String?, current: Int) throws(ProtocolError) -> (xml: String, cells: Int) {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard let src = try? XMLDocument(xmlString: model), let srcRoot = src.rootElement()?.elements(forName: "root").first,
              let doc = try? XMLDocument(xmlString: file), let top = doc.rootElement() else { throw bad("Mermaid não reconhecido: resultado inválido") }
        let target: XMLElement
        if top.name == "mxGraphModel" { target = top } else {
            let diagrams = top.elements(forName: "diagram")
            let d: XMLElement?
            if let page { d = diagrams.first { $0.attribute(forName: "name")?.stringValue == page } }
            else { d = diagrams.isEmpty ? nil : diagrams[min(max(current, 0), diagrams.count - 1)] }
            guard let d else { throw bad("página '\(page ?? "")' não existe") }
            guard let m = d.elements(forName: "mxGraphModel").first else { throw bad("a página está comprimida; abra e salve o diagrama no painel antes") }
            target = m
        }
        let dstRoot: XMLElement
        if let r = target.elements(forName: "root").first { dstRoot = r } else { dstRoot = XMLElement(name: "root"); target.addChild(dstRoot) }

        func cell(_ e: XMLElement) -> XMLElement { e.name == "mxCell" ? e : (e.elements(forName: "mxCell").first ?? e) }
        func attr(_ e: XMLElement, _ n: String) -> String? { e.attribute(forName: n)?.stringValue }
        func set(_ e: XMLElement, _ n: String, _ v: String) {
            if let a = e.attribute(forName: n) { a.stringValue = v } else { e.addAttribute(XMLNode.attribute(withName: n, stringValue: v) as! XMLNode) }
        }
        let elements = { (r: XMLElement) in (r.children ?? []).compactMap { $0 as? XMLElement } }
        // root cell (no parent), its layers, the rest
        let srcAll = elements(srcRoot)
        let srcRootIds = Set(srcAll.filter { attr(cell($0), "parent") == nil }.compactMap { attr($0, "id") })
        let srcLayers = Set(srcAll.filter { attr(cell($0), "parent").map(srcRootIds.contains) == true }.compactMap { attr($0, "id") })
        let items = srcAll.filter { e in attr(e, "id").map { !srcRootIds.contains($0) && !srcLayers.contains($0) } ?? false }
        let dstAll = elements(dstRoot)
        let dstRootId = dstAll.first { attr(cell($0), "parent") == nil }.flatMap { attr($0, "id") } ?? "0"
        let layer = dstAll.first { attr(cell($0), "parent") == dstRootId }.flatMap { attr($0, "id") } ?? "1"
        guard items.contains(where: { (try? $0.nodes(forXPath: "descendant-or-self::*[@vertex='1']").isEmpty) == false }) else {
            throw bad("Mermaid não reconhecido: nenhuma forma")
        }
        // below the page's current content
        var bottom = 0.0
        for e in dstAll where attr(cell(e), "parent") == layer && attr(cell(e), "vertex") == "1" {
            if let g = cell(e).elements(forName: "mxGeometry").first {
                bottom = max(bottom, (Double(attr(g, "y") ?? "0") ?? 0) + (Double(attr(g, "height") ?? "0") ?? 0))
            }
        }
        let dy = bottom > 0 ? bottom + 40 : 0
        let prefix = "m" + String(UUID().uuidString.prefix(6)).lowercased() + "-"
        var ids: [String: String] = [:]
        for e in items { for n in (try? e.nodes(forXPath: "descendant-or-self::*[@id]")) ?? [] { if let el = n as? XMLElement, let v = attr(el, "id") { ids[v] = prefix + v } } }
        for e in items {
            let topLevel = attr(cell(e), "parent").map(srcLayers.contains) == true
            for n in (try? e.nodes(forXPath: "descendant-or-self::*")) ?? [] {
                guard let el = n as? XMLElement else { continue }
                for k in ["id", "parent", "source", "target"] {
                    guard let v = attr(el, k) else { continue }
                    if k == "parent", srcLayers.contains(v) { set(el, k, layer) } else if let m = ids[v] { set(el, k, m) }
                }
            }
            if topLevel, dy > 0, let g = cell(e).elements(forName: "mxGeometry").first {
                let edge = attr(cell(e), "edge") == "1"
                if !edge { set(g, "y", String((Double(attr(g, "y") ?? "0") ?? 0) + dy)) }
                else { for p in (try? g.nodes(forXPath: ".//mxPoint")) ?? [] { if let p = p as? XMLElement { set(p, "y", String((Double(attr(p, "y") ?? "0") ?? 0) + dy)) } } }
            }
            e.detach()
            dstRoot.addChild(e)
        }
        return (doc.rootElement()?.xmlString ?? file, items.count)
    }

    static func decodeDataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let head = uri[..<comma], body = String(uri[uri.index(after: comma)...])
        return head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
    }
    static func pngSize(_ d: Data) -> (Double, Double) {
        guard d.count >= 24 else { return (0, 0) }
        let b = [UInt8](d.prefix(24))
        func be(_ i: Int) -> Double { Double(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])) }
        return (be(16), be(20))
    }
    static func svgSize(_ d: Data) -> (Double, Double) {
        guard let doc = try? XMLDocument(data: d), let r = doc.rootElement() else { return (0, 0) }
        func n(_ k: String) -> Double { Double((r.attribute(forName: k)?.stringValue ?? "").prefix { $0.isNumber || $0 == "." }) ?? 0 }
        return (n("width"), n("height"))
    }
}
