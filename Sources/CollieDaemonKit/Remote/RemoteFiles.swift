import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// `artifact.file` (remote API spec §3.9): the files a phone's `WKWebView` asks its scheme handler for —
/// `collie-artifact://<id>/<path>` (an artifact's own files) and `collie-lib://lib|fonts/…` (the offline libraries and
/// fonts pages reference) — chunked, confined, and served as the app's handlers serve them.
extension CommandRouter {
    static let fileChunk = 512 << 10, fileMax = 8 << 20
    static let fileTypes = ["html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "css": "text/css",
                            "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8", "json": "application/json",
                            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                            "svg": "image/svg+xml", "ico": "image/x-icon", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf",
                            "otf": "font/otf", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8", "mp4": "video/mp4",
                            "webm": "video/webm", "mp3": "audio/mpeg", "pdf": "application/pdf"]

    /// args `{url, offset? (default 0), etag? (the first chunk's)}` → `{mime, size, offset, d, done, etag}`.
    func remoteFile(_ r: Request, device: RemoteDevice) async throws -> JSONValue {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let gone = ProtocolError(code: .notFound, message: "Arquivo não encontrado.")
        guard let raw = str(r, "url"), let u = URLComponents(string: raw), let host = u.host?.lowercased() else { throw bad("url: collie-artifact://<id>/<caminho> ou collie-lib://…") }
        var offset = 0
        if let v = r.args["offset"] {
            guard case .number(let n) = v, n >= 0, n == n.rounded(), n <= Double(Self.fileMax) else { throw bad("offset: um inteiro de 0 a 8 MiB") }
            offset = Int(n)
        }
        // `path` is percent-decoded: `%2e%2e` is `..` here. No dot entry anywhere (`..`, `.removed/`, hidden files).
        let parts = u.path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0.hasPrefix(".") }) else { throw bad("Caminho fora do permitido.") }

        let file: (data: Data, mime: String, etag: String)
        switch u.scheme?.lowercased() {
        case "collie-artifact":
            guard let id = UUID(uuidString: host), let a = try await artifacts.list().first(where: { $0.id == id }) else { throw gone }
            guard !parts.isEmpty else { throw bad("Falta o caminho do arquivo no artifact.") }
            let base = (await artifacts.dir).appendingPathComponent(a.folder).resolvingSymlinksInPath()
            // resolved, links included: a link that leads out of the artifact's folder is refused, not followed
            let f = base.appendingPathComponent(parts.joined(separator: "/")).resolvingSymlinksInPath()
            guard f.path.hasPrefix(base.path + "/") else { throw bad("Caminho fora do artifact.") }
            guard let (d, mtime) = try Self.regular(f) else { throw gone }
            file = (d, Self.fileTypes[f.pathExtension.lowercased()] ?? "application/octet-stream", "\(a.version)-\(mtime)-\(d.count)")
        case WebLibs.scheme where host == "lib":
            guard let dir = config.weblibsDir?.resolvingSymlinksInPath() else { throw gone }
            let key = parts.joined(separator: "/")
            // only the files the manifest lists, looked up by exact key (as the app's handler)
            guard WebLibs.manifest(in: dir).contains(where: { e in e.files.contains { "\(e.name)@\(e.version)/\($0)" == key } }) else { throw gone }
            let f = dir.appendingPathComponent(key)
            guard f.resolvingSymlinksInPath().path.hasPrefix(dir.path + "/"), let (d, mtime) = try Self.regular(f, noLink: true) else { throw gone }
            file = (d, "text/javascript; charset=utf-8", "\(mtime)-\(d.count)")
        case WebLibs.scheme where host == "fonts":
            if parts == ["css"] {
                let asked = Fonts.requests(u.queryItems ?? [])
                let css = Data(Fonts.css(asked.compactMap { a in fontFamily(a.family).map { ($0.0, a.weights) } }).utf8)
                file = (css, "text/css; charset=utf-8", SHA256.hash(data: css).prefix(8).map { String(format: "%02x", $0) }.joined())
            } else {
                guard parts.count == 2, let (fam, folder) = fontFamily(parts[0]), fam.faces.contains(where: { $0.file == parts[1] }) else { throw gone }
                let f = folder.appendingPathComponent(parts[1])
                guard f.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
                      let (d, mtime) = try Self.regular(f, noLink: true) else { throw gone }
                file = (d, Self.fileTypes[f.pathExtension.lowercased()] ?? "font/ttf", "\(mtime)-\(d.count)")
            }
        default:
            throw bad("url: collie-artifact://<id>/<caminho> ou collie-lib://lib|fonts/…")
        }

        if let e = str(r, "etag"), e != file.etag {
            throw ProtocolError(code: .conflict, message: "O arquivo mudou entre as partes: comece de novo.")
        }
        let size = file.data.count
        guard offset < size || offset == 0 else { throw bad("offset além do fim do arquivo (\(size) bytes).") }
        let end = min(size, offset + Self.fileChunk)
        if let wait = remoteLimits.takeBytes(device.id, end - offset) {
            throw ProtocolError(code: .tooMany, message: "Muitos arquivos de uma vez: tente de novo em instantes.", retryAfter: (wait * 10).rounded(.up) / 10)
        }
        return .object(["mime": .string(file.mime), "size": .number(Double(size)), "offset": .number(Double(offset)),
                        "d": .string(file.data[offset..<end].base64EncodedString()), "done": .bool(end >= size), "etag": .string(file.etag)])
    }

    /// A downloaded family (a real folder, not a link) in `<root>/fonts`, else a bundled one with the faces present.
    private func fontFamily(_ name: String) -> (FontFamily, URL)? {
        guard Fonts.validFamily(name) else { return nil }
        let downloaded = config.paths.root.appendingPathComponent("fonts")
        let folder = downloaded.appendingPathComponent(name)
        if (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory,
           let f = Fonts.downloaded(name, in: downloaded) { return (f, folder) }
        guard let b = config.bundledFontsDir, var f = Fonts.bundled.first(where: { $0.family == name }) else { return nil }
        f.faces = f.faces.filter { FileManager.default.fileExists(atPath: b.appendingPathComponent($0.file).path) }
        return f.faces.isEmpty ? nil : (f, b)
    }

    /// `f`'s bytes and mtime (ms) when it is a regular file (`noLink`: not itself a link) of at most `fileMax`; nil when
    /// missing or not a file. Over the cap: `invalidArgs`.
    private static func regular(_ f: URL, noLink: Bool = false) throws -> (Data, Int)? {
        let attrs = noLink ? try? FileManager.default.attributesOfItem(atPath: f.path)
                           : try? FileManager.default.attributesOfItem(atPath: f.resolvingSymlinksInPath().path)
        guard let attrs, attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard (attrs[.size] as? Int ?? 0) <= fileMax else {
            throw ProtocolError(code: .invalidArgs, message: "Arquivo maior que 8 MiB: abra no Mac.")
        }
        guard let d = try? Data(contentsOf: f) else { return nil }
        return (d, Int(((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000))
    }
}
