import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

extension PaddockStatus {
    /// Working and review share `secondary`: the symbol shape (and the label) tells them apart.
    var color: Color { switch self { case .working, .review: .collieSecondary; case .blocked: .collieAttention; case .done: .collieAccent; case .idle: .collieMuted } }
    /// A distinct shape per status, so a chip never shows state by color alone.
    var symbol: String { switch self { case .working: "circle.fill"; case .review: "circle"; case .blocked: "exclamationmark.circle.fill"; case .done: "checkmark.circle.fill"; case .idle: "pause.circle" } }
    var label: String { switch self { case .working: tr("Trabalhando", "Working"); case .blocked: tr("Bloqueado", "Blocked"); case .review: tr("Em revisão", "In review"); case .done: tr("Concluído", "Done"); case .idle: tr("Ocioso", "Idle") } }
    static let menuOrder: [PaddockStatus] = [.working, .blocked, .review, .idle, .done]
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
    var label: String { switch self { case .merge: "Merge"; case .squash: "Squash"; case .rebase: "Rebase"; case .pr: tr("Abrir PR", "Open PR") } }
}

/// The "Novo cercado" sheet: a name and a folder; a git folder offers isolating the paddock in a worktree (on by default)
/// and creating it cercado fábrica (A3, off by default; never off a non-git folder).
struct NewPaddockForm: Equatable {
    var name = ""
    var folder: String? { didSet { isGit = folder.map { Self.isGit($0) } ?? false; if !isGit { factory = false } } }
    var isolate = true
    var factory = false { didSet { if !isGit { factory = false } } }
    private(set) var isGit = false
    init(folder: String? = nil) { self.folder = folder; isGit = folder.map { Self.isGit($0) } ?? false }
    var slug: String? { PaddockName.slug(name) }
    var canCreate: Bool { slug != nil && folder != nil }
    var worktree: Bool { isGit && isolate }
    /// `path` or an ancestor below `home` holds a `.git` (as the daemon's ProjectRoot: a dotfiles repo at home doesn't count).
    static func isGit(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let ceiling = URL(fileURLWithPath: home).resolvingSymlinksInPath().pathComponents
        var u = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while !ceiling.starts(with: u.pathComponents) {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return true }
            u = u.deletingLastPathComponent()
        }
        return false
    }
}

/// The paddock actions (select, create, status, land, delete), shared by the chips, the sidebar, the header menu and
/// the command palette. Daemon calls are async; land can take minutes, so land/delete are disabled while any call
/// runs (`busy`) and the UI never waits on them. The prompt, alert and dialogs are attached once by `paddockDialogs`.
@MainActor @Observable final class PaddockActions {
    static let currentKey = "paddock.current", repoKey = "paddock.repo"
    let client: DaemonClient
    private(set) var running = 0   // daemon calls in flight
    var busy: Bool { running > 0 }
    var newForm: NewPaddockForm?   // non-nil: the "Novo cercado" sheet is open
    var message: String?   // alert text (errors, land conflicts, results)
    var confirmDelete = false
    var forceDelete = false
    var deleting: Paddock?   // the dialog's paddock
    var choosingStatus: Paddock?   // the palette's status dialog
    var choosingLand: Paddock?     // the palette's land dialog

    /// A3: per paddock, the daemon's refusal of the last Fábrica switch, word for word (shown under the switch, never an alert).
    var factoryRefusal: [UUID: String] = [:]
    /// A3: per factory paddock, the doctor's layers, one line each (or why there is none).
    var factoryNote: [UUID: [String]] = [:]
    /// The daemon side of the switch (`paddock factory <name> on|off`); tests swap it.
    var factoryCall: @MainActor (String, Bool) async throws -> Void

    init(client: DaemonClient) {
        self.client = client
        factoryCall = { [client] name, on in try await client.setPaddockFactory(name, on) }
    }

    /// A3: the Fábrica switch (sidebar ⋯ › Fábrica…, and ⌘K). The new state reaches the UI through the
    /// paddock event, as any other paddock change.
    @discardableResult
    func setFactory(_ f: Paddock, _ on: Bool) -> Task<Void, Never> {
        factoryRefusal[f.id] = nil
        return run { [self] in try await factoryCall(f.name, on) } onError: { [self] m in
            message = nil   // shown under the switch instead
            factoryRefusal[f.id] = m
        }
    }

    /// A3: the doctor's note of a factory paddock. The daemon reads the project through a terminal of the paddock; with
    /// none open, the note says so (no engine change for a terminal-less doctor).
    func loadFactoryNote(_ f: Paddock) async {
        guard let t = client.terminals.first(where: { $0.paddockId == f.id }) else {
            factoryNote[f.id] = [tr("Abra um terminal no cercado para ver a nota do doctor.", "Open a terminal in the paddock to see the doctor note.")]
            return
        }
        do { factoryNote[f.id] = Self.noteLines(try await client.factoryDoctor(terminal: t.name)) }
        catch let e as ProtocolError { factoryNote[f.id] = [e.message] }
        catch { factoryNote[f.id] = ["\(error)"] }
    }

    /// One line per layer: "static 2/3 OK".
    static func noteLines(_ r: FactoryDoctor.Report) -> [String] {
        r.layers.map { "\($0.layer.rawValue) \($0.score)/3 \($0.rating.rawValue)" }
    }

    func select(_ id: UUID?) {
        client.currentPaddock = id
        UserDefaults.standard.set(id?.uuidString ?? "", forKey: Self.currentKey)
    }

    func newPaddock() { newForm = NewPaddockForm(folder: UserDefaults.standard.string(forKey: Self.repoKey)) }

    func setStatus(_ f: Paddock, _ s: PaddockStatus) { run { [client] in try await client.setPaddockStatus(f.name, s) } }

    func askDelete(_ f: Paddock) { deleting = f; forceDelete = false; confirmDelete = true }

    /// ⌘K: the paddock menu's actions for `f` (Land / Excluir only while nothing runs, as in the menu; no Land for a folder).
    func commands(for f: Paddock) -> [PaletteCommand] {
        [PaletteCommand(id: "paddock.status", title: tr("Status do cercado \(f.name)…", "Paddock status \(f.name)…"), run: { self.choosingStatus = f })]
            + (busy || f.isFolder ? [] : [PaletteCommand(id: "paddock.land", title: "Land \(f.name)…", run: { self.choosingLand = f })])
            + (busy ? [] : [PaletteCommand(id: "paddock.delete", title: tr("Excluir cercado \(f.name)…", "Delete paddock \(f.name)…"), run: { self.askDelete(f) })])
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = tr("Pasta do cercado", "Paddock folder")
        if let last = newForm?.folder { p.directoryURL = URL(fileURLWithPath: last) }
        guard p.runModal() == .OK, let dir = p.url?.path else { return }
        newForm?.folder = dir
    }

    func create() {
        guard let form = newForm, form.canCreate, let name = form.slug, let folder = form.folder else { return }
        UserDefaults.standard.set(folder, forKey: Self.repoKey)
        newForm = nil
        run { [self] in
            try await client.createPaddock(name: name, folder: folder, worktree: form.worktree, factory: form.factory)
            if let f = client.paddocks.first(where: { $0.name == name }) { select(f.id) }
        }
    }

    func land(_ f: Paddock, _ mode: LandMode) {
        run { [self] in
            let r = try await client.land(f.name, mode: mode)
            if let pr = r.prURL { message = tr("PR aberto: \(pr)", "PR opened: \(pr)") }
            else if let c = r.commit { message = tr("Cercado integrado (\(String(c.prefix(8))))." , "Paddock landed (\(String(c.prefix(8)))).") }
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

    /// Runs a daemon call off the click; failures (land conflicts included) go to the alert. The task is returned so a
    /// caller (a test) can await its end.
    @discardableResult
    func run(_ op: @escaping @MainActor () async throws -> Void, onError: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never> {
        running += 1
        return Task {
            defer { running -= 1 }
            do { try await op() }
            catch let e as ProtocolError { message = e.message; onError?(e.message) }
            catch { message = "\(error)" }
        }
    }
}

/// A3: the Fábrica switch's state, out of SwiftUI. `label` is the action a click takes (also the paddock menu's item);
/// disabled while a daemon call runs; `refusal` is the daemon's text whole; `note` only while on.
struct FactorySwitch: Equatable {
    var isOn: Bool, label: String, enabled: Bool, refusal: String?, note: [String]

    static func make(_ p: Paddock, busy: Bool, refusal: String?, note: [String]?) -> FactorySwitch {
        FactorySwitch(isOn: p.factory, label: label(p), enabled: !busy, refusal: refusal, note: p.factory ? note ?? [] : [])
    }
    static func label(_ p: Paddock) -> String { p.factory ? tr("Desligar fábrica", "Turn factory off") : tr("Ligar fábrica", "Turn factory on") }
    /// The rail's badge and its accessibility text; nil for a plain paddock.
    static func badge(_ p: Paddock) -> String? { p.factory ? tr("cercado fábrica", "factory paddock") : nil }
}

/// A paddock's menu items (Status, Land, Excluir…), for a `Menu` or a `contextMenu`. The Fábrica switch is the
/// sidebar ⋯ menu's "Fábrica…" (with what it does).
struct PaddockMenu: View {
    let paddock: Paddock
    let actions: PaddockActions

    var body: some View {
        Menu("Status") {
            ForEach(PaddockStatus.menuOrder, id: \.self) { s in
                Button(s.label) { actions.setStatus(paddock, s) }
            }
        }
        if !paddock.isFolder {   // a folder paddock has no branch to land
            Menu("Land") {
                ForEach(LandMode.menuOrder, id: \.self) { m in Button(m.label) { actions.land(paddock, m) } }
            }.disabled(actions.busy)
        }
        Divider()
        Button(tr("Excluir…", "Delete…")) { actions.askDelete(paddock) }.disabled(actions.busy)
    }
}

struct NewPaddockButton: View {
    let actions: PaddockActions
    var body: some View { Button(tr("Novo cercado…", "New paddock…")) { actions.newPaddock() } }
}

extension View {
    /// The "Novo cercado" prompt, the result/error alert and the delete confirmation, attached once per window.
    func paddockDialogs(_ a: PaddockActions) -> some View { modifier(PaddockDialogs(actions: a)) }
}

private struct PaddockDialogs: ViewModifier {
    @Bindable var actions: PaddockActions

    func body(content: Content) -> some View {
        let name = actions.deleting?.name ?? "", folder = actions.deleting?.isFolder == true
        content
            .sheet(isPresented: Binding(get: { actions.newForm != nil }, set: { if !$0 { actions.newForm = nil } })) { newSheet }
            .alert(tr("Cercado", "Paddock"), isPresented: Binding(get: { actions.message != nil }, set: { if !$0 { actions.message = nil } })) {
                Button("OK") {}
            } message: { Text(actions.message ?? "") }
            .confirmationDialog(actions.forceDelete ? tr("Forçar a exclusão de \(name)?", "Force-delete \(name)?") : tr("Excluir o cercado \(name)?", "Delete paddock \(name)?"),
                                isPresented: $actions.confirmDelete) {
                Button(actions.forceDelete ? tr("Forçar exclusão", "Force delete") : tr("Excluir", "Delete"), role: .destructive) { actions.delete(force: actions.forceDelete) }
            } message: {
                Text(folder ? tr("Remove só o cercado do Collie: a pasta e os arquivos dela ficam intactos.", "Removes only the paddock from Collie: the folder and its files stay intact.")
                     : actions.forceDelete ? tr("Alterações não commitadas ou não integradas serão perdidas.", "Uncommitted or unmerged changes will be lost.") : tr("Remove o worktree e o branch.", "Removes the worktree and the branch."))
            }
            .confirmationDialog(tr("Status do cercado \(actions.choosingStatus?.name ?? "")", "Paddock status \(actions.choosingStatus?.name ?? "")"), isPresented: shown(\.choosingStatus),
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
        let form = actions.newForm ?? NewPaddockForm()
        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("Novo cercado", "New paddock")).font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
            TextField(tr("Nome do cercado", "Paddock name"), text: Binding(get: { actions.newForm?.name ?? "" }, set: { actions.newForm?.name = $0 }))
                .collieField(mono: true)
            if !form.name.isEmpty {
                Text(form.slug.map { $0 == form.name ? tr("Nome: \($0)", "Name: \($0)") : tr("Será criado como: \($0)", "Will be created as: \($0)") } ?? tr("Use letras ou números", "Use letters or numbers"))
                    .font(.collieMono(12)).foregroundStyle(form.slug == nil ? Color.collieDanger : Color.collieMuted)
            }
            HStack(spacing: 8) {
                Text(tr("Pasta: \(form.folder ?? "nenhuma")", "Folder: \(form.folder ?? "none")"))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button(tr("Escolher pasta…", "Choose folder…")) { actions.chooseFolder() }.buttonStyle(CollieButtonStyle(.secondary))
            }
            if form.folder != nil {
                Toggle(tr("Isolar numa branch (worktree)", "Isolate on a branch (worktree)"), isOn: Binding(get: { form.worktree }, set: { actions.newForm?.isolate = $0 }))
                    .disabled(!form.isGit)
                Toggle(tr("Cercado fábrica", "Factory paddock"), isOn: Binding(get: { form.factory }, set: { actions.newForm?.factory = $0 }))
                    .disabled(!form.isGit)
                if !form.isGit {
                    Text(tr("A pasta não é um repositório git: o cercado trabalha nela direto.", "The folder isn't a git repository: the paddock works in it directly."))
                        .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button(tr("Cancelar", "Cancel")) { actions.newForm = nil }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary))
                Button(tr("Criar", "Create")) { actions.create() }.keyboardShortcut(.defaultAction)
                    .disabled(!form.canCreate)
                    .buttonStyle(CollieButtonStyle(.primary))
            }
        }
        .padding(24).frame(width: 420).background(Color.collieSurface)
    }
}
