import Foundation
import CollieProtocol

/// The Prévia's rules (plug-in `preview`): the page it shows is an `.html`/`.htm` file inside the panel's project, and
/// the files it serves (the page and what it links) are under the project root, never through a symlink out, never a
/// dot-path (`.env`, `.git/`, `.collie/`). Pages are agent-written: untrusted. Reads go through `DiagramFile.readData`
/// (no-follow from the root, regular file, ≤ 8 MiB).
public enum PreviewFile {
    static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    /// `requested` (relative to `projectRoot`, or absolute); symlinks resolved, inside the project, `.html`/`.htm`, ≤ 8 MiB.
    public static func resolve(_ requested: String, projectRoot: URL) throws(ProtocolError) -> URL {
        let path = requested.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw bad("informe a página (--file)") }
        let root = DiagramFile.real(projectRoot)
        let url = DiagramFile.real(path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
        guard ["html", "htm"].contains(url.pathExtension.lowercased()), !path.hasSuffix("/") else {
            throw bad("a página precisa ser um arquivo .html: \(path)")
        }
        guard url.pathComponents.count > root.pathComponents.count, url.pathComponents.starts(with: root.pathComponents) else {
            throw bad("a página precisa ficar dentro do projeto \(root.path): \(path)")
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > DiagramFile.maxBytes {
            throw bad("página grande demais (máximo \(DiagramFile.maxBytes >> 20) MiB): \(path)")
        }
        return url
    }

    /// The file a `collie-preview://app/<urlPath>` request names (`urlPath` still percent-encoded), or nil: `..`, any
    /// component starting with `.`, or a path that (links resolved) leaves the root or lands on a dot-path.
    public static func servable(_ urlPath: String, projectRoot: URL) -> URL? {
        guard let decoded = urlPath.removingPercentEncoding, !decoded.contains("\0") else { return nil }
        let comps = decoded.split(separator: "/").map(String.init)
        guard !comps.isEmpty, !comps.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let root = DiagramFile.real(projectRoot)
        let url = DiagramFile.real(comps.reduce(root) { $0.appendingPathComponent($1) })
        let r = root.pathComponents, u = url.pathComponents
        guard u.count > r.count, u.starts(with: r), !u.dropFirst(r.count).contains(where: { $0.hasPrefix(".") }) else { return nil }
        return url
    }

    static let types = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8", "json": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "txt": "text/plain; charset=utf-8",
    ]
    public static func contentType(_ ext: String) -> String { types[ext.lowercased()] ?? "application/octet-stream" }
}
