import CollieCore
import Foundation

/// Watches one project file for the Diagram and Prévia panels: its folder (atomic writes: a rename; delete and
/// re-create) and the file itself (in-place writes: `echo >`, editors' Write tools), both opened from the project root
/// without following any link. The file source is re-armed after each event (a rename replaced its inode); a burst
/// of events is coalesced into one `onChange`, 150 ms after the last (well within the panels' 1 s budget).
@MainActor final class FileWatch {
    let file: URL, root: URL
    private let onChange: @MainActor () -> Void
    private var dirSource: DispatchSourceFileSystemObject?, fileSource: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var stopped = false

    init(file: URL, root: URL, onChange: @escaping @MainActor () -> Void) {
        self.file = file; self.root = root; self.onChange = onChange
        if let d = try? DiagramFile.openDirectory(of: file, root: root, create: false) { dirSource = source(d, [.write, .rename, .delete]) }
        rearm()
    }

    /// A fresh source on the file's current inode (after the owner's own atomic write, or when it was re-created).
    func rearm() {
        fileSource?.cancel(); fileSource = nil
        guard !stopped, let d = try? DiagramFile.openDirectory(of: file, root: root, create: false) else { return }
        let fd = openat(d, file.lastPathComponent, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        Darwin.close(d)
        guard fd >= 0 else { return }
        fileSource = source(fd, [.write, .extend, .delete, .rename, .attrib])
    }

    func stop() {
        stopped = true
        dirSource?.cancel(); dirSource = nil; fileSource?.cancel(); fileSource = nil
        pending?.cancel(); pending = nil
    }

    private func source(_ fd: Int32, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.event() } }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        return src
    }

    private func event() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.rearm()
            self.onChange()
        }
    }
}
