import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// `artifact.*`: the admin token or a terminal token (as `memory.*`); `reexport`, `remove` and `folder.*` are the app's.
    /// `libs`: the offline web libraries (`config.weblibsDir`'s manifest) as `collie-lib://` URLs.
    func artifactCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        @Sendable func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        if caller != nil, ["artifact.reexport", "artifact.remove"].contains(r.command) || r.command.hasPrefix("artifact.folder.") {
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
            var origin: String?
            if let v = str(r, "source"), !v.isEmpty {
                let l = try ClaudeImport.links([v])
                guard l.count == 1 else { throw invalid("--source: um link só") }
                origin = l[0]
            }
            // the asked terminal's report (the app's sheet follows only those); taken before the add clears the grant
            let nonce = origin.flatMap { askedNonce($0, r, caller) }
            // one add per link at a time: a version never overtakes another
            // ponytail: 50 ms polling, as font.add
            if let origin { while addingSources.contains(origin) { try await Task.sleep(for: .milliseconds(50)) } }
            if let origin { addingSources.insert(origin) }
            defer { if let origin { addingSources.remove(origin) } }
            do { return try await addPage(r, caller: caller, origin: origin, nonce: nonce) } catch {
                if let origin, let nonce { await importFailed(origin, (error as? ProtocolError)?.message ?? "\(error)", nonce: nonce) }
                throw error
            }
        case "artifact.import-claude":
            return try await importClaude(r, caller: caller)
        case "artifact.import-terminals":
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is for the app only") }
            return .array(try await claudeTerminals().map { t, running, first in
                .object(["id": .string(t.id.uuidString.lowercased()), "name": .string(t.name), "running": .bool(running), "default": .bool(first)])
            })
        case "artifact.import-list":
            let nonce = str(r, "nonce") ?? ""
            guard let asked = claudeLists[nonce], caller.map({ $0.id == asked }) ?? true else {
                throw ProtocolError(code: .unauthorized, message: "só o terminal a quem o app pediu a lista a entrega (com o --nonce do pedido)")
            }
            let base = URL(fileURLWithPath: r.cwd ?? caller?.cwd ?? "/", isDirectory: true)
            let file = URL(fileURLWithPath: try need(r, "path"), relativeTo: base).standardizedFileURL
            let text = try await UnixSocketClient.offPool { try DiagramFile.readLocal(file) }
            let items = try ClaudeImport.entries(Data(text.utf8))
            claudeLists[nonce] = nil
            let payload = JSONValue.object(["by": .string(Self.origin(caller)), "nonce": .string(nonce), "items": .array(items.map { e in
                .object(["url": .string(e.url), "title": e.title.map { .string($0) } ?? .null])
            })])
            for p in ws.panels where p.pluginId == "artifacts" { await pluginEmitted(panel: p.id, name: "artifact.import.list", payload: payload) }
            return .object(["count": .number(Double(items.count))])
        case "artifact.import-failed":
            let l = try ClaudeImport.links([try need(r, "url")])
            guard l.count == 1 else { throw invalid("um link só") }
            guard let nonce = askedNonce(l[0], r, caller) else {
                throw ProtocolError(code: .unauthorized, message: "só o terminal a quem o app pediu esse link relata a falha (com o --nonce do pedido)")
            }
            let reason = ClaudeImport.clean(str(r, "reason") ?? "")
            await importFailed(l[0], reason.isEmpty ? "o terminal não conseguiu ler o artifact" : reason, nonce: nonce)
            return .object([:])
        case "artifact.new":
            guard let kind = ArtifactTemplates.Kind(rawValue: try need(r, "kind")) else {
                throw invalid("kind must be " + ArtifactTemplates.Kind.allCases.map(\.rawValue).joined(separator: "|"))
            }
            return try await newPage(kind, r, caller: caller)
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
        case "artifact.libs":
            let dir = config.weblibsDir
            let libs = try await UnixSocketClient.offPool { dir.map(WebLibs.manifest(in:)) ?? [] }
            guard !libs.isEmpty else { throw ProtocolError(code: .unavailable, message: "Bibliotecas offline ausentes: rode scripts/fetch-weblibs.sh") }
            return .array(libs.map { e in
                .object(["name": .string(e.name), "version": .string(e.version), "global": .string(e.global),
                         "url": WebLibs.url(e.name, in: [e]).map { .string($0) } ?? .null, "licence": .string(e.licence)])
            })
        case "artifact.remove":
            try await artifacts.remove(try id())
            return .object([:])
        case "artifact.move":
            guard case .string(let f)? = r.args["folder"] else { throw invalid("Missing argument 'folder' (\"\" for none)") }
            let folder = try ArtifactFolder.normalize(f), a = try await artifacts.get(try id())
            if let me = caller { try await checkImportFolder(folder, link: nil, by: me) }   // user decision: any agent moves any artifact, into an existing folder
            try await artifacts.move(a.id, to: folder)
            await artifactsChanged()
            return .object(["folder": folder.map { .string($0) } ?? .null])
        case "artifact.folders":
            return .array(try await artifacts.folders().map { f in
                .object(["path": .string(f.path), "count": .number(Double(f.count)), "total": .number(Double(f.total)),
                         "color": f.color.map { .string($0) } ?? .null, "pinned": .bool(f.pinned), "presentation": .bool(f.presentation),
                         "items": .array(f.items.map { .string($0.uuidString.lowercased()) })])
            })
        case "artifact.folder.create", "artifact.folder.rename", "artifact.folder.remove", "artifact.folder.set":
            guard let path = try ArtifactFolder.normalize(try need(r, "path")) else { throw invalid("Missing argument 'path'") }
            switch r.command {
            case "artifact.folder.create": try await artifacts.createFolder(path)
            case "artifact.folder.rename":
                guard let to = try ArtifactFolder.normalize(try need(r, "to")) else { throw invalid("Missing argument 'to'") }
                try await artifacts.renameFolder(path, to: to)
            case "artifact.folder.remove":
                let dest: String?? = if case .string(let m)? = r.args["move-to"] { .some(try ArtifactFolder.normalize(m)) } else { nil }
                try await artifacts.removeFolder(path, moveTo: dest)
            default:
                func bool(_ k: String) throws(ProtocolError) -> Bool? {
                    guard let v = str(r, k) else { return nil }
                    guard v == "true" || v == "false" else { throw invalid("'\(k)' must be true or false") }
                    return v == "true"
                }
                let color = str(r, "color")
                if let c = color, !c.isEmpty, c.wholeMatch(of: /#[0-9a-fA-F]{6}/) == nil { throw invalid("'color' must be #RRGGBB (\"\" for none)") }
                let order = try str(r, "order").map { s throws(ProtocolError) in
                    try s.split(separator: ",").map { w throws(ProtocolError) in
                        guard let u = UUID(uuidString: w.trimmingCharacters(in: .whitespaces)) else { throw invalid("'order' must list artifact ids") }
                        return u
                    }
                }
                try await artifacts.setFolder(path, color: color, pinned: try bool("pin"), presentation: try bool("present"), order: order)
            }
            await artifactsChanged()
            return .object([:])
        default:
            throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// `artifact.changed` to every Artifacts panel (a move or a folder change).
    private func artifactsChanged() async {
        for p in ws.panels where p.pluginId == "artifacts" { await pluginEmitted(panel: p.id, name: "artifact.changed", payload: .object([:])) }
    }

    /// The folder a new artifact goes in: `--folder` (normalized; "": none), else the caller's lot's (`lotFolder`).
    private func artifactFolder(_ r: Request, caller: TerminalRecord?) throws(ProtocolError) -> String? {
        if case .string(let f)? = r.args["folder"] { return try ArtifactFolder.normalize(f) }
        return lotFolder(caller)
    }

    /// The caller's lot's name as a folder (a "/" in it kept as "-"); none outside a lot (and for the app).
    private func lotFolder(_ caller: TerminalRecord?) -> String? {
        guard let me = caller, let lot = ws.lot(of: me.id) else { return nil }
        return try? ArtifactFolder.normalize(String(lot.name.replacingOccurrences(of: "/", with: "-").prefix(ArtifactFolder.maxName)))
    }

    /// User decision (2026-10-26): a terminal files into any folder that already exists (the user creates folders in the app),
    /// its lot's folder (made on first use), or none; a new path is refused.
    private func checkImportFolder(_ folder: String?, link: String?, by me: TerminalRecord) async throws {
        guard let folder, !ArtifactFolder.same(folder, lotFolder(me)) else { return }
        if let link, let g = claudeImports[link], g.terminal == me.id, ArtifactFolder.same(g.folder, folder) { return }
        if try await artifacts.folders().contains(where: { ArtifactFolder.same($0.path, folder) }) { return }
        throw ProtocolError(code: .unauthorized, message: "a pasta '\(folder)' não existe: crie no app (Artifacts → Nova pasta) ou use uma existente")
    }

    /// The nonce of the app's ask for `link` when `r` brings it (`--nonce`) from the terminal it was asked of; nil otherwise.
    private func askedNonce(_ link: String, _ r: Request, _ caller: TerminalRecord?) -> String? {
        guard let g = claudeImports[link], let n = str(r, "nonce"), n == g.nonce, caller.map({ $0.id == g.terminal }) ?? true else { return nil }
        return n
    }

    /// `artifact.import.failed` `{url, reason, nonce}` to every Artifacts panel (the import sheet's row; `url` "": its list).
    func importFailed(_ link: String, _ reason: String, nonce: String) async {
        for p in ws.panels where p.pluginId == "artifacts" {
            await pluginEmitted(panel: p.id, name: "artifact.import.failed",
                                payload: .object(["url": .string(link), "reason": .string(reason), "nonce": .string(nonce)]))
        }
    }

    /// `artifact add`: an .html/.htm page (with `--root`, its folder), a folder (its page: `ZipCheck.page`) or a .zip
    /// (checked, unpacked into `<root>/.import-<uuid>`, removed after). The copy is made offline (`OfflineRewriter`);
    /// Google Fonts it asks for are downloaded in the background when that is on. `origin` (`--source`): a claude.ai
    /// link; the same link again is that artifact's next version (its folder kept unless `--folder`).
    private func addPage(_ r: Request, caller: TerminalRecord?, origin: String?, nonce: String?) async throws -> JSONValue {
        @Sendable func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let base = URL(fileURLWithPath: r.cwd ?? caller?.cwd ?? "/", isDirectory: true)
        let src = URL(fileURLWithPath: try need(r, "path"), relativeTo: base).standardizedFileURL
        let known = try await artifacts.continued(origin: origin, byId: caller?.id)
        if let known, importingArtifacts.contains(known.id) { throw invalid("importação em andamento desse artifact; tente de novo em instantes") }
        let folder = r.args["folder"] == nil && known != nil ? nil : try artifactFolder(r, caller: caller)
        if let me = caller { try await checkImportFolder(folder, link: origin, by: me) }   // every terminal add
        let width = try DeviceService.int(r.args, "width", 320...3840) ?? 1440
        let dir = config.weblibsDir, fontDir = config.paths.root.appendingPathComponent("fonts"), google = googleFonts
        let libs = try await UnixSocketClient.offPool { dir.map(WebLibs.manifest(in:)) ?? [] }
        let rw = OfflineRewriter(libs: libs) { f in
            google || Fonts.bundled.contains { $0.family == f } || Fonts.downloaded(f, in: fontDir) != nil ? nil
                : "fonte \(f) não baixada: ligue Baixar fontes do Google Fonts nas Preferências ou rode collie font add \"\(f)\""
        }
        let ext = src.pathExtension.lowercased()
        let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
        let named = str(r, "title").flatMap { $0.isEmpty ? nil : $0 }
        let root = str(r, "root").flatMap { $0.isEmpty ? nil : $0 }
        let a: Artifact
        if isDir || ext == "zip" {
            guard root == nil else { throw invalid("--root vale só com uma página .html") }
            let title = named ?? src.deletingPathExtension().lastPathComponent
            var scratch: URL?
            defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
            let (top, page): (URL, URL)
            if isDir {
                page = try ZipCheck.page(in: src); top = src
            } else {
                let tmp = config.paths.root.appendingPathComponent(".import-\(UUID().uuidString)")
                scratch = tmp
                page = try await ZipCheck.extract(src, into: tmp); top = tmp
            }
            a = try await artifacts.addAgent(root: top, page: page, title: title, noFollow: flag(r, "nofollow"), paddockId: caller?.paddockId,
                                             by: Self.origin(caller), byId: caller?.id, inFolder: folder, origin: origin, rewriter: rw)
        } else {
            guard ["html", "htm"].contains(ext) else { throw invalid("'\(src.path)' is not an .html or .htm file, a folder or a .zip") }
            let title = named ?? src.lastPathComponent
            if let root {
                a = try await artifacts.addAgent(root: URL(fileURLWithPath: root, relativeTo: base), page: src, title: title, noFollow: flag(r, "nofollow"),
                                                 paddockId: caller?.paddockId, by: Self.origin(caller), byId: caller?.id, inFolder: folder,
                                                 origin: origin, rewriter: rw)
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
                a = try await artifacts.addAgent(page: try read.get(), title: title, paddockId: caller?.paddockId, by: Self.origin(caller),
                                                 byId: caller?.id, inFolder: folder, origin: origin, rewriter: rw)
            }
        }
        if let origin, nonce != nil { claudeImports[origin] = nil }   // the asked add done (another terminal's never clears it)
        let id = JSONValue.string(a.id.uuidString.lowercased())
        for p in ws.panels where p.pluginId == "artifacts" {
            // the link only for the asked terminal's add: the sheet's row follows that one alone
            await pluginEmitted(panel: p.id, name: "artifact.added", payload: .object(["id": id, "url": nonce == nil ? .null : origin.map { .string($0) } ?? .null,
                                                                                       "nonce": nonce.map { .string($0) } ?? .null]))
        }
        importInBackground(a, width: width, by: Self.origin(caller))
        if google {   // the families not here yet, one after another (each within font.add's own limits)
            // at most 6 families an import (a drop by the app: 10), through font.add's own caps
            let missing = rw.report.fonts.filter { f in !Fonts.bundled.contains { $0.family == f.family } && Fonts.downloaded(f.family, in: fontDir) == nil }
                .prefix(caller == nil ? 10 : 6)
            if !missing.isEmpty {
                Task { for f in missing { _ = try? await addFont(f.family, weights: f.weights ?? [400, 700], italic: false, caller: caller) } }
            }
        }
        return .object(["id": id, "importing": .bool(true), "version": .number(Double(a.version)), "warnings": .array(a.warnings.map { .string($0) }),
                        "needsNetwork": .array((a.needsNetwork ?? []).map { .string($0) })])
    }

    /// Claude Code terminals, the default first (the one the user typed into last, running), then by name.
    private func claudeTerminals() async -> [(TerminalRecord, Bool, Bool)] {
        let last = await hub.lastInput
        var out: [(TerminalRecord, Bool)] = []
        for t in ws.terminals where t.preset == .claude { out.append((t, await registry.process(t.id)?.isRunning ?? false)) }
        out.sort { a, b in
            if a.1 != b.1 { return a.1 }
            let x = last[a.0.id], y = last[b.0.id]
            if x != y { return (x ?? .now - .seconds(1 << 40)) > (y ?? .now - .seconds(1 << 40)) }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }
        return out.enumerated().map { i, t in (t.0, t.1, i == 0 && t.1) }
    }

    /// `artifact import-claude`: the links checked (≤ 50), then the recipe (`ClaudeImport.recipe`, or `.listRecipe` with
    /// `--mine`) for a Claude terminal, its files going to `<root>/sandbox/<id>/state/claude-import/<ms>/`. A terminal gets
    /// it back to follow (folder: its lot's or none); the app sends it to `--terminal` (default: the Claude terminal the
    /// user typed into last) as an ask, in the background, its folder then allowed for those links.
    private func importClaude(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let mine = flag(r, "mine"), words = str(r, "urls") ?? ""
        if mine, !words.trimmingCharacters(in: .whitespaces).isEmpty { throw invalid("--mine lista os artifacts: sem links") }
        let links = mine ? [] : try ClaudeImport.links([words])
        let title = str(r, "title").map { ClaudeImport.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
        if title != nil, links.count != 1 { throw invalid("--title vale para um link só") }
        let folder: String?, target: TerminalRecord
        if let me = caller {
            guard str(r, "terminal") == nil else { throw ProtocolError(code: .unauthorized, message: "--terminal is for the app only") }
            folder = try artifactFolder(r, caller: me)
            try await checkImportFolder(folder, link: nil, by: me)
            target = me
        } else {
            folder = if case .string(let f)? = r.args["folder"] { try ArtifactFolder.normalize(f) } else { nil }
            let all = await claudeTerminals()
            if let n = str(r, "terminal"), !n.isEmpty {
                guard let t = all.first(where: { $0.0.name.caseInsensitiveCompare(n) == .orderedSame || $0.0.id.uuidString.caseInsensitiveCompare(n) == .orderedSame }) else {
                    throw ProtocolError(code: .notFound, message: "nenhum terminal Claude chamado \(n)")
                }
                guard t.1 else { throw ProtocolError(code: .notRunning, message: "o terminal \(t.0.name) não está rodando") }
                target = t.0
            } else {
                guard let t = all.first(where: { $0.2 }) else { throw ProtocolError(code: .notFound, message: "nenhum terminal Claude aberto: abra um (já logado no claude.ai)") }
                target = t.0
            }
        }
        let dir = SandboxLaunch.dir(target.id, root: config.paths.root)
            .appendingPathComponent("state/claude-import/\(Int64(Date().timeIntervalSince1970 * 1000))")
        try await UnixSocketClient.offPool {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // the app's ask carries a nonce: only that terminal's reports with it reach the sheet
        let nonce: String? = caller == nil ? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() : nil
        let text = mine ? ClaudeImport.listRecipe(file: dir.appendingPathComponent("list.json").path, nonce: nonce)
            : ClaudeImport.recipe(links: links, dir: dir.path, folder: folder, title: title, nonce: nonce)
        var out: [String: JSONValue] = ["links": .array(links.map { .string($0) }), "dir": .string(dir.path)]
        if caller != nil {
            out["recipe"] = .string(text)
            return .object(out)
        }
        guard let nonce else { return .object(out) }
        for l in links { claudeImports[l] = (target.id, folder, nonce) }
        if mine { claudeLists[nonce] = target.id }
        let id = target.id
        Task {
            do throws(ProtocolError) { try await asks.inject(to: id, prompt: text) } catch {
                for l in links { await importFailed(l, error.message, nonce: nonce) }
                if mine { await importFailed("", error.message, nonce: nonce) }
            }
        }
        out["terminal"] = .string(target.name); out["nonce"] = .string(nonce)
        return .object(out)
    }

    /// `artifact new`: the starter page written (never over an existing file) into the caller's project, then a Prévia on
    /// it leashed to the caller. Tokens: the active design system's, read within 10 s; none, or any failure: the seed's,
    /// with a warning (the command never fails for that).
    private func newPage(_ kind: ArtifactTemplates.Kind, _ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let dir = config.weblibsDir
        let libs = try await UnixSocketClient.offPool { dir.map(WebLibs.manifest(in:)) ?? [] }
        let tester = caller.flatMap { $0.isShepherd ? nil : $0 }
        // --connect: a Shepherd leashes the new Prévia to terminals it reaches (as `panel open --connect`), checked first
        var wirer: TerminalRecord?
        if r.args["connect"] != nil {
            guard let me = caller, me.isShepherd else { throw ProtocolError(code: .notShepherd, message: "--connect is Shepherd-only") }
            _ = try connectTargets(r, by: me, panels: false); wirer = me
        }
        let slot = try tester.map { me throws(ProtocolError) in try reservePreview(me) }   // before anything is written
        defer { if let me = tester, let slot { releasePreview(me, slot) } }
        let paddock = try canvasPaddock(str(r, "paddock"), caller: caller)
        let folder = try artifactFolder(r, caller: caller)   // the Prévia's Salvar como artifact keeps the page there
        if let me = caller { try await checkImportFolder(folder, link: nil, by: me) }   // as an add: its lot's folder or none
        let root = try await projectRootForPanel(paddock: paddock, caller: caller)
        let slug: String
        if let n = str(r, "name") {
            guard let s = ArtifactTemplates.slug(n) else { throw invalid("nome sem letras nem números: \(n)") }
            slug = s
        } else {
            var i = 1
            while FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/pages/\(kind.rawValue)-\(i)").path) { i += 1 }
            slug = "\(kind.rawValue)-\(i)"
        }
        let rel = "docs/pages/\(slug)/index.html", url = root.appendingPathComponent(rel)   // the slug has no `/` nor `.`
        if FileManager.default.fileExists(atPath: url.path) { throw invalid("já existe: \(rel)") }
        var warnings: [String] = [], variables: JSONValue?
        if let id = activeSystem(paddock: paddock) {
            do throws(ProtocolError) {
                guard let ds = (try? await systems.list())?.first(where: { $0.id == id }) else {
                    throw ProtocolError(code: .notFound, message: "design system")
                }
                variables = try await systems.variables(of: ds, deadline: .now + .seconds(10))
            } catch { warnings.append("design system indisponível: tokens padrão") }
        } else { warnings.append("sem design system ativo: tokens padrão") }
        let title = str(r, "title").flatMap { $0.isEmpty ? nil : $0 } ?? str(r, "name") ?? kind.label
        if libs.isEmpty { warnings.append("bibliotecas offline ausentes") }
        let fonts = ArtifactTemplates.fonts(variables: variables), fontDir = config.paths.root.appendingPathComponent("fonts")
        for f in Set([fonts.text, fonts.mono]).sorted() where !Fonts.bundled.contains(where: { $0.family == f }) && Fonts.downloaded(f, in: fontDir) == nil {
            warnings.append("fonte \(f) não baixada: collie font add \"\(f)\"")
        }
        let html = ArtifactTemplates.render(kind, title: title, tokensCSS: ArtifactTemplates.tokensCSS(variables: variables), libs: libs, fonts: fonts)
        try await UnixSocketClient.offPool { try DiagramFile.write(html, to: url, root: root, noun: "página", exclusive: true) }
        let name = freePanelName("preview")
        try reserve(name); defer { launching.remove(name.lowercased()) }
        let (p, _, _) = try await openPanel(name: name, pluginId: "preview", placement: .canvas,
                                            state: ["file": .string(rel)].merging(folder.map { ["folder": .string($0)] } ?? [:]) { a, _ in a },
                                            file: nil, paddock: paddock, caller: caller, reservation: slot)
        do {   // re-checked after openPanel's awaits; the page stays, the panel goes
            for t in try wirer.map({ try connectTargets(r, by: $0, panels: false).terminals }) ?? [] { try await leash(t, p) }
        } catch { try? await remove(p); throw error }
        return .object(["file": .string(rel), "panel": .string(p.name), "warnings": .array(warnings.map { .string($0) })])
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
                 "importError": opt(a.importError), "folder": opt(a.inFolder), "path": .string(dir.appendingPathComponent(page(a)).path),
                 "thumbnail": thumbs.contains(a.id) ? .string(dir.appendingPathComponent("\(a.folder)/thumb.png").path) : .null,
                 "warnings": .array(a.warnings.map { .string($0) }), "origin": opt(a.origin),
                 "needsNetwork": .array((a.needsNetwork ?? []).map { .string($0) })])
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
    /// artifact. Its tokens: the file's variables, then those of the design system active on its paddock (unless it is
    /// that system's own file; unreadable, or not within what is left of `deadline`: left out, with a warning).
    /// `artifact.exported` goes to every Artifacts panel.
    /// `importing`: the agent artifact whose import this is (it becomes that export's version 1) and its warnings.
    func exportHTML(_ f: DesignService.File, node: String?, snapshot s: ExportSnapshot, by: String,
                    deadline: ContinuousClock.Instant, importing: (id: UUID, warnings: [String])? = nil) async throws -> JSONValue {
        var variables = [s.variables], extra: [String] = []
        if let id = activeSystem(paddock: f.paddockId) {
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
            try await artifacts.newVersion(fileId: f.id, node: node, page: s.page, title: title, paddockId: f.paddockId, by: by)
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
        a.stamp = s.stamp; a.page = s.page
        // an import keeps the page's own warnings (its offline rewrite) before the design's
        a.warnings = (importing.map { made.warnings + $0.warnings } ?? []) + b.warnings + extra
        guard try await artifacts.commit(a) else { throw try await dropped(folder) }
        let id = JSONValue.string(a.id.uuidString.lowercased()), version = JSONValue.number(Double(a.version))
        for p in ws.panels where p.pluginId == "artifacts" {
            await pluginEmitted(panel: p.id, name: "artifact.exported", payload: .object(["id": id, "version": version]))
        }
        return .object(["path": .string(page.path), "artifact": id, "version": version, "warnings": .array(a.warnings.map { .string($0) })])
    }
}
