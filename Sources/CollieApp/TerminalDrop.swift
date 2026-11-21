import AppKit

/// Dropping files or an image on a terminal pastes their paths, shell-escaped (what Terminal.app types). Agents
/// (Claude Code, Codex, Cursor) attach an image whose path is pasted; a shell gets a usable argument.
@MainActor
enum TerminalDrop {
    static var types: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Where an image with no file of its own (dragged from a browser, Photos, a screenshot thumbnail) is written.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("collie-drops", isDirectory: true) }

    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-+@%:,=")

    /// `/a/Captura de Tela.png` → `/a/Captura\ de\ Tela.png`: a backslash before every character outside a safe set.
    static func escape(_ path: String) -> String {
        var out = ""
        for c in path { if !safe.contains(c) { out.append("\\") }; out.append(c) }
        return out
    }

    /// The paths separated by spaces, with a trailing space (so the next word doesn't stick to the last path).
    static func text(for urls: [URL]) -> String? {
        urls.isEmpty ? nil : urls.map { escape($0.path) }.joined(separator: " ") + " "
    }

    static func accepts(_ pb: NSPasteboard) -> Bool { pb.availableType(from: types) != nil }

    /// Resolves the drop to files and calls `paste` with their text on the main thread. File URLs as they are; file
    /// promises received into `folder`; bare image data written there as PNG. False: nothing usable in the drop.
    static func receive(_ pb: NSPasteboard, paste: @escaping @MainActor (String) -> Void) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let text = text(for: urls) {
            paste(text); return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty,
           let dir = try? makeFolder() {
            for p in promises {
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { if let text = text(for: [url]) { paste(text) } }
                }
            }
            return true
        }
        if let url = writeImage(from: pb), let text = text(for: [url]) { paste(text); return true }
        return false
    }

    /// The pasteboard's image as a PNG in `folder`; nil when there is no image or it can't be written.
    static func writeImage(from pb: NSPasteboard, in dir: URL? = nil) -> URL? {
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let dir = try? (dir.map { d -> URL in try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d } ?? makeFolder())
        else { return nil }
        let url = dir.appendingPathComponent("imagem-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url, options: .atomic)) == nil ? nil : url
    }

    private static func makeFolder() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
