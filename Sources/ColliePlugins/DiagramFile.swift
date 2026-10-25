import Foundation
import CollieProtocol

/// The Diagram panel's document: a `.drawio` file inside the panel's project (`state["root"]`), at most 8 MiB.
/// Pure helpers: where it is, whether its XML is a draw.io document, reading and writing it, the conflict rule.
public enum DiagramFile {
    public static let maxBytes = 8 << 20
    /// An empty one-page draw.io document (what a missing file starts as).
    public static let empty = #"<mxfile><diagram id="p1" name="Página-1"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/></root></mxGraphModel></diagram></mxfile>"#

    static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    /// `requested` (relative to `projectRoot`, or absolute) or `docs/diagrams/<panelName>.drawio`; symlinks resolved, and the
    /// result must lie inside the project and end in `.drawio`.
    public static func resolve(_ requested: String?, panelName: String, projectRoot: URL) throws(ProtocolError) -> URL {
        let r = requested?.trimmingCharacters(in: .whitespaces) ?? ""
        let path = r.isEmpty ? "docs/diagrams/\(panelName).drawio" : r
        let root = real(projectRoot)
        let url = real(path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
        guard url.pathExtension.lowercased() == "drawio", !path.hasSuffix("/") else { throw bad("o diagrama precisa ser um arquivo .drawio: \(path)") }
        guard url.pathComponents.count > root.pathComponents.count, url.pathComponents.starts(with: root.pathComponents) else {
            throw bad("o diagrama precisa ficar dentro do projeto \(root.path): \(path)")
        }
        return url
    }

    /// Symlinks resolved through the deepest existing ancestor (a missing tail is kept as is); `..` removed.
    static func real(_ u: URL) -> URL {
        var head = u.standardizedFileURL, tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.pathComponents.count > 1 {
            tail.insert(head.lastPathComponent, at: 0); head = head.deletingLastPathComponent()
        }
        guard let rp = realpath(head.path, nil) else { return u.standardizedFileURL }
        defer { free(rp) }
        return tail.reduce(URL(fileURLWithPath: String(cString: rp))) { $0.appendingPathComponent($1) }
    }

    /// Well-formed XML whose root is `mxfile` or `mxGraphModel`, within the size limit; the error names the line.
    public static func validate(xml: String) throws(ProtocolError) {
        let data = Data(xml.utf8)
        guard data.count <= maxBytes else { throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB)") }
        let p = XMLParser(data: data), root = RootName()
        p.delegate = root
        guard p.parse() else {
            throw bad("XML inválido (linha \(p.lineNumber)): \(p.parserError?.localizedDescription ?? "erro de sintaxe")")
        }
        guard root.name == "mxfile" || root.name == "mxGraphModel" else {
            throw bad("não é um diagrama draw.io: a raiz é <\(root.name ?? "")>, esperado <mxfile>")
        }
    }
    private final class RootName: NSObject, XMLParserDelegate {
        var name: String?
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == nil { name = e }
        }
    }

    public static func read(_ url: URL) throws(ProtocolError) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB)") }
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { throw ProtocolError(code: .internal, message: "não consegui ler \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    /// Atomic (temp file + rename), creating the folders.
    public static func write(_ xml: String, to url: URL) throws(ProtocolError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: url, options: .atomic)
        } catch { throw ProtocolError(code: .internal, message: "não consegui gravar \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    /// An agent's version may replace the document only when the user made no edit in the last 2 s.
    public static func mayOverwrite(lastUserEditAt: Date?, now: Date) -> Bool {
        guard let t = lastUserEditAt else { return true }
        return now.timeIntervalSince(t) >= 2
    }
}
