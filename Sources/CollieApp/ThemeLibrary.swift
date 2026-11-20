import AppKit
import CollieTheme
import Foundation

/// The user's theme folder (`~/Library/Application Support/Collie/themes/`): lists it, watches it, and creates,
/// saves, imports, deletes and reveals theme files. Owned by the app, not the daemon. Applies nothing, knows no view.
@MainActor final class ThemeLibrary {
    enum LibraryError: Error, Equatable {
        case invalidId
        case noFreeId
        case writeFailed

        var message: String {
            switch self {
            case .invalidId: "nome de arquivo inválido"
            case .noFreeId: "não há nome livre"
            case .writeFailed: "não foi possível gravar o arquivo"
            }
        }
    }

    struct Entry: Equatable, Identifiable {
        enum State: Equatable { case ok(ThemeFile), broken(String) }
        let id: String
        let file: URL
        let state: State
        var theme: ThemeFile? { if case .ok(let t) = state { t } else { nil } }
        var problem: String? { if case .broken(let m) = state { m } else { nil } }
    }

    static let maxFiles = 200

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Collie/themes", isDirectory: true)
    }

    let folder: URL
    var onChange: @MainActor () -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(folder: URL = ThemeLibrary.defaultFolder, onChange: @escaping @MainActor () -> Void = {}) {
        self.folder = folder
        self.onChange = onChange
        startWatching()
    }

    isolated deinit { stopWatching() }

    // MARK: Listing

    /// Up to 200 `*.json` regular files (no folders, no symbolic links), read in name order; valid themes by name,
    /// broken ones last. A missing folder is an empty list.
    func reload() -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let files = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return v?.isSymbolicLink != true && v?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maxFiles)

        var good: [Entry] = [], broken: [Entry] = []
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", ThemeFile.validId(id) else {
                broken.append(Entry(id: id, file: url, state: .broken(LibraryError.invalidId.message)))
                continue
            }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > ThemeFile.maxBytes { throw ThemeError.tooLarge }
                good.append(Entry(id: id, file: url, state: .ok(try ThemeFile.parse(Data(contentsOf: url)))))
            } catch let e as ThemeError {
                broken.append(Entry(id: id, file: url, state: .broken(e.message)))
            } catch {
                broken.append(Entry(id: id, file: url, state: .broken("não foi possível ler o arquivo")))
            }
        }
        good.sort {
            let c = ($0.theme?.name ?? "").localizedCaseInsensitiveCompare($1.theme?.name ?? "")
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        broken.sort { $0.id < $1.id }
        return good + broken
    }

    // MARK: Operations

    /// A copy of `base` named `name`, in a free id.
    func create(from base: ThemeFile, name: String) throws -> String {
        var theme = base
        theme.name = name
        let id = try freeId(for: name)
        try write(theme.data, id: id)
        return id
    }

    func save(_ theme: ThemeFile, id: String) throws {
        guard ThemeFile.validId(id) else { throw LibraryError.invalidId }
        try write(theme.data, id: id)
    }

    /// Validates first; an invalid file never lands in the folder and the error carries the reason.
    func importFile(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > ThemeFile.maxBytes { throw ThemeError.tooLarge }
        let data = try Data(contentsOf: url)
        _ = try ThemeFile.parse(data)
        let id = try freeId(for: url.deletingPathExtension().lastPathComponent)
        try write(data, id: id)
        return id
    }

    func delete(id: String) throws {
        guard ThemeFile.validId(id) else { throw LibraryError.invalidId }
        try FileManager.default.trashItem(at: fileURL(id), resultingItemURL: nil)
    }

    /// The file in Finder; the folder itself without an id.
    func reveal(id: String? = nil) {
        if let id, ThemeFile.validId(id) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL(id)])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Files

    private func fileURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    /// Lowercase, anything but `a-z0-9` becomes `-`, edges trimmed, at most 48; `tema` if nothing is left.
    static func slug(_ name: String) -> String {
        let mapped = String(String.UnicodeScalarView(name.lowercased().unicodeScalars.map {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-"
        }))
        let trimmed = String(mapped.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "tema" : trimmed
    }

    private func freeId(for name: String) throws -> String {
        let base = Self.slug(name)
        if !exists(fileURL(base)) { return base }
        for n in 2...(Self.maxFiles + 1) {
            let suffix = "-\(n)"
            let head = String(base.prefix(48 - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let id = (head.isEmpty ? "tema" : head) + suffix
            if !exists(fileURL(id)) { return id }
        }
        throw LibraryError.noFreeId
    }

    /// lstat: a dangling symbolic link still takes the name.
    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Validated bytes into a temporary file in the same folder, then `rename` over the target.
    private func write(_ data: Data, id: String) throws {
        _ = try ThemeFile.parse(data)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = folder.appendingPathComponent(".\(id).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: [])
            guard rename(tmp.path, fileURL(id).path) == 0 else { throw LibraryError.writeFailed }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if dirSource == nil { startWatching() }
    }

    // MARK: Watching

    /// The folder (create, delete, rename) and each listed file (in-place edits), none followed through a link.
    /// A burst of events becomes one `onChange` (see `event`).
    private func startWatching() {
        if dirSource == nil {
            let fd = open(folder.path, O_EVTONLY | O_CLOEXEC)
            if fd >= 0 { dirSource = source(fd, [.write, .rename, .delete]) }
        }
        rearmFiles()
    }

    private func rearmFiles() {
        fileSources.forEach { $0.cancel() }
        fileSources = []
        guard dirSource != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted().prefix(Self.maxFiles) {
            let fd = open(folder.appendingPathComponent(name).path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { fileSources.append(source(fd, [.write, .extend, .delete, .rename])) }
        }
    }

    private func stopWatching() {
        pending?.cancel(); pending = nil
        dirSource?.cancel(); dirSource = nil
        fileSources.forEach { $0.cancel() }
        fileSources = []
    }

    private func source(_ fd: Int32, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.event() } }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        return src
    }

    /// Events of one burst (an editor's save is several) arrive before the main queue turns: one call for all of them,
    /// with no timer. A later event starts a new call.
    private func event() {
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.rearmFiles()
                self.onChange()
            }
        }
        pending = item
        DispatchQueue.main.async(execute: item)
    }
}
