import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI

/// One `artifact.list` entry.
public struct ArtifactRow: Decodable, Identifiable, Equatable, Sendable {
    public let id: String, kind: String, title: String, file: String?, node: String?, by: String, at: Date, version: Int, url: String
    public let thumbnail: String?, status: String?, warnings: [String]
    /// The archived agent page (`collie-artifact://` URL); `importError` when its import failed.
    public let source: String?, importError: String?
    /// The user folder it is in (nil: "Sem pasta"); kept current from `artifact.folders` after a move.
    public internal(set) var folder: String?
    /// Remote resources the page still loads after its offline rewrite (nil: a record from before it).
    public let needsNetwork: [String]?
    public var isExport: Bool { kind == "export" }
    public var statusLabel: String {
        ["current": "atual", "stale": "desatualizado", "missing": "origem removida", "unknown": "desconhecido",
         "pending": "aguardando importação", "importing": "importando…", "failed": "falha na importação"][status ?? "unknown"] ?? (status ?? "desconhecido")
    }
    public var origin: String { isExport ? file.map { "tela \($0)" } ?? "tela removida" : "HTML do agente" }
}

/// One `artifact.folders` entry.
public struct ArtifactFolderRow: Decodable, Equatable, Sendable {
    public let path: String, count: Int, total: Int, color: String?, pinned: Bool, presentation: Bool, items: [String]
}

/// One section of the folder tree: a folder (`path` nil: "Sem pasta") and its own artifacts.
public struct FolderSection: Identifiable, Equatable {
    public let path: String?, name: String, depth: Int
    /// Artifacts in it and its subfolders (those matching the search).
    public let total: Int
    public let rows: [ArtifactRow]
    public let pinned: Bool, presentation: Bool, color: String?, collapsed: Bool, hasChildren: Bool
    public var id: String { path.map { ArtifactFolderTree.key($0) } ?? "\u{0}" }
}

/// The Artifacts panel's folders as a tree (pure: tested without the daemon). Siblings: pinned first, then the user's
/// order (`artifact.folders`), then by name; "Sem pasta" last. A search hides folders without a match.
public enum ArtifactFolderTree {
    /// Lowercased, as the daemon's `ArtifactFolder.same`.
    static func key(_ p: String) -> String { p.lowercased() }
    static func under(_ p: String?, _ f: String) -> Bool { p.map { key($0) == key(f) || key($0).hasPrefix(key(f) + "/") } ?? false }
    static func parent(_ p: String) -> String? { p.lastIndex(of: "/").map { String(p[..<$0]) } }

    public static func sections(rows: [ArtifactRow], folders: [ArtifactFolderRow], query: String = "", collapsed: Set<String> = []) -> [FolderSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? rows : rows.filter { $0.title.lowercased().contains(q) || ($0.folder ?? "").lowercased().contains(q) }
        var nodes: [String: (path: String, rank: Int, f: ArtifactFolderRow?)] = [:]
        for (i, f) in folders.enumerated() where nodes[key(f.path)] == nil { nodes[key(f.path)] = (f.path, i, f) }
        for p in rows.compactMap(\.folder) {
            var cur: String? = p
            while let c = cur { if nodes[key(c)] == nil { nodes[key(c)] = (c, .max, nil) }; cur = parent(c) }
        }
        func kids(_ of: String?) -> [(path: String, rank: Int, f: ArtifactFolderRow?)] {
            nodes.values.filter { parent($0.path).map(key) == of.map(key) }.sorted {
                if ($0.f?.pinned ?? false) != ($1.f?.pinned ?? false) { return $0.f?.pinned ?? false }
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
        }
        var out: [FolderSection] = []
        func emit(_ n: (path: String, rank: Int, f: ArtifactFolderRow?), depth: Int) {
            let total = shown.filter { under($0.folder, n.path) }.count
            if !q.isEmpty, total == 0 { return }
            var own = shown.filter { $0.folder.map(key) == key(n.path) }
            if n.f?.presentation == true, let items = n.f?.items {
                own = own.enumerated().sorted { a, b in
                    (items.firstIndex(of: a.element.id) ?? .max, a.offset) < (items.firstIndex(of: b.element.id) ?? .max, b.offset)
                }.map(\.element)
            }
            let shut = collapsed.contains(key(n.path)), children = kids(n.path)
            out.append(FolderSection(path: n.path, name: String(n.path.split(separator: "/").last ?? ""), depth: depth, total: total, rows: own,
                                     pinned: n.f?.pinned ?? false, presentation: n.f?.presentation ?? false, color: n.f?.color,
                                     collapsed: shut, hasChildren: !children.isEmpty))
            if !shut { children.forEach { emit($0, depth: depth + 1) } }
        }
        kids(nil).forEach { emit($0, depth: 0) }
        let loose = shown.filter { $0.folder == nil }
        if !loose.isEmpty {
            out.append(FolderSection(path: nil, name: "Sem pasta", depth: 0, total: loose.count, rows: loose, pinned: false, presentation: false,
                                     color: nil, collapsed: collapsed.contains("\u{0}"), hasChildren: false))
        }
        return out
    }

    /// `path` with its last name replaced by `name` (trimmed).
    public static func renamed(_ path: String, to name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return parent(path).map { "\($0)/\(n)" } ?? n
    }
}

/// The rows checked in "Selecionar" (pure: tested without the daemon). `anchor`: the last one clicked, where a
/// shift-click range starts.
public struct ArtifactSelection: Equatable {
    public private(set) var ids: Set<String> = []
    private var anchor: String?
    public init() {}
    public var count: Int { ids.count }
    public func contains(_ id: String) -> Bool { ids.contains(id) }
    public mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }
    /// Shift-click: every row from the anchor to `id` in `order` (the rows shown) checked.
    public mutating func extend(to id: String, in order: [String]) {
        guard let a = anchor.flatMap(order.firstIndex(of:)), let b = order.firstIndex(of: id) else { toggle(id); return }
        ids.formUnion(order[min(a, b)...max(a, b)])
        anchor = id
    }
    public func all(_ some: [String]) -> Bool { !some.isEmpty && some.allSatisfy(ids.contains) }
    /// "Selecionar todos" of a folder (or the search results): all checked, or all unchecked when they already were.
    public mutating func selectAll(_ some: [String]) { if all(some) { ids.subtract(some) } else { ids.formUnion(some) } }
    /// Only the ones still listed (after a refresh).
    public mutating func keep(_ listed: Set<String>) { ids.formIntersection(listed) }
    /// The rows shown, in order (open folders only): what ⌘A and a shift-click range cover.
    public static func visible(_ sections: [FolderSection]) -> [String] { sections.flatMap { $0.collapsed ? [] : $0.rows.map(\.id) } }
}

/// State and daemon calls of the Artifacts panel.
@MainActor public final class ArtifactsModel: ObservableObject {
    /// The Browser panel artifacts open in (created on first use).
    static let previewPanel = "Prévia"
    @Published public private(set) var rows: [ArtifactRow] = []
    @Published public private(set) var folders: [ArtifactFolderRow] = []
    /// The search and the folders shut (`FolderSection.id`s).
    @Published public var query = ""
    @Published public var collapsed: Set<String> = []
    public var sections: [FolderSection] { ArtifactFolderTree.sections(rows: rows, folders: folders, query: query, collapsed: collapsed) }
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false
    /// The "Importar do Claude…" sheet: its links' progress and the Claude terminals it can use.
    @Published public var claude = ClaudeImportProgress()
    @Published public private(set) var terminals: [ClaudeTerminalRow] = []
    /// "Selecionar": checkboxes on the rows and the bar of batch actions.
    @Published public var selecting = false { didSet { if !selecting { selection = ArtifactSelection() } } }
    @Published public var selection = ArtifactSelection()
    /// The compact list (true), the cards (false), or nil: compact only in a folder with more than 30 (remembered per user).
    @Published public private(set) var compact: Bool?
    private let defaults: UserDefaults
    private static let compactKey = "collie.artifacts.compact"
    public func isCompact(rows: Int) -> Bool { compact ?? (rows > 30) }
    public func toggleCompact() {
        compact = !(compact ?? false)
        defaults.set(compact, forKey: Self.compactKey)
    }

    private let call: PanelHostContext.Call
    private var coalescer: RefreshCoalescer?, folderCoalescer: RefreshCoalescer?
    public init(call: @escaping PanelHostContext.Call, window: Duration = .milliseconds(500), defaults: UserDefaults = .standard) {
        self.call = call
        self.defaults = defaults
        compact = defaults.object(forKey: Self.compactKey) as? Bool
        coalescer = RefreshCoalescer(window: window) { [weak self] in await self?.backgroundRefresh() }
        folderCoalescer = RefreshCoalescer(window: window) { [weak self] in
            guard let self else { return }
            if let e = await fetchFolders(), !busy { error = e }
        }
    }

    /// `artifact.*` events refresh the list (coalesced: at most one refresh per window); `artifact.changed` (a move or a
    /// folder change) only the folders: `artifact.list` asks the design engine for every export's stamp (seconds with 200+).
    public func handleEvent(_ name: String, _ payload: JSONValue = .null) async {
        guard name.hasPrefix("artifact.") else { return }
        claude.apply(name, payload)
        if name == "artifact.changed" { await folderCoalescer?.fire() }
        else if !name.hasPrefix("artifact.import.") { await coalescer?.fire() }
    }

    // MARK: import

    public func loadTerminals() async {
        guard let v = await send("artifact.import-terminals") else { return }
        terminals = (try? JSONDecoder().decode([ClaudeTerminalRow].self, from: JSONEncoder().encode(v))) ?? []
    }

    /// `links` sent to Claude terminal `terminal` (an id) to import into `folder` ("": none); true once sent.
    public func importClaude(_ links: [String], folder: String, terminal: String) async -> Bool {
        var nonce: String?
        await run {
            let v = await send("artifact.import-claude", ["urls": .string(links.joined(separator: " ")), "folder": .string(folder),
                                                          "terminal": .string(terminal)])
            if case .object(let o)? = v, case .string(let n)? = o["nonce"] { nonce = n }
        }
        if let nonce { claude.started(links, nonce: nonce) }
        return nonce != nil
    }

    /// The terminal lists the user's claude.ai artifacts (`artifact.import.list` brings them).
    public func listClaude(terminal: String) async {
        var nonce: String?
        await run {
            let v = await send("artifact.import-claude", ["mine": .bool(true), "terminal": .string(terminal)])
            if case .object(let o)? = v, case .string(let n)? = o["nonce"] { nonce = n }
        }
        if let nonce { claude.listingStarted(nonce: nonce) }
    }

    /// Files dropped on the panel (or a folder: `into`) added as artifacts, one after another; refusals as the error.
    public func drop(_ urls: [URL], into folder: String?) async {
        let (ok, refused) = ArtifactDrop.check(urls)
        var failed = refused
        await run {
            for u in ok {
                do throws(ProtocolError) {
                    _ = try await call("artifact.add", ["path": .string(u.path), "folder": .string(folder ?? "")])
                } catch { failed.append("\(u.lastPathComponent): \(error.message)") }
            }
        }
        if !ok.isEmpty { await refresh() }
        if !failed.isEmpty { error = failed.joined(separator: "\n") }   // after the refresh, which clears it
    }

    @discardableResult private func send(_ command: String, _ args: [String: JSONValue] = [:]) async -> JSONValue? {
        do { return try await call(command, args) } catch { self.error = error.message; return nil }
    }
    /// Runs `body` with `busy` set and the previous error cleared.
    private func run(_ body: () async -> Void) async {
        busy = true; error = nil
        await body()
        busy = false
    }

    public func refresh() async {
        await run { if let e = await fetchRows() { error = e } }
    }

    /// `artifact.list` into `rows`; the failure message, if any.
    private func fetchRows() async -> String? {
        do throws(ProtocolError) {
            let v = try await call("artifact.list", [:])
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            do { rows = try d.decode([ArtifactRow].self, from: JSONEncoder().encode(v)) } catch { return "lista inválida: \(error.localizedDescription)" }
            selection.keep(Set(rows.map(\.id)))
            return await fetchFolders()
        } catch { return error.message }
    }

    /// `artifact.folders` into `folders`, and each row's folder from their `items` (no `artifact.list`); the failure message, if any.
    private func fetchFolders() async -> String? {
        do throws(ProtocolError) {
            let f = try await call("artifact.folders", [:])
            do { folders = try JSONDecoder().decode([ArtifactFolderRow].self, from: JSONEncoder().encode(f)) } catch { return "pastas inválidas: \(error.localizedDescription)" }
            var at: [String: String] = [:]
            for f in folders { for id in f.items { at[id] = f.path } }
            let moved = rows.map { r in var r = r; r.folder = at[r.id]; return r }
            if moved != rows { rows = moved }
            return nil
        } catch { return error.message }
    }

    /// An event-driven refresh: never touches `busy`, never clears `error`; a failure shows only while no action runs.
    private func backgroundRefresh() async {
        if let e = await fetchRows(), !busy { error = e }
    }

    /// The panel closed: events no longer refresh.
    public func stop() { coalescer?.cancel(); folderCoalescer?.cancel() }

    /// Into the "Prévia" Browser panel; opens it when it doesn't exist yet.
    public func openInBrowser(_ row: ArtifactRow) async { await browse(row.url) }

    /// A Prévia on the artifact, docked right (where comments on it happen).
    public func openInPreview(_ row: ArtifactRow) async {
        await run { await send("panel.open", ["plugin": .string("preview"), "artifact": .string(row.id), "placement": .string("dock.right")]) }
    }

    /// The agent's original page, in the same Browser panel.
    public func openSource(_ row: ArtifactRow) async {
        if let source = row.source { await browse(source) }
    }

    private func browse(_ url: String) async {
        await run {
            do throws(ProtocolError) {
                _ = try await call("browser.navigate", ["panel": .string(Self.previewPanel), "url": .string(url)])
            } catch let e where e.code == .notFound {
                await send("panel.open", ["plugin": .string("browser"), "name": .string(Self.previewPanel), "url": .string(url)])
            } catch { self.error = error.message }
        }
    }

    /// An agent page's import: one that failed, or one still pending (e.g. cut short by a daemon restart). The app
    /// must be open now.
    public func reimport(_ row: ArtifactRow) async {
        guard row.status == "failed" || row.status == "pending" else { return }
        var ok = false
        await run { ok = await send("artifact.import", ["id": .string(row.id)]) != nil }
        if ok { await refresh() }
    }

    public func openInDesign(_ row: ArtifactRow) async {
        guard row.isExport, let file = row.file else { return }
        await run { await send("panel.open", ["plugin": .string("design"), "file": .string(file)]) }
    }

    public func reexport(_ row: ArtifactRow) async {
        guard row.isExport else { return }
        var ok = false
        await run { ok = await send("artifact.reexport", ["id": .string(row.id)]) != nil }
        if ok { await refresh() }
    }

    // MARK: folders

    /// Runs `command` (a move or a folder change), then refreshes the folders on success.
    private func change(_ command: String, _ args: [String: JSONValue]) async {
        await run { if await send(command, args) != nil, let e = await fetchFolders() { error = e } }
    }
    /// Artifact `id` into `folder` (nil: "Sem pasta").
    public func move(_ id: String, to folder: String?) async { await move([id], to: folder) }
    /// Many at once: one `artifact.move` (one write, all or nothing).
    public func move(_ ids: [String], to folder: String?) async {
        await change("artifact.move", ["ids": .array(ids.map { .string($0) }), "folder": .string(folder ?? "")])
    }
    /// The selection into `folder`, then out of "Selecionar" (kept when it failed).
    public func moveSelected(to folder: String?) async {
        await move(selection.ids.sorted(), to: folder)
        if error == nil { selecting = false }
    }
    /// The selection set aside, one `artifact.remove` each (the app's), then one refresh and out of "Selecionar".
    public func removeSelected() async {
        var failed: [String] = []
        await run {
            for id in selection.ids.sorted() {
                do throws(ProtocolError) { _ = try await call("artifact.remove", ["id": .string(id)]) } catch { failed.append(error.message) }
            }
        }
        await refresh()
        if failed.isEmpty { selecting = false } else { error = failed.joined(separator: "\n") }
    }
    public func createFolder(_ name: String, in parent: String?) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        await change("artifact.folder.create", ["path": .string(parent.map { "\($0)/\(n)" } ?? n)])
    }
    public func renameFolder(_ path: String, to name: String) async {
        await change("artifact.folder.rename", ["path": .string(path), "to": .string(ArtifactFolderTree.renamed(path, to: name))])
    }
    /// `emptying`: its artifacts go to "Sem pasta" first (never removed).
    public func removeFolder(_ path: String, emptying: Bool) async {
        await change("artifact.folder.remove", ["path": .string(path)].merging(emptying ? ["move-to": .string("")] : [:]) { a, _ in a })
    }
    public func setFolder(_ path: String, pinned: Bool? = nil, presentation: Bool? = nil) async {
        var args: [String: JSONValue] = ["path": .string(path)]
        if let pinned { args["pin"] = .string("\(pinned)") }
        if let presentation { args["present"] = .string("\(presentation)") }
        await change("artifact.folder.set", args)
    }
    public func toggle(_ s: FolderSection) { if collapsed.remove(s.id) == nil { collapsed.insert(s.id) } }

    public func remove(_ row: ArtifactRow) async {
        var ok = false
        await run { ok = await send("artifact.remove", ["id": .string(row.id)]) != nil }
        if ok { await refresh() }
    }
}

/// The Artifacts plug-in: a SwiftUI list over the `artifact.*` admin commands. No agent commands of its own.
@MainActor public final class ArtifactsPanel: PluginPanelView {
    let model: ArtifactsModel
    public let view: NSView
    public init(panel: Panel, host: PanelHostContext) {
        model = ArtifactsModel(call: host.call)
        view = NSHostingView(rootView: ArtifactsView(model: model))
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .notFound, message: "artifacts has no commands")
    }
    public func close() { model.stop() }   // later events' tasks find the coalescer closed
    public func receive(event: String, payload: JSONValue) { Task { [model] in await model.handleEvent(event, payload) } }
}

@MainActor private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); return f
}()

struct ArtifactsView: View {
    @ObservedObject var model: ArtifactsModel
    @State private var removing: ArtifactRow?
    /// **Nova pasta** (in a parent, nil: top) or **Renomear** (a path): the name being typed.
    private enum Naming: Equatable { case create(String?), rename(String) }
    @State private var naming: Naming?
    @State private var name = ""
    @State private var removingFolder: FolderSection?
    @State private var importing = false
    /// **Remover…** of the selection: asking.
    @State private var removingSelected = false

    var body: some View {
        // once per render: each row's "Mover para…" used to rebuild the tree (2 × 200 rows × the tree ≈ 0.6 s a render)
        let targets = ArtifactFolderTree.sections(rows: model.rows, folders: model.folders).filter { $0.path != nil }
        let sections = model.sections, visible = ArtifactSelection.visible(sections)
        return VStack(spacing: 0) {
            PanelHeader("Artifacts", subtitle: model.rows.count == 1 ? "1 página" : "\(model.rows.count) páginas") {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { model.toggleCompact() } label: {
                        Image(systemName: model.compact == true ? "rectangle.grid.1x2" : "list.bullet")
                    }
                    .help(model.compact == true ? "Mostrar cartões" : "Lista compacta")
                    .accessibilityLabel(model.compact == true ? "Mostrar cartões" : "Lista compacta").buttonStyle(CollieButtonStyle(.secondary))
                    Button(model.selecting ? "Concluir" : "Selecionar") { model.selecting.toggle() }.disabled(model.rows.isEmpty)
                        .buttonStyle(CollieButtonStyle(.secondary))
                    Button("Importar do Claude…") { importing = true }.disabled(model.busy).buttonStyle(CollieButtonStyle(.secondary))
                    Button("Nova pasta") { name = ""; naming = .create(nil) }.disabled(model.busy).buttonStyle(CollieButtonStyle(.secondary))
                    Button("Atualizar") { Task { await model.refresh() } }.disabled(model.busy).buttonStyle(CollieButtonStyle(.secondary))
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {   // lazy: only the cards on screen are built (and their thumbnails read)
                    if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
                    TextField("Buscar artifacts ou pastas", text: $model.query).textFieldStyle(.roundedBorder).font(.collieUI(13))
                    if model.selecting, !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !visible.isEmpty {
                        Button(model.selection.all(visible) ? "Desmarcar os resultados" : "Selecionar todos os resultados (\(visible.count))") {
                            model.selection.selectAll(visible)
                        }.buttonStyle(CollieButtonStyle(.quiet))
                    }
                    if model.rows.isEmpty { Text("Nenhum artifact.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                    ForEach(sections) { s in
                        folderHeader(s)
                        if !s.collapsed {
                            let compact = model.isCompact(rows: s.rows.count)
                            ForEach(s.rows) { r in
                                HStack(alignment: compact ? .center : .top, spacing: 8) {
                                    if model.selecting { checkbox(r, visible) }
                                    if compact { compactRow(r, targets) } else { row(r, targets) }
                                }
                                .padding(.leading, CGFloat(s.depth) * 16)
                            }
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.selecting { selectionBar(targets, visible) }
            PanelFooter("collie artifact add <página.html> · solte .html, pasta ou .zip aqui")
        }
        .background(Color.collieSidebar)
        .dropDestination(for: URL.self) { urls, _ in   // onto the panel: "Sem pasta"
            Task { await model.drop(urls, into: nil) }
            return !urls.isEmpty
        }
        .sheet(isPresented: $importing) { ClaudeImportSheet(model: model, shown: $importing) }
        .task { await model.refresh() }
        .confirmationDialog("Remover \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { r in
            Button("Remover", role: .destructive) { Task { await model.remove(r) } }
        } message: { _ in Text("A pasta vai para artifacts/.removed.") }
        .alert(naming.map { if case .rename = $0 { "Renomear pasta" } else { "Nova pasta" } } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nome", text: $name)
            Button("OK") {
                let n = naming; naming = nil
                Task {
                    switch n {
                    case .create(let parent)?: await model.createFolder(name, in: parent)
                    case .rename(let path)?: await model.renameFolder(path, to: name)
                    case nil: break
                    }
                }
            }
            Button("Cancelar", role: .cancel) { naming = nil }
        } message: { Text("Até 3 níveis; cada nome com até 40 caracteres.") }
        .confirmationDialog("Remover a pasta \(removingFolder?.name ?? "")?", isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }),
                            titleVisibility: .visible, presenting: removingFolder) { s in
            Button(s.total == 0 ? "Remover" : "Mover artifacts para Sem pasta e remover", role: .destructive) {
                Task { if let p = s.path { await model.removeFolder(p, emptying: s.total > 0) } }
            }
        } message: { s in Text(s.total == 0 ? "A pasta está vazia." : "Nenhum artifact é apagado.") }
        .confirmationDialog("Remover \(model.selection.count == 1 ? "1 artifact" : "\(model.selection.count) artifacts")?", isPresented: $removingSelected,
                            titleVisibility: .visible) {
            Button("Remover", role: .destructive) { Task { await model.removeSelected() } }
        } message: { Text("As pastas deles vão para artifacts/.removed.") }
    }

    /// The row's checkbox; shift-click checks the range from the last one clicked.
    private func checkbox(_ r: ArtifactRow, _ visible: [String]) -> some View {
        let on = model.selection.contains(r.id)
        return Button {
            if NSEvent.modifierFlags.contains(.shift) { model.selection.extend(to: r.id, in: visible) } else { model.selection.toggle(r.id) }
        } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                .foregroundStyle(on ? Color.collieAccent : Color.collieMuted)
        }
        .buttonStyle(.plain).accessibilityLabel(r.title).accessibilityValue(on ? "selecionado" : "não selecionado")
    }

    /// "N selecionados" · **Mover para…** · **Remover…** · **Cancelar**; ⌘A checks every row shown.
    private func selectionBar(_ targets: [FolderSection], _ visible: [String]) -> some View {
        let n = model.selection.count
        return HStack(spacing: 8) {
            Text(n == 1 ? "1 selecionado" : "\(n) selecionados").font(.collieMono(12)).foregroundStyle(Color.collieText)
            Button("Selecionar todos") { model.selection.selectAll(visible.filter { !model.selection.contains($0) }) }
                .keyboardShortcut("a", modifiers: .command).buttonStyle(CollieButtonStyle(.quiet))
            Spacer(minLength: 0)
            Menu("Mover para…") {
                Button("Sem pasta") { Task { await model.moveSelected(to: nil) } }
                ForEach(targets) { t in
                    Button(String(repeating: "  ", count: t.depth) + t.name) { Task { await model.moveSelected(to: t.path) } }
                }
            }
            .fixedSize().disabled(n == 0 || model.busy)
            Button("Remover…", role: .destructive) { removingSelected = true }.disabled(n == 0 || model.busy).buttonStyle(CollieButtonStyle(.quiet))
            Button("Cancelar") { model.selecting = false }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary))
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(Color.collieSunken)
    }

    /// One line: a small thumbnail, title, state, folder; the card's actions in its menu.
    private func compactRow(_ r: ArtifactRow, _ targets: [FolderSection]) -> some View {
        HStack(spacing: 8) {
            Thumbnail(path: r.isExport ? r.thumbnail : nil, height: 28).frame(width: 44).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(r.title).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
            if !r.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.collieAttention)
                    .help(r.warnings.joined(separator: "\n")).accessibilityLabel("Avisos: " + r.warnings.joined(separator: ", "))
            }
            Spacer(minLength: 0)
            if let f = r.folder { Text(f).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1) }
            Text(r.statusLabel).font(.collieMono(11, r.status == "stale" ? .semibold : .medium)).foregroundStyle(statusColor(r)).help(r.importError ?? "")
            Menu {
                Button("Abrir na Prévia") { Task { await model.openInPreview(r) } }
                Button("Abrir no Navegador") { Task { await model.openInBrowser(r) } }
                moveMenu(r, targets)
                Divider()
                Button("Remover…", role: .destructive) { removing = r }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.busy).accessibilityLabel("Ações de \(r.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .collieCard(highlight: r.status == "stale" ? Color.collieAttention : nil)
        .draggable(r.id)
        .contextMenu { moveMenu(r, targets) }
    }

    /// The folder's line: chevron, name, count; drop an artifact on it to move it there; its menu.
    private func folderHeader(_ s: FolderSection) -> some View {
        Button { model.toggle(s) } label: {
            HStack(spacing: 6) {
                Image(systemName: s.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    .opacity(s.hasChildren || !s.rows.isEmpty ? 1 : 0.3).accessibilityHidden(true)
                Image(systemName: s.path == nil ? "tray" : s.presentation ? "play.rectangle" : "folder").accessibilityHidden(true)
                Text(s.name).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                if s.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).accessibilityLabel("Fixada") }
                Text("\(s.total)").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                Spacer(minLength: 0)
                if model.selecting, !s.rows.isEmpty {
                    let ids = s.rows.map(\.id)
                    Button(model.selection.all(ids) ? "Desmarcar todos" : "Selecionar todos") { model.selection.selectAll(ids) }
                        .buttonStyle(CollieButtonStyle(.quiet))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.collieMuted)
        .padding(.leading, CGFloat(s.depth) * 16).padding(.top, 4)
        .accessibilityLabel("\(s.path ?? s.name), \(s.total) artifacts, \(s.collapsed ? "recolhida" : "aberta")")
        .dropDestination(for: String.self) { ids, _ in
            // a row's id moves it (a selected one: the whole selection, in one move); a file from the Finder (its file URL) is added into the folder
            let files = ids.compactMap { $0.hasPrefix("file://") ? URL(string: $0) : nil }
            let rows = ids.filter { !$0.hasPrefix("file://") }
            let selected = model.selecting && rows.contains(where: model.selection.contains)
            Task {
                if selected { await model.moveSelected(to: s.path) } else if !rows.isEmpty { await model.move(rows, to: s.path) }
                if !files.isEmpty { await model.drop(files, into: s.path) }
            }
            return !ids.isEmpty
        }
        .contextMenu {
            if let p = s.path {
                if s.depth < 2 { Button("Nova pasta dentro") { name = ""; naming = .create(p) } }
                Button("Renomear…") { name = s.name; naming = .rename(p) }
                Button(s.pinned ? "Desafixar" : "Fixar no topo") { Task { await model.setFolder(p, pinned: !s.pinned) } }
                Button(s.presentation ? "Deixar de ser apresentação" : "Apresentação (páginas em ordem)") {
                    Task { await model.setFolder(p, presentation: !s.presentation) }
                }
                Divider()
                Button("Remover…", role: .destructive) { removingFolder = s }
            }
        }
    }

    /// **Mover para…**: every folder (`targets`), and "Sem pasta".
    private func moveMenu(_ r: ArtifactRow, _ targets: [FolderSection]) -> some View {
        Menu("Mover para…") {
            Button("Sem pasta") { Task { await model.move(r.id, to: nil) } }.disabled(r.folder == nil)
            ForEach(targets) { t in
                Button(String(repeating: "  ", count: t.depth) + t.name) { Task { await model.move(r.id, to: t.path) } }
                    .disabled(t.path.map(ArtifactFolderTree.key) == r.folder.map(ArtifactFolderTree.key))
            }
        }
    }

    /// The state is text in DM Mono; its color only repeats it.
    private func statusColor(_ r: ArtifactRow) -> Color {
        switch r.status {
        case "current": .collieAccent
        case "stale": .collieAttention
        case "importing": .collieSecondary
        case "failed": .collieDanger
        default: .collieMuted
        }
    }

    private func row(_ r: ArtifactRow, _ targets: [FolderSection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(path: r.isExport ? r.thumbnail : nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(r.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                    if !r.warnings.isEmpty {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.collieAttention)
                            .help(r.warnings.joined(separator: "\n")).accessibilityLabel("Avisos: " + r.warnings.joined(separator: ", "))
                    }
                    Spacer(minLength: 0)
                    Text(r.statusLabel).font(.collieMono(11, r.status == "stale" ? .semibold : .medium)).foregroundStyle(statusColor(r))
                        .help(r.importError ?? "")
                }
                Text("\(r.origin) · v\(r.version)").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                if let net = r.needsNetwork, !net.isEmpty {
                    Label("precisa de rede", systemImage: "wifi").font(.collieMono(11)).foregroundStyle(Color.collieAttention)
                        .help(net.joined(separator: "\n")).accessibilityLabel("Precisa de rede: " + net.joined(separator: ", "))
                }
                Text("por \(r.by) · \(relative.localizedString(for: r.at, relativeTo: Date()))").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                if r.status == "importing" { ProgressView().progressViewStyle(.linear).tint(Color.collieSecondary) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if r.isExport { Button("Reexportar") { Task { await model.reexport(r) } }.buttonStyle(CollieButtonStyle(.attention)) }
                        Button("Abrir no Navegador") { Task { await model.openInBrowser(r) } }
                        Button("Abrir na Prévia") { Task { await model.openInPreview(r) } }
                        if r.status == "failed" { Button("Importar de novo") { Task { await model.reimport(r) } } }
                        if r.status == "pending" { Button("Importar") { Task { await model.reimport(r) } } }
                    }
                    HStack(spacing: 6) {
                        if r.source != nil { Button("Abrir origem") { Task { await model.openSource(r) } } }
                        if r.isExport, r.file != nil { Button("Abrir no Design") { Task { await model.openInDesign(r) } } }
                        moveMenu(r, targets).fixedSize()
                        Button("Remover…", role: .destructive) { removing = r }.buttonStyle(CollieButtonStyle(.quiet))
                    }
                }
                .buttonStyle(CollieButtonStyle(.secondary)).disabled(model.busy).padding(.top, 4)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .collieCard(highlight: r.status == "stale" ? Color.collieAttention : nil)
        .draggable(r.id)
        .contextMenu { moveMenu(r, targets) }
    }
}

/// 120 pt tall (the compact row's: 28), the card's width; the file is read off the main thread. No path (agent page, or no
/// thumbnail yet): a document icon.
private struct Thumbnail: View {
    let path: String?
    var height: CGFloat = 120
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: "doc.richtext").font(.system(size: height < 60 ? 14 : 28)).foregroundStyle(Color.collieMuted).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity).frame(height: height).background(Color.collieSunken)
        .task(id: path) {
            guard let path else { image = nil; return }
            let data = await Task.detached { FileManager.default.contents(atPath: path) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
