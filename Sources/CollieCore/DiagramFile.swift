import Foundation
import CollieProtocol

/// The Diagram panel's document: a `.drawio` file inside the panel's project (`state["root"]`), at most 8 MiB.
/// Shared by the daemon (`panel.open` refuses a bad file) and the app (the panel checks again). Pure helpers: where it is, whether its XML is a draw.io document, reading and writing it, the conflict rule.
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
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB): \(path)")
        }
        return url
    }

    /// Symlinks resolved through the deepest existing ancestor (a missing tail is kept as is); `..` removed.
    public static func real(_ u: URL) -> URL {
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

    // MARK: no-follow file access (R12)
    // Every read and write walks from the project root with `openat(O_NOFOLLOW)` one folder at a time: a folder swapped for
    // a symlink after the panel opened is refused, never followed out of the project. The file itself is opened
    // O_NOFOLLOW|O_NONBLOCK and must be a regular file of at most 8 MiB (a FIFO or a link to /dev/zero fails at once).

    static func posix(_ what: String) -> ProtocolError {
        let e = errno
        if e == ELOOP || e == ENOTDIR || e == EMLINK {
            return bad("\(what): o caminho do diagrama passa por um link ou por algo que não é pasta")
        }
        return ProtocolError(code: .internal, message: "\(what): \(String(cString: strerror(e)))")
    }

    /// The folders below the root and the file name of `url` (already `resolve`d inside `root`).
    static func parts(_ url: URL, _ root: URL) throws(ProtocolError) -> (dirs: [String], name: String) {
        let r = real(root).pathComponents, u = url.pathComponents
        guard u.count > r.count, u.starts(with: r) else { throw bad("o diagrama precisa ficar dentro do projeto \(real(root).path)") }
        let rel = Array(u.dropFirst(r.count))
        guard !rel.contains(where: { $0 == ".." || $0 == "." }) else { throw bad("caminho inválido: \(url.path)") }
        return (Array(rel.dropLast()), rel.last!)
    }

    /// The file's folder, opened from the project root without following any link; `create` makes missing folders.
    /// nil: a folder is missing (and `create` is false). The caller closes the fd.
    public static func openDirectory(of url: URL, root: URL, create: Bool) throws(ProtocolError) -> Int32? {
        let (dirs, _) = try parts(url, root)
        var fd = open(real(root).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix("pasta do projeto") }
        for d in dirs {
            var next = openat(fd, d, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, !create { close(fd); return nil }
            if next < 0, errno == ENOENT, create {
                if mkdirat(fd, d, 0o755) != 0, errno != EEXIST { let e = posix(d); close(fd); throw e }
                next = openat(fd, d, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let e = next < 0 ? posix(d) : nil
            close(fd)
            if let e { throw e }
            fd = next
        }
        return fd
    }

    /// The file's text; nil when it does not exist (its folders included).
    public static func read(_ url: URL, root: URL) throws(ProtocolError) -> String? {
        guard let dir = try openDirectory(of: url, root: root, create: false) else { return nil }
        defer { close(dir) }
        let fd = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw posix(url.lastPathComponent) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posix(url.lastPathComponent) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw bad("\(url.lastPathComponent) não é um arquivo comum") }
        guard st.st_size <= maxBytes else { throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB)") }
        var data = Data(), buf = [UInt8](repeating: 0, count: 64 << 10)
        while data.count <= maxBytes {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw posix(url.lastPathComponent) }
            if n == 0 { break }
            data.append(buf, count: n)
        }
        guard data.count <= maxBytes else { throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB)") }
        guard let s = String(data: data, encoding: .utf8) else { throw bad("\(url.lastPathComponent) não é UTF-8") }
        return s
    }

    /// Atomic: a temp file in the same folder fd, then `renameat` over the name (a link at the name is replaced, not
    /// followed). Creates missing folders, refuses more than 8 MiB.
    public static func write(_ xml: String, to url: URL, root: URL) throws(ProtocolError) {
        let data = Data(xml.utf8)
        guard data.count <= maxBytes else { throw bad("diagrama grande demais (máximo \(maxBytes >> 20) MiB)") }
        guard let dir = try openDirectory(of: url, root: root, create: true) else { throw bad("pasta do diagrama ausente") }
        defer { close(dir) }
        let name = url.lastPathComponent, tmp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posix(name) }
        var off = 0, failed: ProtocolError?
        data.withUnsafeBytes { p in
            while off < data.count {
                let n = Darwin.write(fd, p.baseAddress! + off, data.count - off)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { failed = posix(name); return }
                off += n
            }
        }
        close(fd)
        if failed == nil, renameat(dir, tmp, dir, name) != 0 { failed = posix(name) }
        if let failed { unlinkat(dir, tmp, 0); throw failed }
    }

    /// An agent's version may replace the document only when the user made no edit in the last 2 s.
    public static func mayOverwrite(lastUserEditAt: Date?, now: Date) -> Bool {
        guard let t = lastUserEditAt else { return true }
        return now.timeIntervalSince(t) >= 2
    }
}
