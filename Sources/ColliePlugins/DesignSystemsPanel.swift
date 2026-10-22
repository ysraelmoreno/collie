import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI

public struct DesignSystemRow: Decodable, Identifiable, Equatable, Sendable {
    public let name: String, version: Int, active: [String], reverted: Int?
    public var id: String { name }
}
public struct DesignFileOutcome: Decodable, Identifiable, Equatable, Sendable {
    public let file: String, ok: Bool, detail: String, unmatched: [String]?
    public var id: String { file }
}
public struct DesignEventRow: Decodable, Identifiable, Equatable, Sendable {
    public let at: Date, kind: String, version: Int?, scope: String?, by: String, reason: String, files: [DesignFileOutcome]?
    public var id: String { "\(at.timeIntervalSince1970)-\(kind)-\(version ?? 0)" }
    /// A scope's undo: `undone`, or `reverted` with a scope in histories from before that kind.
    public var isUndo: Bool { kind == "undone" || (kind == "reverted" && scope != nil) }
    /// "Voltar para esta versão": every version event (created, published, reverted; no scope) has a snapshot.
    public var canRevert: Bool { ["created", "published", "reverted"].contains(kind) && scope == nil && version != nil }
    public var label: String {
        if isUndo { return "desfeito" }
        return ["created": "criado", "published": "publicado", "reverted": "revertido", "activated": "ativado"][kind] ?? kind
    }
}

/// State and daemon calls of the Design Systems panel. Every write needs a `reason`.
@MainActor public final class DesignSystemsModel: ObservableObject {
    @Published public private(set) var systems: [DesignSystemRow] = []
    @Published public private(set) var paddocks: [String] = []
    @Published public var selected: String? {
        didSet { if selected != oldValue { offerForce = false; history = [] } }
    }
    /// "workspace" or "paddock:<name>".
    @Published public var scope = "workspace"
    @Published public var reason = ""
    @Published public var newName = ""
    @Published public var newFrom = ""
    @Published public private(set) var history: [DesignEventRow] = []
    /// Per-file outcomes of the last action (with their `unmatched`).
    @Published public private(set) var results: [DesignFileOutcome] = []
    @Published public private(set) var error: String?
    /// The last publish was refused because the system was reverted: the user may force it.
    @Published public private(set) var offerForce = false

    private let call: PanelHostContext.Call
    private var coalescer: RefreshCoalescer?
    public init(call: @escaping PanelHostContext.Call, window: Duration = .milliseconds(500)) {
        self.call = call
        coalescer = RefreshCoalescer(window: window) { [weak self] in await self?.load(clearError: false, background: true) }
    }

    public var scopes: [String] { ["workspace"] + paddocks.map { "paddock:\($0)" } }
    public var canWrite: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var paddockArg: [String: JSONValue] { scope.hasPrefix("paddock:") ? ["paddock": .string(String(scope.dropFirst(8)))] : [:] }

    private func decode<T: Decodable>(_ v: JSONValue?) -> T? {
        guard let v, let data = try? JSONEncoder().encode(v) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }
    /// Writes running now: a background reload's failure shows only while none runs (as in Artifacts).
    private var acting = 0
    private func send(_ command: String, _ args: [String: JSONValue] = [:], background: Bool = false) async -> JSONValue? {
        do { return try await call(command, args) } catch {
            if !background || acting == 0 { self.error = error.message }
            return nil
        }
    }

    public func load(clearError: Bool = true, background: Bool = false) async {
        if clearError { error = nil }
        struct F: Decodable { var name: String }
        if let f: [F] = decode(await send("paddock.list", background: background)) { paddocks = f.map(\.name) }
        if let s: [DesignSystemRow] = decode(await send("design.system.list", background: background)) { systems = s }
        if selected == nil || !systems.contains(where: { $0.name == selected }) { selected = systems.first?.name }
        if !scopes.contains(scope) { scope = "workspace" }
        if !history.isEmpty { await showHistory(background: background) }
    }
    /// The panel closed: events no longer reload.
    public func stop() { coalescer?.cancel() }
    /// `designsystem.changed` reloads (coalesced: at most one reload per window).
    public func handleEvent(_ name: String) async { if name == "designsystem.changed" { await coalescer?.fire() } }

    public func showHistory(background: Bool = false) async {
        guard let name = selected else { return }
        let h: [DesignEventRow]? = decode(await send("design.system.history", ["name": .string(name)], background: background))
        guard selected == name, let h else { return }   // a newer selection owns the history now
        history = h.reversed()
    }

    /// Runs a write with the reason; shows per-file outcomes; refreshes.
    @discardableResult private func write(_ command: String, _ args: [String: JSONValue]) async -> Bool {
        guard canWrite else { return false }
        acting += 1; defer { acting -= 1 }
        error = nil; results = []; offerForce = false
        var a = args; a["reason"] = .string(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let r = await send(command, a) else { return false }
        if case .object(let o) = r, let files: [DesignFileOutcome] = decode(o["files"]) { results = files }
        reason = ""
        await load(clearError: false)
        return true
    }
    public func use() async { guard let selected else { return }; await write("design.system.use", paddockArg.merging(["name": .string(selected)]) { a, _ in a }) }
    public func clear() async { await write("design.system.use", paddockArg.merging(["none": .bool(true)]) { a, _ in a }) }
    public func undo() async { await write("design.system.undo", paddockArg) }
    public func create() async {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var a: [String: JSONValue] = ["name": .string(n)]
        if !newFrom.isEmpty { a["from"] = .string(newFrom) }
        if await write("design.system.create", a) { newName = ""; newFrom = ""; selected = n; await showHistory() }
    }
    public func publish(force: Bool = false) async {
        guard let selected else { return }
        var a: [String: JSONValue] = ["name": .string(selected)]
        if force { a["force"] = .bool(true) }
        if await write("design.system.publish", a) { await showHistory(); return }
        // refused for a reverted system: the daemon's message stays in `error`, the user may force it
        if let error, error.contains("was reverted to"), systems.first(where: { $0.name == selected })?.reverted != nil { offerForce = true }
    }
    public func revert(to version: Int) async {
        guard let selected else { return }
        if await write("design.system.revert", ["name": .string(selected), "to": .number(Double(version))]) { await showHistory() }
    }
}

/// The Design Systems plug-in: a SwiftUI panel over the `design.system.*` admin commands. No agent commands.
@MainActor public final class DesignSystemsPanel: PluginPanelView {
    let model: DesignSystemsModel
    public let view: NSView
    public init(panel: Panel, host: PanelHostContext) {
        model = DesignSystemsModel(call: host.call)
        view = NSHostingView(rootView: DesignSystemsView(model: model))
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .notFound, message: "designsystems has no commands")
    }
    public func close() { model.stop() }   // later events' tasks find the coalescer closed
    public func receive(event: String, payload: JSONValue) { Task { [model] in await model.handleEvent(event) } }
}

@MainActor private let when: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateStyle = .short; f.timeStyle = .short; return f
}()

struct DesignSystemsView: View {
    @ObservedObject var model: DesignSystemsModel
    @State private var confirmForce = false
    @State private var showNew = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Design systems")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Motivo (obrigatório)", text: $model.reason).collieField()
                    if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
                    if model.offerForce { Button("Publicar mesmo assim…") { confirmForce = true }.buttonStyle(CollieButtonStyle(.attention)) }
                    results
                    if model.systems.isEmpty { Text("Nenhum design system.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                    ForEach(model.systems) { s in
                        let on = model.selected == s.name
                        Button { model.selected = s.name; Task { await model.showHistory() } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(s.name).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                                        Text("v\(s.version)").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                                    }
                                    Text(s.active.isEmpty ? "não está ativo" : "ativo: " + s.active.joined(separator: ", "))
                                        .font(.collieMono(11)).foregroundStyle(s.active.isEmpty ? Color.collieMuted : .collieAccent)
                                    if let r = s.reverted { Text("voltou para v\(r)").font(.collieMono(11)).foregroundStyle(Color.collieAttention) }
                                }
                                Spacer()
                            }
                            .padding(12).contentShape(RoundedRectangle(cornerRadius: 14))
                            .collieCard(highlight: on ? Color.collieAccent : nil)
                        }
                        .buttonStyle(.plain)   // system focus ring is kept
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    HStack(spacing: 6) {
                        Picker("Escopo", selection: $model.scope) { ForEach(model.scopes, id: \.self) { Text($0 == "workspace" ? "Workspace" : "Cercado \($0.dropFirst(8))").tag($0) } }
                            .labelsHidden().fixedSize()
                        Button("Usar neste escopo") { Task { await model.use() } }.disabled(!model.canWrite || model.selected == nil)
                            .buttonStyle(CollieButtonStyle(.primary))
                    }
                    HStack(spacing: 6) {
                        Button("Desfazer troca") { Task { await model.undo() } }.disabled(!model.canWrite)
                        Button("Nenhum neste escopo") { Task { await model.clear() } }.disabled(!model.canWrite)
                        Button("Publicar versão") { Task { await model.publish() } }.disabled(!model.canWrite || model.selected == nil)
                    }.buttonStyle(CollieButtonStyle(.secondary))
                    DisclosureGroup("Novo design system…", isExpanded: $showNew) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Nome", text: $model.newName).collieField()
                            Picker("A partir de", selection: $model.newFrom) {
                                Text("(vazio)").tag(""); ForEach(model.systems) { Text($0.name).tag($0.name) }
                            }
                            Button("Criar") { Task { await model.create() } }
                                .disabled(!model.canWrite || model.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                                .buttonStyle(CollieButtonStyle(.secondary))
                        }.padding(.top, 6)
                    }.font(.collieUI(13)).foregroundStyle(Color.collieText)
                    Rectangle().fill(Color.collieBorder).frame(height: 1)
                    Text("Histórico").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    if model.history.isEmpty { Text("Selecione um design system.").font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                    ForEach(model.history) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                CollieTag(e.label, tone: .neutral)
                                Text("\(e.version.map { "v\($0)" } ?? "")\(e.scope.map { " · \($0)" } ?? "")").font(.collieMono(12)).foregroundStyle(Color.collieText)
                            }
                            Text("\(when.string(from: e.at)) · \(e.by) · \(e.reason)").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                            ForEach(e.files ?? []) { outcome($0) }
                            if e.canRevert, let v = e.version {
                                Button("Voltar para esta versão") { Task { await model.revert(to: v) } }
                                    .disabled(!model.canWrite).buttonStyle(CollieButtonStyle(.secondary))
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).collieCard()
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            PanelFooter(model.systems.count == 1 ? "1 design system" : "\(model.systems.count) design systems", trailing: model.scope == "workspace" ? "workspace" : "cercado \(model.scope.dropFirst(8))")
        }
        .background(Color.collieSidebar)
        .task { await model.load() }
        .confirmationDialog("Publicar \(model.selected ?? "") mesmo assim?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Publicar \(model.selected ?? "") mesmo assim", role: .destructive) { Task { await model.publish(force: true) } }
        } message: { Text("O arquivo será publicado como está e a marca de \"voltou\" será limpa.") }
    }

    @ViewBuilder private var results: some View {
        if !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resultado por arquivo").font(.collieUI(12, .semibold)).foregroundStyle(Color.collieText)
                ForEach(model.results) { outcome($0) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).collieCard()
        }
    }
    private func outcome(_ o: DesignFileOutcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(o.ok ? "✓" : "✕") \(o.file): \(o.detail)").font(.collieMono(11)).foregroundStyle(o.ok ? Color.collieMuted : .collieDanger)
            if let u = o.unmatched, !u.isEmpty {
                Text("sem par: " + u.joined(separator: ", ")).font(.collieMono(11)).foregroundStyle(Color.collieAttention)
            }
        }
    }
}
