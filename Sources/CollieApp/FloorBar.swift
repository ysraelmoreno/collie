import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

extension FloorStatus {
    /// Working and review share `secondary`: the symbol shape (and the label) tells them apart.
    var color: Color { switch self { case .working, .review: .collieSecondary; case .blocked: .collieAttention; case .done: .collieAccent } }
    /// A distinct shape per status, so a chip never shows state by color alone.
    var symbol: String { switch self { case .working: "circle.fill"; case .review: "circle"; case .blocked: "exclamationmark.circle.fill"; case .done: "checkmark.circle.fill" } }
    var label: String { switch self { case .working: "Trabalhando"; case .blocked: "Bloqueado"; case .review: "Em revisão"; case .done: "Concluído" } }
    static let menuOrder: [FloorStatus] = [.working, .blocked, .review, .done]
}

/// The floor status mark: shape plus color (decorative; the label carries it for VoiceOver).
struct FloorStatusDot: View {
    let status: FloorStatus?
    var body: some View {
        Image(systemName: status?.symbol ?? "circle.fill").font(.system(size: 8, weight: .bold))
            .foregroundStyle(status?.color ?? Color.collieMuted).accessibilityHidden(true)
    }
}

extension LandMode {
    static let menuOrder: [LandMode] = [.merge, .squash, .rebase, .pr]
    var label: String { switch self { case .merge: "Merge"; case .squash: "Squash"; case .rebase: "Rebase"; case .pr: "Abrir PR" } }
}

/// The floor actions (select, create, status, land, delete), shared by the chips, the sidebar, the header menu and
/// the command palette. Daemon calls are async; land can take minutes, so land/delete are disabled while any call
/// runs (`busy`) and the UI never waits on them. The prompt, alert and dialogs are attached once by `floorDialogs`.
@MainActor @Observable final class FloorActions {
    static let currentKey = "floor.current", repoKey = "floor.repo"
    let client: DaemonClient
    private(set) var running = 0   // daemon calls in flight
    var busy: Bool { running > 0 }
    var newName: String?   // non-nil: the "Novo andar" prompt is open
    var message: String?   // alert text (errors, land conflicts, results)
    var confirmDelete = false
    var forceDelete = false
    var deleting: Floor?   // the dialog's floor
    var choosingStatus: Floor?   // the palette's status dialog
    var choosingLand: Floor?     // the palette's land dialog

    init(client: DaemonClient) { self.client = client }

    func select(_ id: UUID?) {
        client.currentFloor = id
        UserDefaults.standard.set(id?.uuidString ?? "", forKey: Self.currentKey)
    }

    func newFloor() { newName = "" }

    func setStatus(_ f: Floor, _ s: FloorStatus) { run { [client] in try await client.setFloorStatus(f.name, s) } }

    func askDelete(_ f: Floor) { deleting = f; forceDelete = false; confirmDelete = true }

    /// ⌘K: the floor menu's actions for `f` (Land / Excluir only while nothing runs, as in the menu).
    func commands(for f: Floor) -> [PaletteCommand] {
        [PaletteCommand(id: "floor.status", title: "Status do andar \(f.name)…", run: { self.choosingStatus = f })]
            + (busy ? [] : [PaletteCommand(id: "floor.land", title: "Land \(f.name)…", run: { self.choosingLand = f }),
                            PaletteCommand(id: "floor.delete", title: "Excluir andar \(f.name)…", run: { self.askDelete(f) })])
    }

    func create() {
        let name = (newName ?? "").trimmingCharacters(in: .whitespaces)
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = "Repositório git do andar"
        if let last = UserDefaults.standard.string(forKey: Self.repoKey) { p.directoryURL = URL(fileURLWithPath: last) }
        guard p.runModal() == .OK, let repo = p.url?.path else { return }
        UserDefaults.standard.set(repo, forKey: Self.repoKey)
        newName = nil
        run { [self] in
            try await client.createFloor(name: name, repo: repo)
            if let f = client.floors.first(where: { $0.name == name }) { select(f.id) }
        }
    }

    func land(_ f: Floor, _ mode: LandMode) {
        run { [self] in
            let r = try await client.land(f.name, mode: mode)
            if let pr = r.prURL { message = "PR aberto: \(pr)" }
            else if let c = r.commit { message = "Andar integrado (\(String(c.prefix(8))))." }
        }
    }

    func delete(force: Bool) {
        guard let f = deleting, client.floors.contains(where: { $0.id == f.id }) else { return }   // gone meanwhile
        run { [self] in
            try await client.deleteFloor(f.name, force: force)
            if client.currentFloor == f.id { select(nil) }
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

/// A floor's menu items (Status, Land, Excluir…), for a `Menu` or a `contextMenu`.
struct FloorMenu: View {
    let floor: Floor
    let actions: FloorActions

    var body: some View {
        Menu("Status") {
            ForEach(FloorStatus.menuOrder, id: \.self) { s in
                Button(s.label) { actions.setStatus(floor, s) }
            }
        }
        Menu("Land") {
            ForEach(LandMode.menuOrder, id: \.self) { m in Button(m.label) { actions.land(floor, m) } }
        }.disabled(actions.busy)
        Divider()
        Button("Excluir…") { actions.askDelete(floor) }.disabled(actions.busy)
    }
}

struct NewFloorButton: View {
    let actions: FloorActions
    var body: some View { Button("Novo andar…") { actions.newFloor() } }
}

extension View {
    /// The "Novo andar" prompt, the result/error alert and the delete confirmation, attached once per window.
    func floorDialogs(_ a: FloorActions) -> some View { modifier(FloorDialogs(actions: a)) }
}

private struct FloorDialogs: ViewModifier {
    @Bindable var actions: FloorActions

    func body(content: Content) -> some View {
        let name = actions.deleting?.name ?? ""
        content
            .sheet(isPresented: Binding(get: { actions.newName != nil }, set: { if !$0 { actions.newName = nil } })) { newSheet }
            .alert("Andar", isPresented: Binding(get: { actions.message != nil }, set: { if !$0 { actions.message = nil } })) {
                Button("OK") {}
            } message: { Text(actions.message ?? "") }
            .confirmationDialog(actions.forceDelete ? "Forçar a exclusão de \(name)?" : "Excluir o andar \(name)?",
                                isPresented: $actions.confirmDelete) {
                Button(actions.forceDelete ? "Forçar exclusão" : "Excluir", role: .destructive) { actions.delete(force: actions.forceDelete) }
            } message: {
                Text(actions.forceDelete ? "Alterações não commitadas ou não integradas serão perdidas." : "Remove o worktree e o branch.")
            }
            .confirmationDialog("Status do andar \(actions.choosingStatus?.name ?? "")", isPresented: shown(\.choosingStatus),
                                presenting: actions.choosingStatus) { f in
                ForEach(FloorStatus.menuOrder, id: \.self) { s in Button(s.label) { actions.setStatus(f, s) } }
            }
            .confirmationDialog("Land \(actions.choosingLand?.name ?? "")", isPresented: shown(\.choosingLand),
                                presenting: actions.choosingLand) { f in
                ForEach(LandMode.menuOrder, id: \.self) { m in Button(m.label) { actions.land(f, m) }.disabled(actions.busy) }
            }
    }

    private func shown(_ k: ReferenceWritableKeyPath<FloorActions, Floor?>) -> Binding<Bool> {
        Binding(get: { actions[keyPath: k] != nil }, set: { if !$0 { actions[keyPath: k] = nil } })
    }

    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Novo andar").font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
            TextField("Nome (a-z, 0-9, -)", text: Binding(get: { actions.newName ?? "" }, set: { actions.newName = $0 }))
                .collieField(mono: true)
            Text("Repositório: \(UserDefaults.standard.string(forKey: FloorActions.repoKey) ?? "escolha ao criar")")
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { actions.newName = nil }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary))
                Button("Escolher repositório e criar…") { actions.create() }.keyboardShortcut(.defaultAction)
                    .disabled((actions.newName ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(CollieButtonStyle(.primary))
            }
        }
        .padding(24).frame(width: 420).background(Color.collieSurface)
    }
}
