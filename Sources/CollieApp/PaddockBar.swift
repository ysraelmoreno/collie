import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

extension PaddockStatus {
    /// Working and review share `secondary`: the symbol shape (and the label) tells them apart.
    var color: Color { switch self { case .working, .review: .collieSecondary; case .blocked: .collieAttention; case .done: .collieAccent } }
    /// A distinct shape per status, so a chip never shows state by color alone.
    var symbol: String { switch self { case .working: "circle.fill"; case .review: "circle"; case .blocked: "exclamationmark.circle.fill"; case .done: "checkmark.circle.fill" } }
    var label: String { switch self { case .working: "Trabalhando"; case .blocked: "Bloqueado"; case .review: "Em revisão"; case .done: "Concluído" } }
    static let menuOrder: [PaddockStatus] = [.working, .blocked, .review, .done]
}

/// The paddock status mark: shape plus color (decorative; the label carries it for VoiceOver).
struct PaddockStatusDot: View {
    let status: PaddockStatus?
    var body: some View {
        Image(systemName: status?.symbol ?? "circle.fill").font(.system(size: 8, weight: .bold))
            .foregroundStyle(status?.color ?? Color.collieMuted).accessibilityHidden(true)
    }
}

extension LandMode {
    static let menuOrder: [LandMode] = [.merge, .squash, .rebase, .pr]
    var label: String { switch self { case .merge: "Merge"; case .squash: "Squash"; case .rebase: "Rebase"; case .pr: "Abrir PR" } }
}

/// The paddock actions (select, create, status, land, delete), shared by the chips, the sidebar, the header menu and
/// the command palette. Daemon calls are async; land can take minutes, so land/delete are disabled while any call
/// runs (`busy`) and the UI never waits on them. The prompt, alert and dialogs are attached once by `paddockDialogs`.
@MainActor @Observable final class PaddockActions {
    static let currentKey = "paddock.current", repoKey = "paddock.repo"
    let client: DaemonClient
    private(set) var running = 0   // daemon calls in flight
    var busy: Bool { running > 0 }
    var newName: String?   // non-nil: the "Novo cercado" prompt is open
    var message: String?   // alert text (errors, land conflicts, results)
    var confirmDelete = false
    var forceDelete = false
    var deleting: Paddock?   // the dialog's paddock
    var choosingStatus: Paddock?   // the palette's status dialog
    var choosingLand: Paddock?     // the palette's land dialog

    init(client: DaemonClient) { self.client = client }

    func select(_ id: UUID?) {
        client.currentPaddock = id
        UserDefaults.standard.set(id?.uuidString ?? "", forKey: Self.currentKey)
    }

    func newPaddock() { newName = "" }

    func setStatus(_ f: Paddock, _ s: PaddockStatus) { run { [client] in try await client.setPaddockStatus(f.name, s) } }

    func askDelete(_ f: Paddock) { deleting = f; forceDelete = false; confirmDelete = true }

    /// ⌘K: the paddock menu's actions for `f` (Land / Excluir only while nothing runs, as in the menu).
    func commands(for f: Paddock) -> [PaletteCommand] {
        [PaletteCommand(id: "paddock.status", title: "Status do cercado \(f.name)…", run: { self.choosingStatus = f })]
            + (busy ? [] : [PaletteCommand(id: "paddock.land", title: "Land \(f.name)…", run: { self.choosingLand = f }),
                            PaletteCommand(id: "paddock.delete", title: "Excluir cercado \(f.name)…", run: { self.askDelete(f) })])
    }

    func create() {
        guard let name = PaddockName.slug(newName ?? "") else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = "Repositório git do cercado"
        if let last = UserDefaults.standard.string(forKey: Self.repoKey) { p.directoryURL = URL(fileURLWithPath: last) }
        guard p.runModal() == .OK, let repo = p.url?.path else { return }
        UserDefaults.standard.set(repo, forKey: Self.repoKey)
        newName = nil
        run { [self] in
            try await client.createPaddock(name: name, repo: repo)
            if let f = client.paddocks.first(where: { $0.name == name }) { select(f.id) }
        }
    }

    func land(_ f: Paddock, _ mode: LandMode) {
        run { [self] in
            let r = try await client.land(f.name, mode: mode)
            if let pr = r.prURL { message = "PR aberto: \(pr)" }
            else if let c = r.commit { message = "Cercado integrado (\(String(c.prefix(8))))." }
        }
    }

    func delete(force: Bool) {
        guard let f = deleting, client.paddocks.contains(where: { $0.id == f.id }) else { return }   // gone meanwhile
        run { [self] in
            try await client.deletePaddock(f.name, force: force)
            if client.currentPaddock == f.id { select(nil) }
        } onError: { [self] m in
            // unmerged / uncommitted changes: offer to force
            if !force, m.contains("not merged") || m.contains("--force") || m.contains("modified or untracked") {
                message = nil   // the dialog explains it; an alert at the same time would collide with it
                forceDelete = true; confirmDelete = true
            }
        }
    }

    /// Runs a daemon call off the click; failures (land conflicts included) go to the alert.
    func run(_ op: @escaping @MainActor () async throws -> Void, onError: (@MainActor (String) -> Void)? = nil) {
        running += 1
        Task {
            defer { running -= 1 }
            do { try await op() }
            catch let e as ProtocolError { message = e.message; onError?(e.message) }
            catch { message = "\(error)" }
        }
    }
}

/// A paddock's menu items (Status, Land, Excluir…), for a `Menu` or a `contextMenu`.
struct PaddockMenu: View {
    let paddock: Paddock
    let actions: PaddockActions

    var body: some View {
        Menu("Status") {
            ForEach(PaddockStatus.menuOrder, id: \.self) { s in
                Button(s.label) { actions.setStatus(paddock, s) }
            }
        }
        Menu("Land") {
            ForEach(LandMode.menuOrder, id: \.self) { m in Button(m.label) { actions.land(paddock, m) } }
        }.disabled(actions.busy)
        Divider()
        Button("Excluir…") { actions.askDelete(paddock) }.disabled(actions.busy)
    }
}

struct NewPaddockButton: View {
    let actions: PaddockActions
    var body: some View { Button("Novo cercado…") { actions.newPaddock() } }
}

extension View {
    /// The "Novo cercado" prompt, the result/error alert and the delete confirmation, attached once per window.
    func paddockDialogs(_ a: PaddockActions) -> some View { modifier(PaddockDialogs(actions: a)) }
}

private struct PaddockDialogs: ViewModifier {
    @Bindable var actions: PaddockActions

    func body(content: Content) -> some View {
        let name = actions.deleting?.name ?? ""
        content
            .sheet(isPresented: Binding(get: { actions.newName != nil }, set: { if !$0 { actions.newName = nil } })) { newSheet }
            .alert("Cercado", isPresented: Binding(get: { actions.message != nil }, set: { if !$0 { actions.message = nil } })) {
                Button("OK") {}
            } message: { Text(actions.message ?? "") }
            .confirmationDialog(actions.forceDelete ? "Forçar a exclusão de \(name)?" : "Excluir o cercado \(name)?",
                                isPresented: $actions.confirmDelete) {
                Button(actions.forceDelete ? "Forçar exclusão" : "Excluir", role: .destructive) { actions.delete(force: actions.forceDelete) }
            } message: {
                Text(actions.forceDelete ? "Alterações não commitadas ou não integradas serão perdidas." : "Remove o worktree e o branch.")
            }
            .confirmationDialog("Status do cercado \(actions.choosingStatus?.name ?? "")", isPresented: shown(\.choosingStatus),
                                presenting: actions.choosingStatus) { f in
                ForEach(PaddockStatus.menuOrder, id: \.self) { s in Button(s.label) { actions.setStatus(f, s) } }
            }
            .confirmationDialog("Land \(actions.choosingLand?.name ?? "")", isPresented: shown(\.choosingLand),
                                presenting: actions.choosingLand) { f in
                ForEach(LandMode.menuOrder, id: \.self) { m in Button(m.label) { actions.land(f, m) }.disabled(actions.busy) }
            }
    }

    private func shown(_ k: ReferenceWritableKeyPath<PaddockActions, Paddock?>) -> Binding<Bool> {
        Binding(get: { actions[keyPath: k] != nil }, set: { if !$0 { actions[keyPath: k] = nil } })
    }

    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Novo cercado").font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
            TextField("Nome do cercado", text: Binding(get: { actions.newName ?? "" }, set: { actions.newName = $0 }))
                .collieField(mono: true)
            if let typed = actions.newName, !typed.isEmpty {
                let slug = PaddockName.slug(typed)
                Text(slug.map { $0 == typed ? "Nome: \($0)" : "Será criado como: \($0)" } ?? "Use letras ou números")
                    .font(.collieMono(12)).foregroundStyle(slug == nil ? Color.collieDanger : Color.collieMuted)
            }
            Text("Repositório: \(UserDefaults.standard.string(forKey: PaddockActions.repoKey) ?? "escolha ao criar")")
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { actions.newName = nil }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary))
                Button("Escolher repositório e criar…") { actions.create() }.keyboardShortcut(.defaultAction)
                    .disabled(PaddockName.slug(actions.newName ?? "") == nil)
                    .buttonStyle(CollieButtonStyle(.primary))
            }
        }
        .padding(24).frame(width: 420).background(Color.collieSurface)
    }
}
