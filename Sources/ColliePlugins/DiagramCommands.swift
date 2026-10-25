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
            let pages = await Self.offMain { Self.pages(xml) }
            return .object(["file": .string(relative(url)), "xml": .string(xml),
                            "pages": .array(pages.map { .object(["id": .string($0.id), "name": .string($0.name)]) })])
        case "diagram.set":
            guard case .string(let xml)? = args["xml"] else { throw ProtocolError(code: .invalidArgs, message: "diagram.set: give --xml or --from") }
            try DiagramFile.validate(xml: xml)
            let url = try await replace(xml)
            return .object(["file": .string(relative(url)), "bytes": .number(Double(xml.utf8.count))])
        case "diagram.mermaid":
            guard case .string(let text)? = args["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProtocolError(code: .invalidArgs, message: "diagram.mermaid: falta o texto Mermaid")
            }
            guard text.utf8.count <= Self.mermaidMaxBytes else {
                throw ProtocolError(code: .invalidArgs, message: "diagram.mermaid: texto grande demais (máximo \(Self.mermaidMaxBytes >> 10) KiB)")
            }
            _ = try current()   // a bad file is refused before the editor is started
            try await ensureEditor()
            let model = try await mermaidModel(text)
            try DiagramFile.validate(xml: model)
            let (_, xml) = try current()
            let page = string(args, "page"), on = currentPage
            let merged = try await Self.offMain { () throws(ProtocolError) in try Self.insert(model: model, into: xml, page: page, current: on) }
            try DiagramFile.validate(xml: merged.xml)
            _ = try await replace(merged.xml, over: xml)
            return .object(["inserted": .number(Double(merged.cells)), "editable": .bool(true)])
        case "diagram.export":
            let format = string(args, "format") ?? ""
            guard format == "png" || format == "svg" else { throw ProtocolError(code: .invalidArgs, message: "--format must be png|svg") }
            _ = try current()
            try await ensureEditor()
            return try await export(format, page: string(args, "page"))
        case "diagram.screenshot":
            try await ensureEditor(timeout: 25)   // within the command's 30 s
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
    /// `validated: false` only to replace the file (`diagram.set` may fix a bad one): its text is then not used.
    private func current(validated: Bool = true) throws(ProtocolError) -> (URL, String) {
        let url: URL
        if let file { url = file } else {
            guard let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem pasta de projeto") }
            url = try DiagramFile.resolve(requestedFile, panelName: panel.name, projectRoot: root)
        }
        guard let root = projectRoot else { throw ProtocolError(code: .unavailable, message: "painel sem pasta de projeto") }
        let xml = try DiagramFile.read(url, root: root) ?? DiagramFile.empty
        if validated { try DiagramFile.validate(xml: xml) }   // R13: never handed to XMLDocument (or the agent) unchecked
        return (url, xml)
    }
    private func relative(_ url: URL) -> String {
        guard let root = projectRoot.map(DiagramFile.real) else { return url.path }
        return url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    }

    /// Writes an agent's version (Review Focus 1: only when the user made no edit in the last 2 s) and merges it into a
    /// live editor (zoom and scroll kept). `over`: the version it was made from; the file must still be that one.
    private func replace(_ xml: String, over base: String? = nil) async throws(ProtocolError) -> URL {
        guard DiagramFile.mayOverwrite(lastUserEditAt: lastUserEditAt, now: Date()) else {
            throw ProtocolError(code: .conflict, message: "o usuário está editando; tente de novo")
        }
        let (url, disk) = try current(validated: base != nil)
        if let base, disk != base { throw ProtocolError(code: .conflict, message: "o diagrama mudou durante a inserção; tente de novo") }
        try writeFile(xml, at: url)
        if editorReady {
            send(["action": "merge", "xml": xml])
            _ = await next("merge", timeout: 10)
        }
        return url
    }

    /// The editor is up (starting it if the panel was never shown), or why not.
    private func ensureEditor(timeout: Double = 30) async throws(ProtocolError) {
        startIfNeeded()
        let end = Date().addingTimeInterval(timeout)
        while !editorReady, failure == nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        if let failure { throw ProtocolError(code: .unavailable, message: failure) }
        guard editorReady else { throw ProtocolError(code: .timeout, message: "o editor de diagramas não abriu em \(Int(timeout)) s") }
    }

    /// Mermaid → `<mxGraphModel>` by draw.io's own converter, in the editor's frame (offline). R7: an error or a result
    /// without shapes is refused, with the converter's message when it gives one. R13: no answer in `jsTimeout` (a promise
    /// that never settles, or a loop that holds the page) restarts the editor, so the panel's next command isn't stuck.
    private func mermaidModel(_ text: String) async throws(ProtocolError) -> String {
        guard let web = webView else { throw ProtocolError(code: .unavailable, message: "o editor de diagramas não está aberto") }
        let js = """
            const w = document.getElementById('f').contentWindow;
            if (!w || !w.mxMermaidToDrawio || !w.mxMermaidToDrawio.parseText) return {error: 'conversor Mermaid indisponível'};
            try { return {xml: String(await w.mxMermaidToDrawio.parseText(text))} } catch (e) { return {error: String((e && e.message) || e)} }
            """
        let once = Once(), secs = jsTimeout
        let reply: [String: String]? = await withCheckedContinuation { c in
            once.c = c
            web.callAsyncJavaScript(js, arguments: ["text": text], in: nil, in: .page) { result in
                switch result {
                case .success(let v): once.finish(((v as? [String: Any]) ?? [:]).compactMapValues { $0 as? String })
                case .failure(let e): once.finish(["jsError": BrowserAutomation.jsMessage(e)])
                }
            }
            Task { @MainActor in try? await Task.sleep(for: .seconds(secs)); once.finish(nil) }
        }
        guard let r = reply else {
            resetEditor()
            throw ProtocolError(code: .timeout, message: "Mermaid: o conversor não respondeu em \(Int(secs)) s; o editor foi reiniciado")
        }
        if let e = r["jsError"] { throw ProtocolError(code: .internal, message: "Mermaid: \(e)") }
        if let e = r["error"] { throw ProtocolError(code: .invalidArgs, message: "Mermaid não reconhecido: \(e)") }
        guard let xml = r["xml"], xml.contains("vertex=\"1\"") else {
            throw ProtocolError(code: .invalidArgs, message: "Mermaid não reconhecido: nenhuma forma (\(Self.firstLine(text)))")
        }
        return xml
    }
    @MainActor private final class Once {
        var c: CheckedContinuation<[String: String]?, Never>?
        func finish(_ v: [String: String]?) { c?.resume(returning: v); c = nil }
    }
    static let mermaidMaxBytes = 64 << 10

    /// XML parsing off the main actor (R13: a large document never freezes the app's UI).
    nonisolated static func offMain<T: Sendable>(_ f: @escaping @Sendable () throws(ProtocolError) -> T) async throws(ProtocolError) -> T {
        let r = await Task.detached { () -> Result<T, ProtocolError> in
            do throws(ProtocolError) { return .success(try f()) } catch { return .failure(error) }
        }.value
        return try r.get()
    }
    nonisolated static func offMain<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T { await Task.detached { f() }.value }

    static func firstLine(_ s: String) -> String {
        let l = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return "linha 1: " + String(l.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    private func export(_ format: String, page: String?) async throws(ProtocolError) -> JSONValue {
        let (_, xml) = try current()
        var msg: [String: Any] = ["action": "export", "format": format, "border": 10]
        if let page {
            let all = await Self.offMain { Self.pages(xml) }
            guard let i = all.firstIndex(where: { $0.name == page }) else {
                throw ProtocolError(code: .invalidArgs, message: "página '\(page)' não existe (\(all.map(\.name).joined(separator: ", ")))")
            }
            if format == "png" { msg["pageId"] = all[i].id }
            else if i != currentPage {   // draw.io's SVG export is always of the page on screen
                throw ProtocolError(code: .invalidArgs, message: "SVG só da página aberta no painel; use --format png para '\(page)'")
            }
        } else if format == "png" { msg["currentPage"] = true }
        send(msg)
        // the editor's 30 s + this stay within the command's 60 s
        guard let r = await next("export", timeout: 25), case .string(let uri)? = r["data"] else {
            throw ProtocolError(code: .timeout, message: "a exportação não respondeu")
        }
        guard let data = Self.decodeDataURI(uri), !data.isEmpty else {
            throw ProtocolError(code: .internal, message: "exportação vazia ou grande demais (máximo \(Self.exportMaxBytes >> 20) MiB)")
        }
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
    /// Only on `DiagramFile.validate`d text (no DTD), and never loading an external entity besides.
    nonisolated static let xmlOptions: XMLNode.Options = [.nodeLoadExternalEntitiesNever]
    nonisolated static func pages(_ xml: String) -> [(id: String, name: String)] {
        guard let doc = try? XMLDocument(xmlString: xml, options: xmlOptions), let root = doc.rootElement(), root.name == "mxfile" else { return [] }
        return root.elements(forName: "diagram").map { ($0.attribute(forName: "id")?.stringValue ?? "", $0.attribute(forName: "name")?.stringValue ?? "") }
    }

    /// Adds the converted model's shapes to a page of `file` (`page` by name, else the one on screen): fresh ids, on the
    /// page's first layer, below what is already there. Returns the new document and how many cells were added.
    /// ponytail: compressed pages (draw.io's older default) are refused, not inflated; add raw-deflate decoding if one shows up.
    nonisolated static func insert(model: String, into file: String, page: String?, current: Int) throws(ProtocolError) -> (xml: String, cells: Int) {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard let src = try? XMLDocument(xmlString: model, options: xmlOptions), let srcRoot = src.rootElement()?.elements(forName: "root").first,
              let doc = try? XMLDocument(xmlString: file, options: xmlOptions), let top = doc.rootElement() else { throw bad("Mermaid não reconhecido: resultado inválido") }
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

    static let exportMaxBytes = 32 << 20
    /// nil when not a data URI or larger than `max` (checked on the text first: a huge payload is never decoded).
    static func decodeDataURI(_ uri: String, max: Int = exportMaxBytes) -> Data? {
        guard uri.utf8.count <= max / 3 * 4 + 1024, uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let head = uri[..<comma], body = String(uri[uri.index(after: comma)...])
        let d = head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        return d.flatMap { $0.count <= max ? $0 : nil }
    }
    static func pngSize(_ d: Data) -> (Double, Double) {
        guard d.count >= 24 else { return (0, 0) }
        let b = [UInt8](d.prefix(24))
        func be(_ i: Int) -> Double { Double(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])) }
        return (be(16), be(20))
    }
    /// From the `<svg>` tag's text: the export comes from the editor's frame, never parsed as XML here (R13).
    static func svgSize(_ d: Data) -> (Double, Double) {
        guard let s = String(data: d.prefix(64 << 10), encoding: .utf8), let tag = s.firstMatch(of: /<svg\b[^>]*>/)?.0 else { return (0, 0) }
        return (tag.firstMatch(of: /\swidth\s*=\s*["']([0-9.]+)/).flatMap { Double($0.1) } ?? 0,
                tag.firstMatch(of: /\sheight\s*=\s*["']([0-9.]+)/).flatMap { Double($0.1) } ?? 0)
    }
}
