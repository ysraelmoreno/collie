import Foundation
import PDFKit

/// Text and chunks of a reference document (md, txt, pdf) for `memory.doc-add`.
enum DocIngest {
    static let maxBytes = 20 << 20, chunkMax = 2500, extensions: Set<String> = ["md", "markdown", "txt", "pdf"]

    /// The file's text. Throws a message for an unsupported, too large, non-regular (symlink included) or unreadable file.
    static func extract(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw Failure("unsupported file type '.\(ext)' (md, txt, pdf)") }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Failure("not a regular file: \(url.path)") }
        guard st.st_size <= maxBytes else { throw Failure("file over \(maxBytes >> 20) MB") }
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), let t = pdf.string, !t.isEmpty else { throw Failure("PDF has no text (scanned? OCR is not supported)") }
            return t
        }
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { throw Failure("not UTF-8 text") }
        return t
    }

    /// Pieces of ≤ `chunkMax` characters, each under the nearest markdown heading above it: whole paragraphs are packed
    /// together; a heading starts a new piece; a paragraph longer than the limit is cut hard.
    static func chunk(_ text: String) -> [(heading: String, body: String)] {
        var out: [(String, String)] = [], heading = "", cur = ""
        func flush() { let b = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !b.isEmpty { out.append((heading, b)) }; cur = "" }
        for para in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if p.hasPrefix("#") {
                flush()
                heading = (p.components(separatedBy: "\n").first ?? "").drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            var rest = Substring(p)
            while rest.count > chunkMax {
                flush(); cur = String(rest.prefix(chunkMax)); flush(); rest = rest.dropFirst(chunkMax)
            }
            if cur.count + rest.count + 2 > chunkMax { flush() }
            cur += (cur.isEmpty ? "" : "\n\n") + rest
        }
        flush()
        return out
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }
}
