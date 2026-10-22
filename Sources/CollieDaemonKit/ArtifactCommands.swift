import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// `artifact.*`: the admin token or a terminal token (as `memory.*`); `reexport` and `remove` are the app's.
    func artifactCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        @Sendable func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        if caller != nil, ["artifact.reexport", "artifact.remove"].contains(r.command) {
            throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is for the app only")
        }
        func id() throws(ProtocolError) -> UUID {
            guard let u = UUID(uuidString: try need(r, "id")) else { throw invalid("'id' must be an artifact id") }
            return u
        }
        switch r.command {
        case "artifact.list":
            let all = try await artifacts.list().sorted { $0.at > $1.at }, files = try await design.list()
            let status = await artifactStatus(all, files: Set(files.map(\.id)), deadline: design.deadline(r.command))
            return .array(try await artifactRows(all, files: files).map { a, row in
                var row = row
                row["status"] = .string(importingArtifacts.contains(a.id) ? "importing" : a.kind == .agent && a.importError != nil ? "failed" : status[a.id] ?? "pending")
                return .object(row)
            })
        case "artifact.get":
            let a = try await artifacts.get(try id())
            return .object(try await artifactRows([a], files: try await design.list())[0].1)
        case "artifact.add":
            let base = URL(fileURLWithPath: r.cwd ?? caller?.cwd ?? "/", isDirectory: true)
            let src = URL(fileURLWithPath: try need(r, "path"), relativeTo: base).standardizedFileURL
            guard ["html", "htm"].contains(src.pathExtension.lowercased()) else { throw invalid("'\(src.path)' is not an .html or .htm file") }
            let title = str(r, "title").flatMap { $0.isEmpty ? nil : $0 } ?? src.lastPathComponent
            let width = try DeviceService.int(r.args, "width", 320...3840) ?? 1440
            let a: Artifact
            if let root = str(r, "root").flatMap({ $0.isEmpty ? nil : $0 }) {
                a = try await artifacts.addAgent(root: URL(fileURLWithPath: root, relativeTo: base), page: src, title: title,
                                                 floorId: caller?.floorId, by: Self.origin(caller))
            } else {
            // opened without following a link (nor blocking on a fifo), then checked and read through that descriptor
            let cap = 8 << 20
            let read = try await UnixSocketClient.offPool { () -> Result<Data, ProtocolError> in
                let fd = open(src.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else {
                    return .failure(invalid(errno == ELOOP ? "'\(src.path)' is not a regular file" : "cannot read \(src.path)"))
                }
                defer { close(fd) }
                var st = stat()
                guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .failure(invalid("'\(src.path)' is not a regular file")) }
                guard st.st_size <= cap else { return .failure(invalid("'\(src.path)' is over 8 MiB")) }
                let d: Data
                do { d = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: cap + 1) ?? Data() }   // nil: empty
                catch { return .failure(invalid("cannot read \(src.path)")) }
                guard d.count <= cap else { return .failure(invalid("'\(src.path)' is over 8 MiB")) }
                return .success(d)
            }
            a = try await artifacts.addAgent(page: try read.get(), title: title, floorId: caller?.floorId, by: Self.origin(caller))
            }
            let id = JSONValue.string(a.id.uuidString.lowercased())
            for p in ws.panels where p.pluginId == "artifacts" {
                await pluginEmitted(panel: p.id, name: "artifact.added", payload: .object(["id": id]))
            }
            importInBackground(a, width: width, by: Self.origin(caller))
            return .object(["id": id, "importing": .bool(true)])
        case "artifact.import":
            return try await importArtifact(try id(), width: try DeviceService.int(r.args, "width", 320...3840) ?? 1440, by: Self.origin(caller))
        case "artifact.reexport":
            let a = try await artifacts.get(try id())
            guard a.kind == .export, let fid = a.fileId else { throw invalid("an agent's page has no design to export: imported in plan 2D") }
            guard let f = try await design.list().first(where: { $0.id == fid }) else {
                throw ProtocolError(code: .notFound, message: "the artifact's design file is gone")
            }
            let deadline = design.deadline(r.command)
            let snap = try await design.systemSnapshot(fileId: fid, node: a.node, page: a.page, deadline: deadline)
            return try await exportHTML(f, node: a.node, snapshot: snap, by: Self.origin(nil), deadline: deadline)
        case "artifact.remove":
            try await artifacts.remove(try id())
            return .object([:])
        default:
            throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// An export version whose artifact was removed while it was written: its folder deleted (and the artifact's, when
    /// that leaves it empty: the remove had moved it away already), as the error to answer.
    private func dropped(_ folder: URL) async throws -> ProtocolError {
        try await UnixSocketClient.offPool {
            try? FileManager.default.removeItem(at: folder)
            _ = rmdir(folder.deletingLastPathComponent().path)   // only when empty
        }
        return ProtocolError(code: .notFound, message: "the artifact was removed meanwhile")
    }

    /// Each artifact as `artifact.list` shows it, without `status`.
    private func artifactRows(_ all: [Artifact], files: [DesignService.File]) async throws -> [(Artifact, [String: JSONValue])] {
        let dir = artifacts.dir
        func page(_ a: Artifact) -> String {
            a.kind == .export ? "\(a.folder)/index.html" : a.source ?? "\(a.folder)/source.html"
        }
        let thumbs = try await UnixSocketClient.offPool {
            Set(all.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0.folder)/thumb.png").path) }.map(\.id))
        }
        let iso = ISO8601DateFormatter()
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        return all.map { a in
            (a, ["id": .string(a.id.uuidString.lowercased()), "kind": .string(a.kind.rawValue), "title": .string(a.title),
                 "file": opt(files.first { $0.id == a.fileId }?.name), "node": opt(a.node), "by": .string(a.by),
                 "at": .string(iso.string(from: a.at)), "version": .number(Double(a.version)),
                 "url": .string("collie-artifact://app/\(page(a))"),
                 "source": (a.source ?? (a.kind == .agent ? page(a) : nil)).map { .string("collie-artifact://app/\($0)") } ?? .null,
                 "importError": opt(a.importError), "path": .string(dir.appendingPathComponent(page(a)).path),
                 "thumbnail": thumbs.contains(a.id) ? .string(dir.appendingPathComponent("\(a.folder)/thumb.png").path) : .null,
                 "warnings": .array(a.warnings.map { .string($0) })])
        }
    }

    /// Each export's status (agent pages have none: `pending`): its design's stamp now against the one kept. One stamp
    /// at a time, file by file, each within 10 s and all within `deadline` (those left over: `unknown`, unasked).
    private func artifactStatus(_ all: [Artifact], files: Set<String>, deadline: ContinuousClock.Instant) async -> [UUID: String] {
        var out: [UUID: String] = [:]
        let byFile = Dictionary(grouping: all.filter { $0.kind == .export }) { $0.fileId ?? "" }
        for (fid, group) in byFile.sorted(by: { $0.key < $1.key }) {
            for a in group {
                guard files.contains(fid) else { out[a.id] = "missing"; continue }
                guard ContinuousClock.now < deadline else { out[a.id] = "unknown"; continue }
                do {
                    let s = try await design.currentStamp(fileId: fid, node: a.node, page: a.page, deadline: min(.now + .seconds(10), deadline))
                    out[a.id] = s == a.stamp ? "current" : "stale"
                } catch {
                    out[a.id] = (error as? ProtocolError).map { $0.message.contains("no such layer") || $0.message.hasPrefix("no such page") } == true ? "missing" : "unknown"
                }
            }
        }
        return out
    }

    /// `snapshot` of file `f` (of `node`, else its page) as a complete HTML document: the next version of its export
    /// artifact. Its tokens: the file's variables, then those of the design system active on its floor (unless it is
    /// that system's own file; unreadable, or not within what is left of `deadline`: left out, with a warning).
    /// `artifact.exported` goes to every Artifacts panel.
    /// `importing`: the agent artifact whose import this is (it becomes that export's version 1) and its warnings.
    func exportHTML(_ f: DesignService.File, node: String?, snapshot s: ExportSnapshot, by: String,
                    deadline: ContinuousClock.Instant, importing: (id: UUID, warnings: [String])? = nil) async throws -> JSONValue {
        var variables = [s.variables], extra: [String] = []
        if let id = activeSystem(floor: f.floorId) {
            do {
                if let ds = try await systems.list().first(where: { $0.id == id }), ds.fileId.uuidString.lowercased() != f.id {
                    variables.append(try await design.variables(ofFile: ds.fileId.uuidString.lowercased(), deadline: deadline))
                }
            } catch { extra.append("design system tokens unavailable") }
        }
        var title = f.name
        if node != nil, case .object(let o)? = s.layers.first, case .string(let n)? = o["name"] { title = n }
        let b = HTMLExport.build(ExportInput(title: title, code: s.code, layers: s.layers, variables: variables, assets: s.assets))
        let (made, folder) = if let importing, let node {
            try await artifacts.convertToExport(importing.id, fileId: f.id, node: node, page: s.page)
        } else {
            try await artifacts.newVersion(fileId: f.id, node: node, page: s.page, title: title, floorId: f.floorId, by: by)
        }
        var a = made
        let page = folder.appendingPathComponent("index.html"), files = b.files, thumb = s.thumbnail, html = b.html
        // ponytail: HTMLExport makes these paths from sanitized names; checked again, as they reach the disk
        guard files.allSatisfy({ !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") }) else {
            throw ProtocolError(code: .internal, message: "artifacts: an export file path leaves its folder")
        }
        guard try await UnixSocketClient.offPool({ () -> Bool in
            do {
                try Data(html.utf8).write(to: page)
                for (path, data) in files {
                    let u = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: u)
                }
                if let thumb { try thumb.write(to: folder.appendingPathComponent("thumb.png")) }
                return true
            } catch { return false }
        }) else {
            if await artifacts.wasRemoved(a.id) { throw try await dropped(folder) }
            throw ProtocolError(code: .internal, message: "artifacts: cannot write \(folder.path)")
        }
        a.stamp = s.stamp; a.page = s.page; a.warnings = (importing?.warnings ?? []) + b.warnings + extra
        guard try await artifacts.commit(a) else { throw try await dropped(folder) }
        let id = JSONValue.string(a.id.uuidString.lowercased()), version = JSONValue.number(Double(a.version))
        for p in ws.panels where p.pluginId == "artifacts" {
            await pluginEmitted(panel: p.id, name: "artifact.exported", payload: .object(["id": id, "version": version]))
        }
        return .object(["path": .string(page.path), "artifact": id, "version": version, "warnings": .array(a.warnings.map { .string($0) })])
    }
}
