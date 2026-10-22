import Foundation
import CollieCore
import CollieProtocol

/// A page Collie keeps: an HTML export of a design (one per file and node, versioned) or a page an agent handed in.
/// `folder` is relative to `<root>/artifacts`; the record describes the latest committed version. `page`: the page a
/// page export (no `node`) was read from (records from before it: nil, the daemon's client's current page).
struct Artifact: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case export, agent }
    var id: UUID; var kind: Kind; var title: String; var fileId: String?; var node: String?; var floorId: UUID?
    var by: String; var at: Date; var version: Int; var folder: String; var stamp: String?; var warnings: [String]
    var page: String? = nil
    /// The page the artifact came from, relative to `<root>/artifacts` (agents' records from before it: `<id>/source.html`).
    var source: String? = nil
    /// Why the last import of the page into a design failed.
    var importError: String? = nil
}

/// `<root>/artifacts/artifacts.json` (0600) and a folder per artifact: an export's versions in `<id>/v<N>/`, an
/// agent's page as `<id>/source.html` (0444). A version is reserved here (`newVersion`) and listed once committed: a
/// folder never committed is passed over. Removed artifacts move to `.removed/<id>-<epochMs>/`.
/// All disk work runs on one serial queue, off the cooperative pool.
actor ArtifactStore {
    /// `<root>/artifacts`.
    let dir: URL
    private var all: [Artifact]?   // loaded on first use
    /// Per artifact, the highest version handed out (committed or not); per (file, node), the id of an export not
    /// committed yet (its first versions share it).
    private var reserved: [UUID: Int] = [:]
    private var pending: [String: UUID] = [:]
    /// Legacy records (no page) reserved by a page export not yet committed, with that page: no other page adopts them.
    /// ponytail: a claim is cleared only on commit or a daemon restart; an abandoned export's claim keeps the legacy
    /// record for that same page until then (any later export of the page still adopts it).
    private var adopting: [UUID: String] = [:]
    /// Ids removed: an export of one still in flight is not recorded when it commits.
    /// ponytail: one UUID per removed artifact for the daemon's life; fine at this scale.
    private var removed: Set<UUID> = []
    /// Agent artifacts being converted to an export (until its commit or `setImportError`).
    private var converting: Set<UUID> = []
    private var saving = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let io = DispatchQueue(label: "collie.artifacts")

    init(root: URL) { dir = root.appendingPathComponent("artifacts") }

    private var registryFile: URL { dir.appendingPathComponent("artifacts.json") }
    private static func name(_ id: UUID) -> String { id.uuidString.lowercased() }

    func list() async throws -> [Artifact] { try await registry() }

    func get(_ id: UUID) async throws -> Artifact {
        guard let a = try await registry().first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "no artifact \(Self.name(id))")
        }
        return a
    }

    /// Reservation key of an export: its node, else (a whole page) its page.
    private static func key(_ fileId: String, node: String?, page: String?) -> String {
        fileId + "\u{0}" + (node.map { "n" + $0 } ?? "p" + (page ?? ""))
    }

    /// The next version of `(fileId, node ?? page)`'s export (a new artifact for a key not seen) and its new empty folder.
    /// A record from before pages (no node, no page) is adopted by the first page export, which then records its page.
    func newVersion(fileId: String, node: String?, page: String?, title: String, floorId: UUID?, by: String) async throws -> (Artifact, URL) {
        // one being removed (its record still listed while its folder moves) is not continued: a new artifact
        let all = try await registry().filter { $0.kind == .export && $0.fileId == fileId && $0.node == node && !removed.contains($0.id) }
        let known = node != nil ? all.first : all.first { $0.page == page } ?? (page != nil ? all.first { $0.page == nil && (adopting[$0.id] ?? page) == page } : nil)
        if let known, known.page == nil, let page { adopting[known.id] = page }
        let key = Self.key(fileId, node: node, page: page)
        let id = known?.id ?? pending[key].flatMap { removed.contains($0) ? nil : $0 } ?? UUID()
        if known == nil { pending[key] = id }
        let n = max(known?.version ?? 0, reserved[id] ?? 0) + 1
        reserved[id] = n
        let a = Artifact(id: id, kind: .export, title: title, fileId: fileId, node: node, floorId: floorId, by: by, at: Date(),
                         version: n, folder: "\(Self.name(id))/v\(n)", stamp: nil, warnings: [], page: page)
        let folder = dir.appendingPathComponent(a.folder)
        try await onIO {
            try? FileManager.default.removeItem(at: folder)   // an orphan of an earlier run, never committed
            try Self.mkdir(folder)
        }
        return (a, folder)
    }

    /// `a` (a version from `newVersion`, its files written) recorded; an older version than the one recorded is not,
    /// nor one of an artifact removed meanwhile (then false).
    @discardableResult
    func commit(_ a: Artifact) async throws -> Bool {
        var recorded = false
        try await update { list in
            guard !removed.contains(a.id) else { return }   // checked as the change runs: a remove may land while waiting
            recorded = true
            if let i = list.firstIndex(where: { $0.id == a.id }) {
                guard list[i].version <= a.version else { return }
                list[i] = a
            } else {
                list.append(a)
            }
        }
        converting.remove(a.id)
        adopting[a.id] = nil
        if let f = a.fileId {
            let k = Self.key(f, node: a.node, page: a.page)
            if pending[k] == a.id { pending[k] = nil }
        }
        return recorded
    }

    /// Whether `id` was removed (an export of it in flight is then dropped).
    func wasRemoved(_ id: UUID) -> Bool { removed.contains(id) }

    /// `page` (an HTML document) kept as a new agent artifact.
    func addAgent(page: Data, title: String, floorId: UUID?, by: String) async throws -> Artifact {
        let id = UUID()
        var a = Artifact(id: id, kind: .agent, title: title, fileId: nil, node: nil, floorId: floorId, by: by, at: Date(),
                         version: 1, folder: Self.name(id), stamp: nil, warnings: [])
        a.source = "\(a.folder)/source.html"
        let folder = dir.appendingPathComponent(a.folder)
        try await onIO {
            try Self.mkdir(folder)
            let dst = folder.appendingPathComponent("source.html")
            guard FileManager.default.createFile(atPath: dst.path, contents: page, attributes: [.posixPermissions: 0o444]) else {
                try? FileManager.default.removeItem(at: folder)
                throw ProtocolError(code: .internal, message: "artifacts: cannot write \(dst.path)")
            }
        }
        try await update { [a] in $0.append(a) }
        return a
    }

    /// The folder `root` kept as a new agent artifact (`<id>/source/`), `page` (inside it) its page. Only regular files of
    /// the allowed kinds are copied (never a link; hidden names skipped), up to `maxFiles` and `maxBytes`: past them
    /// (or `page` outside `root`, or not copied) nothing is created. Read and written on the io queue.
    func addAgent(root: URL, page: URL, title: String, floorId: UUID?, by: String) async throws -> Artifact {
        let id = UUID()
        // links in the paths themselves resolved (the page's own name is not: a linked page is not copied)
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let pageURL = page.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(page.lastPathComponent)
        let base = rootURL.path, pagePath = pageURL.path
        guard pagePath.hasPrefix(base + "/") else { throw Self.invalid("the page must be a regular file inside --root") }
        let pageRel = String(pagePath.dropFirst(base.count + 1))
        var a = Artifact(id: id, kind: .agent, title: title, fileId: nil, node: nil, floorId: floorId, by: by, at: Date(),
                         version: 1, folder: Self.name(id), stamp: nil, warnings: [])
        a.source = "\(a.folder)/source/\(pageRel)"
        let folder = dir.appendingPathComponent(a.folder), dst = folder.appendingPathComponent("source")
        try await onIO {
            let files = try Self.readTree(rootURL, page: pageRel)
            guard files.contains(where: { $0.rel == pageRel }) else { throw Self.invalid("the page must be a regular file inside --root") }
            do {
                try Self.mkdir(dst)
                var dirs: Set<String> = [dst.path]
                for (rel, data) in files {
                    let u = dst.appendingPathComponent(rel)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: u.path, contents: data, attributes: [.posixPermissions: 0o444]) else {
                        throw ProtocolError(code: .internal, message: "artifacts: cannot write \(u.path)")
                    }
                    var d = u.deletingLastPathComponent()
                    while d.path.count >= dst.path.count, dirs.insert(d.path).inserted { d = d.deletingLastPathComponent() }
                }
                // read-only at the end, deepest first
                for d in dirs.sorted(by: { $0.count > $1.count }) { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: d) }
            } catch { Self.purge(folder); throw error }
        }
        do { try await update { [a] in $0.append(a) } }
        catch { try? await onIO { Self.purge(folder) }; throw error }   // the copy of a record never made
        return a
    }

    /// `folder` deleted, its read-only folders made writable first.
    private static func purge(_ folder: URL) {
        for case let u as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    static let maxFiles = 2000, maxVisited = 20_000, maxPage = 8 << 20, maxBytes = 64 << 20
    private static let kinds: Set<String> = ["html", "htm", "css", "js", "mjs", "json", "png", "jpg", "jpeg", "gif", "webp", "avif",
                                             "svg", "ico", "woff", "woff2", "ttf", "otf"]
    private static func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    /// The files of `root` to copy as (path relative to it, contents): regular, no link followed, hidden names and
    /// other extensions skipped; each opened without following a link nor blocking, and read through that descriptor.
    private static func readTree(_ root: URL, page: String) throws -> [(rel: String, data: Data)] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw invalid("cannot read \(root.path)")
        }
        let top = root.resolvingSymlinksInPath().path
        var out: [(rel: String, data: Data)] = [], total = 0, visited = 0
        for case let u as URL in walk {
            visited += 1
            guard visited <= maxVisited else { throw invalid("'\(root.path)' has over \(maxVisited) entries") }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }   // the walk does not enter a linked folder
            guard v?.isRegularFile == true, kinds.contains(u.pathExtension.lowercased()) else { continue }
            let path = u.resolvingSymlinksInPath().path
            guard path.hasPrefix(top + "/") else { continue }
            guard out.count < maxFiles else { throw invalid("'\(root.path)' has over \(maxFiles) files to copy") }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }   // a link made meanwhile
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            let rel = String(path.dropFirst(top.count + 1))
            guard rel != page || Int(st.st_size) <= maxPage else { throw invalid("the page is over 8 MiB") }
            guard Int(st.st_size) <= maxBytes - total else { throw invalid("'\(root.path)' is over \(maxBytes >> 20) MiB to copy") }
            guard let d = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes - total + 1) ?? Data(),
                  d.count <= maxBytes - total else { throw invalid("'\(root.path)' is over \(maxBytes >> 20) MiB to copy") }
            total += d.count
            out.append((rel, d))
        }
        return out
    }

    /// Artifact `id`'s page (an agent's) to become the export of `fileId`/`node`: reserves `v1` under the same id and
    /// returns the record as `commit` is to keep it (an export; `source` kept) with the version's new folder. The
    /// record stays the agent's until that commit, so a failed export leaves it as it was.
    func convertToExport(_ id: UUID, fileId: String, node: String, page: String?) async throws -> (Artifact, URL) {
        var a = try await get(id)
        guard !removed.contains(id) else { throw ProtocolError(code: .notFound, message: "the artifact was removed meanwhile") }
        guard a.kind == .agent else { throw Self.invalid("artifact \(Self.name(id)) is not an agent's page") }
        guard converting.insert(id).inserted else { throw Self.invalid("import already in progress") }
        reserved[id] = 1
        a.source = a.source ?? "\(a.folder)/source.html"
        a.kind = .export; a.fileId = fileId; a.node = node; a.page = page; a.importError = nil
        a.version = 1; a.at = Date(); a.folder = "\(Self.name(id))/v1"
        let folder = dir.appendingPathComponent(a.folder)
        do {
            try await onIO {
                try? FileManager.default.removeItem(at: folder)
                try Self.mkdir(folder)
            }
        } catch { converting.remove(id); throw error }
        return (a, folder)
    }

    /// Why the last import of `id` failed (nil: cleared).
    func setImportError(_ id: UUID, _ message: String?) async throws {
        converting.remove(id)   // an import that fails ends its conversion
        _ = try await get(id)
        try await update { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i].importError = message } }
    }

    /// The artifact's folder set aside and its record gone.
    func remove(_ id: UUID) async throws {
        let a = try await get(id)
        removed.insert(id)   // before the move: exports finishing meanwhile are dropped, new ones get a new id
        let from = dir.appendingPathComponent(Self.name(a.id))
        let to = dir.appendingPathComponent(".removed/\(Self.name(a.id))-\(Int64(Date().timeIntervalSince1970 * 1000))")
        do {
            try await onIO {
                try Self.mkdir(to.deletingLastPathComponent())
                guard (try? FileManager.default.moveItem(at: from, to: to)) != nil || !FileManager.default.fileExists(atPath: from.path) else {
                    throw ProtocolError(code: .internal, message: "artifacts: cannot move \(from.path)")
                }
            }
        } catch { removed.remove(id); throw error }   // still there: its exports count again
        try await update { $0.removeAll { $0.id == id } }
    }

    // MARK: disk

    private func registry() async throws -> [Artifact] {
        if let all { return all }
        let file = registryFile
        let loaded = try await onIO { () throws -> [Artifact] in
            guard let d = FileManager.default.contents(atPath: file.path) else { return [] }
            guard let v = try? Self.decoder.decode([Artifact].self, from: d) else {
                throw ProtocolError(code: .internal, message: "artifacts: \(file.path) is unreadable")
            }
            return v
        }
        if all == nil { all = loaded }
        return all ?? loaded
    }

    /// The registry changed by `change`, written, then kept in memory; one change at a time (a later one waits, so
    /// none is lost while another is being written).
    private func update(_ change: (inout [Artifact]) -> Void) async throws {
        while saving { await withCheckedContinuation { waiters.append($0) } }
        saving = true
        defer { saving = false; if !waiters.isEmpty { waiters.removeFirst().resume() } }
        var list = try await registry()
        change(&list)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(list), file = registryFile
        try await onIO { try DesignService.writePrivate(data, to: file) }
        all = list
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func mkdir(_ u: URL) throws(ProtocolError) {
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ProtocolError(code: .internal, message: "artifacts: cannot create \(u.path)") }
    }

    /// `body` on the serial queue; enqueued before this returns to the actor, so calls run in the order made.
    private func onIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await withCheckedThrowingContinuation { c in io.async { c.resume(with: Result { try body() }) } }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }
}
