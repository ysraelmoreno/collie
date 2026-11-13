import CoreGraphics
import Foundation
import CollieCore
import CollieProtocol
import WebKit

/// `deck.snapshot` / `deck.pdf` for the daemon's deck export (`HostTarget.importer`, like `html.snapshot`): an artifact
/// deck (`.slide`, else `[data-slide]`) rendered in `HTMLSnapshotter`'s offline web view. Results go to
/// `<artifactsRoot>/<id>/.export/` (0700, never through a symlink); replies carry names only. The daemon keeps its
/// `deck.pptx` / `deck.pdf` there too, so each command clears only its own earlier files (`clear`).
/// - `deck.snapshot {id, url, width?}` → `slides.json` (deck-mode snapshot, payloads in `img-N.png` / `svg-N.svg`);
///   reply `{file, slides, blocked, truncated}`.
/// - `deck.pdf {id, url}` → `deck-app.pdf`, one page per slide at 0.75 pt per CSS px (1280×720 → 960×540), vector text;
///   reply `{file, slides}`.
@MainActor public enum DeckExporter {
    nonisolated static let exportDir = ".export"

    public static func handle(command: String, args: [String: JSONValue], artifactsRoot: URL,
                              timeoutSeconds: Double) async throws(ProtocolError) -> JSONValue {
        guard command == "deck.snapshot" || command == "deck.pdf" else {
            throw ProtocolError(code: .invalidArgs, message: "unknown command: \(command)")
        }
        guard case .string(let rawId)? = args["id"], let id = UUID(uuidString: rawId) else {
            throw ProtocolError(code: .invalidArgs, message: "id must be an artifact id")
        }
        guard case .string(let raw)? = args["url"], let url = URL(string: raw),
              url.scheme?.lowercased() == BrowserPanel.artifactScheme, url.host == "app" else {
            throw ProtocolError(code: .invalidArgs, message: "url must be collie-artifact://app/…")
        }
        var width = 1440
        if let w = args["width"] {
            guard case .number(let n) = w, n.rounded() == n, (320...3840).contains(n) else {
                throw ProtocolError(code: .invalidArgs, message: "width must be an integer in 320…3840")
            }
            width = Int(n)
        }
        let out = try HTMLSnapshotter.importFolder(artifactsRoot, id, exportDir)
        let timeout = Duration.milliseconds(Int(max(5, timeoutSeconds - 2) * 1000))
        let end = ContinuousClock.now + timeout
        do throws(ProtocolError) {
            if command == "deck.snapshot" {
                let snap = try await HTMLSnapshotter.snapshot(url: url, artifactsRoot: artifactsRoot, width: width, timeout: timeout, deck: true)
                return try await BrowserAutomation.offMain { () -> Result<JSONValue, ProtocolError> in
                    if let e = clear(out, own: { n in n == "slides.json" || (n.hasPrefix("img-") && n.hasSuffix(".png"))
                                                      || (n.hasPrefix("svg-") && n.hasSuffix(".svg")) }) { return .failure(e) }
                    return HTMLSnapshotter.store(snap, in: out, file: "slides.json", replace: false)
                }.get()
            }
            let pages = try await slidePDFs(url: url, artifactsRoot: artifactsRoot, width: width, timeout: timeout, end: end)
            return try await BrowserAutomation.offMain { write(pages, to: out) }.get()
        } catch where error.message.hasSuffix("no slides") {
            throw ProtocolError(code: .invalidArgs, message: "page has no slides")
        }
    }

    /// One single-page PDF per slide (CSS px = pt), each slide isolated as in the deck snapshot.
    static func slidePDFs(url: URL, artifactsRoot: URL, width: Int, timeout: Duration,
                          end: ContinuousClock.Instant) async throws(ProtocolError) -> [Data] {
        // ready = loaded, fonts in, 300 ms settle (as the snapshot script)
        let ready = HTMLSnapshotScript.wrap(#"await document.fonts.ready; await new Promise(r => setTimeout(r, 300)); return "ready";"#)
        return try await HTMLSnapshotter.withPage(url: url, artifactsRoot: artifactsRoot, width: width, timeout: timeout,
                                                  libs: WebLibs.directory, script: ready) { web, _ throws(ProtocolError) in
            try await race(until: end, "deck.pdf timed out after \(timeout)") { () throws(ProtocolError) in
                var pages: [Data] = [], count = 1, i = 0
                while i < count {
                    let box: [String: Any]
                    do {
                        box = try await web.callAsyncJavaScript(HTMLSnapshotScript.isolateSlide(i), contentWorld: .defaultClient) as? [String: Any] ?? [:]
                    } catch { throw ProtocolError(code: .internal, message: "deck.pdf: slide \(i + 1): \(error.localizedDescription)") }
                    count = (box["count"] as? NSNumber)?.intValue ?? 0
                    guard count > 0 else { throw ProtocolError(code: .invalidArgs, message: "no slides") }
                    let n = { (k: String) in CGFloat((box[k] as? NSNumber)?.doubleValue ?? 0) }
                    let pdf = WKPDFConfiguration()
                    pdf.rect = CGRect(x: n("x"), y: n("y"), width: max(1, n("w")), height: max(1, n("h")))
                    do { pages.append(try await web.pdf(configuration: pdf)) } catch {
                        throw ProtocolError(code: .internal, message: "deck.pdf: slide \(i + 1): \(error.localizedDescription)")
                    }
                    i += 1
                }
                return pages
            }
        }
    }

    /// `work`'s result, or `.timeout` at `end`, whichever is first. On timeout `work` is left running (WebKit calls
    /// cannot be cancelled); the caller then releases the view it uses.
    static func race<T: Sendable>(until end: ContinuousClock.Instant, _ message: String,
                                  _ work: @escaping @MainActor () async throws(ProtocolError) -> T) async throws(ProtocolError) -> T {
        let once = RaceOnce<T>()
        let r: Result<T, ProtocolError> = await withCheckedContinuation { c in
            once.c = c
            once.timer = Task { @MainActor in
                guard (try? await Task.sleep(until: end)) != nil else { return }
                once.finish(.failure(ProtocolError(code: .timeout, message: message)))
            }
            Task { @MainActor in
                do throws(ProtocolError) { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) }
            }
        }
        return try r.get()
    }

    /// Makes `dir` a real 0700 folder (a symlink there, dangling or not, is removed, never followed) and deletes the
    /// entries `own` claims.
    nonisolated static func clear(_ dir: URL, own: (String) -> Bool) -> ProtocolError? {
        let fm = FileManager.default
        do {
            if (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil { try fm.removeItem(at: dir) }
            if fm.fileExists(atPath: dir.path) { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            else { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            for name in try fm.contentsOfDirectory(atPath: dir.path) where own(name) { try fm.removeItem(at: dir.appendingPathComponent(name)) }
        } catch {
            return ProtocolError(code: .internal, message: "deck export: could not prepare \(exportDir): \(error.localizedDescription)")
        }
        return nil
    }

    /// Merges the slide PDFs into `deck-app.pdf` in `dir` (other files kept), each page drawn at 0.75 (vector, text kept).
    nonisolated static func write(_ pages: [Data], to dir: URL) -> Result<JSONValue, ProtocolError> {
        let merged = NSMutableData()
        guard let consumer = CGDataConsumer(data: merged), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return .failure(ProtocolError(code: .internal, message: "deck.pdf: no PDF context"))
        }
        for data in pages {
            guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else {
                return .failure(ProtocolError(code: .internal, message: "deck.pdf: WebKit returned a bad PDF"))
            }
            let src = page.getBoxRect(.mediaBox)
            var box = CGRect(x: 0, y: 0, width: src.width * 0.75, height: src.height * 0.75)
            ctx.beginPage(mediaBox: &box)
            ctx.scaleBy(x: 0.75, y: 0.75)
            ctx.translateBy(x: -src.minX, y: -src.minY)
            ctx.drawPDFPage(page)
            ctx.endPage()
        }
        ctx.closePDF()
        do {
            if let e = clear(dir, own: { $0 == "deck-app.pdf" }) { return .failure(e) }
            try (merged as Data).write(to: dir.appendingPathComponent("deck-app.pdf"))
        } catch {
            return .failure(ProtocolError(code: .internal, message: "deck.pdf: could not write the PDF: \(error.localizedDescription)"))
        }
        return .success(.object(["file": .string("\(exportDir)/deck-app.pdf"), "slides": .number(Double(pages.count))]))
    }
}

/// `DeckExporter.race`'s continuation, resumed by whichever of work / deadline comes first.
@MainActor private final class RaceOnce<T: Sendable> {
    var c: CheckedContinuation<Result<T, ProtocolError>, Never>?
    var timer: Task<Void, Never>?
    func finish(_ r: Result<T, ProtocolError>) { c?.resume(returning: r); c = nil; timer?.cancel() }
}
