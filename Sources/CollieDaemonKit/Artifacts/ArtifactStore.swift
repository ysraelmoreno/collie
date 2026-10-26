import Foundation
import CollieCore
import CollieProtocol

/// A page Collie keeps: an HTML export of a design (one per file and node, versioned) or a page an agent handed in.
/// `folder` is relative to `<root>/artifacts`; the record describes the latest committed version. `page`: the page a
/// page export (no `node`) was read from (records from before it: nil, the daemon's client's current page).
struct Artifact: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case export, agent }
    var id: UUID; var kind: Kind; var title: String; var fileId: String?; var node: String?; var paddockId: UUID?
    var by: String; var at: Date; var version: Int; var folder: String; var stamp: String?; var warnings: [String]
    var page: String? = nil
    /// The page the artifact came from, relative to `<root>/artifacts` (agents' records from before it: `<id>/source.html`).
    var source: String? = nil
    /// Why the last import of the page into a design failed.
    var importError: String? = nil
    /// The user folder it is kept in (`ArtifactFolder`; nil: "Sem pasta"), and the terminal that handed it in (nil: the app,
    /// or a record from before it): only that terminal (or the app) moves it.
    var inFolder: String? = nil
    var byId: UUID? = nil
    /// The claude.ai link it was imported from (`artifact add --source`): adding that link again is its next version.
    var origin: String? = nil
    /// Remote resources the page still loads after the offline rewrite ("precisa de rede"); nil: none.
    var needsNetwork: [String]? = nil
}

extension Artifact {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, fileId, node, paddockId, by, at, version, folder, stamp, warnings, page, source, importError, inFolder, byId,
             origin, needsNetwork
    }
    private enum Legacy: String, CodingKey { case floorId }   // before the herding vocabulary
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(Kind.self, forKey: .kind); title = try c.decode(String.self, forKey: .title)
        fileId = try c.decodeIfPresent(String.self, forKey: .fileId); node = try c.decodeIfPresent(String.self, forKey: .node)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? d.container(keyedBy: Legacy.self).decodeIfPresent(UUID.self, forKey: .floorId)
        by = try c.decode(String.self, forKey: .by); at = try c.decode(Date.self, forKey: .at); version = try c.decode(Int.self, forKey: .version)
        folder = try c.decode(String.self, forKey: .folder); stamp = try c.decodeIfPresent(String.self, forKey: .stamp)
        warnings = try c.decode([String].self, forKey: .warnings); page = try c.decodeIfPresent(String.self, forKey: .page)
        source = try c.decodeIfPresent(String.self, forKey: .source); importError = try c.decodeIfPresent(String.self, forKey: .importError)
        inFolder = try c.decodeIfPresent(String.self, forKey: .inFolder); byId = try c.decodeIfPresent(UUID.self, forKey: .byId)
        origin = try c.decodeIfPresent(String.self, forKey: .origin); needsNetwork = try c.decodeIfPresent([String].self, forKey: .needsNetwork)
    }
}

/// `<root>/artifacts/artifacts.json` (0600) and a folder per artifact: an export's versions in `<id>/v<N>/`, an
/// agent's page as `<id>/source.html` (0444). A version is reserved here (`newVersion`) and listed once committed: a
/// folder never committed is passed over. Removed artifacts move to `.removed/<id>-<epochMs>/`. User folders: each
/// artifact's `inFolder`, plus `folders.json` (0600: the folders the user made or set something on, in order).
/// All disk work runs on one serial queue, off the cooperative pool.
actor ArtifactStore {
    /// `<root>/artifacts`.
    let dir: URL
    private var all: [Artifact]?   // loaded on first use
    private var entries: [FolderEntry]?   // `folders.json`, loaded on first use
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
    private var foldersFile: URL { dir.appendingPathComponent("folders.json") }
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
    func newVersion(fileId: String, node: String?, page: String?, title: String, paddockId: UUID?, by: String) async throws -> (Artifact, URL) {
        // one being removed (its record still listed while its folder moves) is not continued: a new artifact
        let all = try await registry().filter { $0.kind == .export && $0.fileId == fileId && $0.node == node && !removed.contains($0.id) }
        let known = node != nil ? all.first : all.first { $0.page == page } ?? (page != nil ? all.first { $0.page == nil && (adopting[$0.id] ?? page) == page } : nil)
        if let known, known.page == nil, let page { adopting[known.id] = page }
        let key = Self.key(fileId, node: node, page: page)
        let id = known?.id ?? pending[key].flatMap { removed.contains($0) ? nil : $0 } ?? UUID()
        if known == nil { pending[key] = id }
        let n = max(known?.version ?? 0, reserved[id] ?? 0) + 1
        reserved[id] = n
        var a = Artifact(id: id, kind: .export, title: title, fileId: fileId, node: node, paddockId: paddockId, by: by, at: Date(),
                         version: n, folder: "\(Self.name(id))/v\(n)", stamp: nil, warnings: [], page: page)
        // what the export does not make: kept from the record
        a.source = known?.source; a.inFolder = known?.inFolder; a.byId = known?.byId; a.origin = known?.origin; a.needsNetwork = known?.needsNetwork
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

    /// The record a new agent page starts from: a new artifact, or (`origin` already kept) that artifact's next version
    /// in `<id>/r<N>/`, its folder kept unless `inFolder` is given.
    private func agentRecord(title: String, paddockId: UUID?, by: String, byId: UUID?, inFolder: String?, origin: String?) async throws -> Artifact {
        if let origin, let known = try await registry().first(where: { $0.origin == origin && !removed.contains($0.id) }) {
            guard !converting.contains(known.id) else { throw Self.invalid("importação em andamento desse artifact; tente de novo em instantes") }
            let n = max(known.version, reserved[known.id] ?? 0) + 1
            reserved[known.id] = n
            return Artifact(id: known.id, kind: .agent, title: title, fileId: nil, node: nil, paddockId: paddockId ?? known.paddockId, by: by, at: Date(),
                            version: n, folder: "\(Self.name(known.id))/r\(n)", stamp: nil, warnings: [], inFolder: inFolder ?? known.inFolder,
                            byId: byId, origin: origin)
        }
        let id = UUID()
        return Artifact(id: id, kind: .agent, title: title, fileId: nil, node: nil, paddockId: paddockId, by: by, at: Date(),
                        version: 1, folder: Self.name(id), stamp: nil, warnings: [], inFolder: inFolder, byId: byId, origin: origin)
    }

    /// The rewrite's report on the record.
    private static func noted(_ a: inout Artifact, _ rw: OfflineRewriter?) {
        guard let r = rw?.report else { return }
        a.warnings += r.warnings; a.needsNetwork = r.remote.isEmpty ? nil : r.remote
    }

    /// `page` (an HTML document) kept as a new agent artifact (or the next version of the one from `origin`), made
    /// offline by `rewriter` in the copy.
    func addAgent(page: Data, title: String, paddockId: UUID?, by: String, byId: UUID? = nil, inFolder: String? = nil,
                  origin: String? = nil, rewriter: OfflineRewriter? = nil) async throws -> Artifact {
        var a = try await agentRecord(title: title, paddockId: paddockId, by: by, byId: byId, inFolder: inFolder, origin: origin)
        a.source = "\(a.folder)/source.html"
        let folder = dir.appendingPathComponent(a.folder), page = rewriter?.rewrite(page, ext: "html") ?? page
        try await onIO {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("source.html"))   // a version never recorded
            try Self.mkdir(folder)
            let dst = folder.appendingPathComponent("source.html")
            guard FileManager.default.createFile(atPath: dst.path, contents: page, attributes: [.posixPermissions: 0o444]) else {
                try? FileManager.default.removeItem(at: folder)
                throw ProtocolError(code: .internal, message: "artifacts: cannot write \(dst.path)")
            }
        }
        Self.noted(&a, rewriter)
        try await append(&a)
        return a
    }

    /// The folder `root` kept as a new agent artifact (`<id>/source/`), `page` (inside it) its page. Only regular files of
    /// the allowed kinds are copied (never a link; hidden names skipped), up to `maxFiles` and `maxBytes`: past them
    /// (or `page` outside `root`, or not copied) nothing is created. Read and written on the io queue.
    /// `noFollow` (the Prévia's save): `root` and the page's folder must be real paths already (no link anywhere in them).
    func addAgent(root: URL, page: URL, title: String, noFollow: Bool = false, paddockId: UUID?, by: String,
                  byId: UUID? = nil, inFolder: String? = nil, origin: String? = nil, rewriter: OfflineRewriter? = nil) async throws -> Artifact {
        // links in the paths themselves resolved (the page's own name is not: a linked page is not copied)
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let pageDir = page.standardizedFileURL.deletingLastPathComponent()
        let pageURL = pageDir.resolvingSymlinksInPath().appendingPathComponent(page.lastPathComponent)
        if noFollow, DiagramFile.real(root.standardizedFileURL).path != root.standardizedFileURL.path || DiagramFile.real(pageDir).path != pageDir.path {
            throw Self.invalid("--nofollow: the page's folder goes through a symbolic link")
        }
        let base = rootURL.path, pagePath = pageURL.path
        guard pagePath.hasPrefix(base + "/") else { throw Self.invalid("the page must be a regular file inside --root") }
        let pageRel = String(pagePath.dropFirst(base.count + 1))
        var a = try await agentRecord(title: title, paddockId: paddockId, by: by, byId: byId, inFolder: inFolder, origin: origin)
        a.source = "\(a.folder)/source/\(pageRel)"
        let folder = dir.appendingPathComponent(a.folder), dst = folder.appendingPathComponent("source")
        let made = a.version == 1 ? folder : dst   // what a failure removes: a new artifact's folder, else this version's copy
        try await onIO {
            var files = try Self.readTree(rootURL, page: pageRel)
            guard files.contains(where: { $0.rel == pageRel }) else { throw Self.invalid("the page must be a regular file inside --root") }
            if let rewriter { files = files.map { ($0.rel, rewriter.rewrite($0.data, ext: URL(fileURLWithPath: $0.rel).pathExtension)) } }
            Self.purge(dst)   // a version never recorded
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
            } catch { Self.purge(made); throw error }
        }
        Self.noted(&a, rewriter)
        do { try await append(&a) }
        catch { try? await onIO { Self.purge(made) }; throw error }   // the copy of a record never made
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
        let n = max(a.version, 1)   // a page added again (`origin`) exports as its own version
        reserved[id] = max(reserved[id] ?? 0, n)
        a.source = a.source ?? "\(a.folder)/source.html"
        a.kind = .export; a.fileId = fileId; a.node = node; a.page = page; a.importError = nil
        a.version = n; a.at = Date(); a.folder = "\(Self.name(id))/v\(n)"
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

    /// `a` recorded, its folder spelled as an existing one.
    private func append(_ a: inout Artifact) async throws {
        var made = a
        try await edit { list, fl in
            made.inFolder = made.inFolder.map { ArtifactFolder.canonical($0, known: Self.known(list, fl)) }
            if let i = list.firstIndex(where: { $0.id == made.id }) {   // the next version of one from the same origin
                guard !removed.contains(made.id) else { throw ProtocolError(code: .notFound, message: "the artifact was removed meanwhile") }
                if list[i].version < made.version { list[i] = made }
            } else {
                list.append(made)
            }
        }
        a = made
    }

    // MARK: folders

    private static func known(_ list: [Artifact], _ fl: [FolderEntry]) -> [String] { fl.map(\.path) + list.compactMap(\.inFolder) }
    private static func missing(_ p: String) -> ProtocolError { ProtocolError(code: .notFound, message: "pasta não encontrada: \(p)") }

    /// Artifact `id` into `folder` (normalized; nil: none), spelled as an existing one.
    func move(_ id: UUID, to folder: String?) async throws {
        try await edit { list, fl in
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw ProtocolError(code: .notFound, message: "no artifact \(Self.name(id))") }
            list[i].inFolder = folder.map { ArtifactFolder.canonical($0, known: Self.known(list, fl)) }
        }
    }

    /// Every folder (with the ones they are in): the user's in their order, then the others by name.
    func folders() async throws -> [FolderInfo] {
        let list = try await registry(), fl = try await folderEntries()
        var out: [String] = []
        func add(_ p: String) { for q in ArtifactFolder.lineage(p) where !out.contains(where: { ArtifactFolder.same($0, q) }) { out.append(q) } }
        fl.forEach { add($0.path) }
        list.compactMap(\.inFolder).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.forEach(add)
        return out.map { p in
            let e = fl.first { ArtifactFolder.same($0.path, p) }
            let own = list.filter { ArtifactFolder.same($0.inFolder, p) }.map(\.id), first = (e?.order ?? []).filter(own.contains)
            return FolderInfo(path: p, count: own.count, total: list.filter { ArtifactFolder.isUnder($0.inFolder, p) }.count, color: e?.color,
                              pinned: e?.pinned ?? false, presentation: e?.presentation ?? false, items: first + own.filter { !first.contains($0) })
        }
    }

    /// An empty folder kept (`path` normalized); one the user already has: refused.
    func createFolder(_ path: String) async throws {
        try await edit { list, fl in
            guard !fl.contains(where: { ArtifactFolder.same($0.path, path) }) else { throw Self.invalid("já existe: \(path)") }
            fl.append(FolderEntry(path: ArtifactFolder.canonical(path, known: Self.known(list, fl))))
        }
    }

    /// `from` and everything in it renamed to `to` (both normalized), artifacts' folders and the user's together in one
    /// change. Refused into an existing folder, inside itself, or past 3 levels; nothing changes then.
    /// ponytail: artifacts.json is written before folders.json; a failure between them leaves the user's empty folders
    /// under the old name (the artifacts already moved).
    func renameFolder(_ from: String, to: String) async throws {
        try await edit { list, fl in
            let known = Self.known(list, fl)
            guard known.contains(where: { ArtifactFolder.isUnder($0, from) }) else { throw Self.missing(from) }
            if !ArtifactFolder.same(from, to) {
                guard !ArtifactFolder.isUnder(to, from) else { throw Self.invalid("não cabe dentro dela mesma: \(to)") }
                guard !known.contains(where: { ArtifactFolder.isUnder($0, to) }) else { throw Self.invalid("já existe: \(to)") }
            }
            func moved(_ p: String) throws(ProtocolError) -> String {
                let n = ArtifactFolder.rebase(p, from: from, to: to) ?? to
                guard ArtifactFolder.names(n).count <= ArtifactFolder.maxDepth else { throw Self.invalid("passaria de \(ArtifactFolder.maxDepth) níveis: \(n)") }
                return n
            }
            for i in list.indices where ArtifactFolder.isUnder(list[i].inFolder, from) { list[i].inFolder = try moved(list[i].inFolder!) }
            for i in fl.indices where ArtifactFolder.isUnder(fl[i].path, from) { fl[i].path = try moved(fl[i].path) }
        }
    }

    /// `path` (and its subfolders) gone: only when no artifact is in it, unless `moveTo` (`.some(nil)`: "Sem pasta"), where
    /// its artifacts go. Never removes an artifact.
    func removeFolder(_ path: String, moveTo: String??) async throws {
        try await edit { list, fl in
            let known = Self.known(list, fl)
            guard known.contains(where: { ArtifactFolder.isUnder($0, path) }) else { throw Self.missing(path) }
            let inside = list.indices.filter { ArtifactFolder.isUnder(list[$0].inFolder, path) }
            if let dest = moveTo {
                if let d = dest, ArtifactFolder.isUnder(d, path) { throw Self.invalid("--move-to fica dentro da pasta removida") }
                let to = dest.map { ArtifactFolder.canonical($0, known: known) }
                for i in inside { list[i].inFolder = to }
            } else if !inside.isEmpty {
                throw Self.invalid("a pasta \(path) tem \(inside.count) artifact(s): esvazie-a ou use --move-to")
            }
            fl.removeAll { ArtifactFolder.isUnder($0.path, path) }
        }
    }

    /// The folder's settings (nil: unchanged; `color` "": none); a folder not kept yet becomes the user's.
    func setFolder(_ path: String, color: String?, pinned: Bool?, presentation: Bool?, order: [UUID]?) async throws {
        try await edit { list, fl in
            let i = fl.firstIndex { ArtifactFolder.same($0.path, path) } ?? {
                fl.append(FolderEntry(path: ArtifactFolder.canonical(path, known: Self.known(list, fl)))); return fl.count - 1
            }()
            if let color { fl[i].color = color.isEmpty ? nil : color }
            if let pinned { fl[i].pinned = pinned }
            if let presentation { fl[i].presentation = presentation }
            if let order { fl[i].order = order }
        }
    }

    // MARK: disk

    private func folderEntries() async throws -> [FolderEntry] {
        if let entries { return entries }
        let file = foldersFile
        let loaded = try await onIO { () throws -> [FolderEntry] in
            guard let d = FileManager.default.contents(atPath: file.path) else { return [] }
            if let v = try? JSONDecoder().decode([FolderEntry].self, from: d) { return v }
            // unreadable: set aside (kept for the user) and started over empty; folders are only labels, never block an add
            let aside = file.deletingLastPathComponent().appendingPathComponent("folders.json.bad-\(Int64(Date().timeIntervalSince1970 * 1000))")
            let moved = (try? FileManager.default.moveItem(at: file, to: aside)) != nil
            FileHandle.standardError.write(Data("collied: artifacts: \(file.path) is unreadable; \(moved ? "moved to \(aside.lastPathComponent)" : "ignored")\n".utf8))
            return []
        }
        if entries == nil { entries = loaded }
        return entries ?? loaded
    }

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
    private func update(_ change: (inout [Artifact]) -> Void) async throws { try await edit { list, _ in change(&list) } }

    /// `update` over both files: each written only when changed (artifacts.json first); a throwing `change` writes none.
    private func edit(_ change: (inout [Artifact], inout [FolderEntry]) throws -> Void) async throws {
        while saving { await withCheckedContinuation { waiters.append($0) } }
        saving = true
        defer { saving = false; if !waiters.isEmpty { waiters.removeFirst().resume() } }
        let list0 = try await registry(), fl0 = try await folderEntries()
        var list = list0, fl = fl0
        try change(&list, &fl)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if list != list0 {
            let data = try enc.encode(list), file = registryFile
            try await onIO { try DesignService.writePrivate(data, to: file) }
            all = list
        }
        if fl != fl0 {
            let data = try enc.encode(fl), file = foldersFile
            try await onIO { try DesignService.writePrivate(data, to: file) }
            entries = fl
        }
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
