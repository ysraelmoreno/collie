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
    public var isExport: Bool { kind == "export" }
    public var statusLabel: String {
        ["current": "atual", "stale": "desatualizado", "missing": "origem removida", "unknown": "desconhecido",
         "pending": "aguardando importação", "importing": "importando…", "failed": "falha na importação"][status ?? "unknown"] ?? (status ?? "desconhecido")
    }
    public var origin: String { isExport ? file.map { "tela \($0)" } ?? "tela removida" : "HTML do agente" }
}

/// State and daemon calls of the Artifacts panel.
@MainActor public final class ArtifactsModel: ObservableObject {
    /// The Browser panel artifacts open in (created on first use).
    static let previewPanel = "Prévia"
    @Published public private(set) var rows: [ArtifactRow] = []
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false

    private let call: PanelHostContext.Call
    private var coalescer: RefreshCoalescer?
    public init(call: @escaping PanelHostContext.Call, window: Duration = .milliseconds(500)) {
        self.call = call
        coalescer = RefreshCoalescer(window: window) { [weak self] in await self?.backgroundRefresh() }
    }

    /// `artifact.*` events refresh the list (coalesced: at most one refresh per window).
    public func handleEvent(_ name: String) async { if name.hasPrefix("artifact.") { await coalescer?.fire() } }

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
            return nil
        } catch { return error.message }
    }

    /// An event-driven refresh: never touches `busy`, never clears `error`; a failure shows only while no action runs.
    private func backgroundRefresh() async {
        if let e = await fetchRows(), !busy { error = e }
    }

    /// The panel closed: events no longer refresh.
    public func stop() { coalescer?.cancel() }

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
    public func receive(event: String, payload: JSONValue) { Task { [model] in await model.handleEvent(event) } }
}

@MainActor private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); return f
}()

struct ArtifactsView: View {
    @ObservedObject var model: ArtifactsModel
    @State private var removing: ArtifactRow?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Artifacts", subtitle: model.rows.count == 1 ? "1 página" : "\(model.rows.count) páginas") {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Atualizar") { Task { await model.refresh() } }.disabled(model.busy).buttonStyle(CollieButtonStyle(.secondary))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
                    if model.rows.isEmpty { Text("Nenhum artifact.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                    ForEach(model.rows) { row($0) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            PanelFooter("collie artifact add <página.html>")
        }
        .background(Color.collieSidebar)
        .task { await model.refresh() }
        .confirmationDialog("Remover \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { r in
            Button("Remover", role: .destructive) { Task { await model.remove(r) } }
        } message: { _ in Text("A pasta vai para artifacts/.removed.") }
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

    private func row(_ r: ArtifactRow) -> some View {
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
    }
}

/// 120 pt tall, the card's width; the file is read off the main thread. No path (agent page, or no thumbnail yet): a document icon.
private struct Thumbnail: View {
    let path: String?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: "doc.richtext").font(.system(size: 28)).foregroundStyle(Color.collieMuted).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity).frame(height: 120).background(Color.collieSunken)
        .task(id: path) {
            guard let path else { image = nil; return }
            let data = await Task.detached { FileManager.default.contents(atPath: path) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
