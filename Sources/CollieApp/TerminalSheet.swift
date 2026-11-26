import AppKit
import SwiftUI
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

/// Creates (name, preset, command for custom, folder, Shepherd; remembers the last values) or edits a terminal.
struct TerminalSheet: View {
    enum Mode { case create(at: CGPoint?), edit(TerminalRecord) }
    let client: DaemonClient
    let canvas: CanvasState
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var presetRaw: String
    @State private var command: String
    @State private var cwd: String
    @State private var shepherd: Bool
    @State private var free = false   // never remembered: each free terminal is a fresh decision
    @State private var lotId: UUID?
    @State private var error: String?
    @State private var busy = false

    private static let trustedKey = "new.claudeFolders"   // folders where a claude terminal was already created

    init(client: DaemonClient, canvas: CanvasState, mode: Mode) {
        self.client = client; self.canvas = canvas; self.mode = mode
        let d = UserDefaults.standard
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _presetRaw = State(initialValue: d.string(forKey: "new.preset") ?? Preset.shell.rawValue)
            _command = State(initialValue: d.string(forKey: "new.command") ?? "")
            _cwd = State(initialValue: d.string(forKey: "new.cwd") ?? NSHomeDirectory())
            _shepherd = State(initialValue: d.bool(forKey: "new.shepherd"))
        case .edit(let t):
            _name = State(initialValue: t.name); _presetRaw = State(initialValue: t.preset.rawValue)
            _command = State(initialValue: t.command ?? ""); _cwd = State(initialValue: t.cwd); _shepherd = State(initialValue: t.isShepherd)
            _lotId = State(initialValue: client.lot(of: t.id)?.id)
        }
    }

    private var original: TerminalRecord? { if case .edit(let t) = mode { t } else { nil } }
    /// Edit: the terminal's own paddock (it cannot change folder); create: the paddock being shown.
    private var paddock: Paddock? {
        client.paddocks.first { $0.id == (original.map(\.paddockId) ?? client.currentPaddock) }
    }
    private var preset: Preset { Preset(rawValue: presetRaw) ?? .shell }
    private var chosenLot: Lot? { client.lots.first { $0.id == lotId } }
    private var newClaudeFolder: Bool {
        original == nil && preset == .claude
            && !(UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? []).contains(paddock?.path ?? cwd)
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !(paddock?.path ?? cwd).isEmpty
            && (preset != .custom || !command.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    private var changes: (newName: String?, shepherd: Bool?, preset: Preset?, command: String?, cwd: String?)? {
        original.map { editArgs(original: $0, name: name, shepherd: shepherd, preset: preset, command: command, cwd: paddock == nil ? cwd : $0.cwd) }
    }
    /// Launch settings changed under a running process: they apply only after a restart.
    private var needsRestart: Bool {
        guard let o = original, let c = changes, client.badges[o.id] != .stopped else { return false }
        return c.shepherd != nil || c.preset != nil || c.command != nil || c.cwd != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? tr("Novo terminal", "New terminal") : tr("Editar terminal", "Edit terminal")).font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
            VStack(alignment: .leading, spacing: 8) {
                label(tr("Agente", "Agent"))
                // one card per preset: a new one (e.g. Cursor) shows up here unchanged
                HStack(spacing: 8) {
                    ForEach(Preset.allCases, id: \.rawValue) { p in
                        ChoiceCard(p.cardTitle, subtitle: p.cardCommand, selected: preset == p, action: { presetRaw = p.rawValue }) { EmptyView() }
                    }
                }
            }
            if preset == .custom { field(tr("Comando", "Command")) { TextField(tr("Comando", "Command"), text: $command).collieField(mono: true) } }
            HStack(alignment: .top, spacing: 14) {
                field(tr("Nome", "Name")) { TextField(tr("Nome", "Name"), text: $name).collieField() }
                field(tr("Cercado", "Paddock")) {
                    Text(paddock?.name ?? tr("Pasto", "Pasture")).font(.collieUI(14)).foregroundStyle(Color.collieTextSecondary).frame(height: 36)
                }
            }
            field(tr("Lote", "Lot")) {
                Picker(tr("Lote", "Lot"), selection: $lotId) {
                    ForEach(LotChoice.all(client.lots)) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 260, alignment: .leading)
            }
            if paddock == nil {
                field(tr("Pasta", "Folder")) {
                    HStack(spacing: 6) {
                        TextField(tr("Pasta", "Folder"), text: $cwd).collieField(mono: true)
                        Button(tr("Escolher", "Choose"), action: pick).buttonStyle(CollieButtonStyle(.secondary))
                    }
                }
            }
            Toggle(isOn: $shepherd) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Pastor", "Shepherd")).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                    Text(tr("Pode chamar agentes, abrir painéis e criar cercados. Só alcança quem estiver ligado a ele por guia.", "Can summon agents, open panels and create paddocks. It only reaches whoever is connected to it by a leash."))
                        .font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.collieSidebar))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.collieBorder, lineWidth: 1))
            if original == nil {
                Toggle(isOn: $free) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Terminal livre (sem sandbox)", "Free terminal (no sandbox)")).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                        Text(tr("Vê e altera tudo o que você pode; nenhuma guia chega a ele. Só para o seu próprio trabalho.", "Sees and changes everything you can; no leash reaches it. Only for your own work."))
                            .font(.collieUI(13)).foregroundStyle(free ? Color.collieDanger : Color.collieTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.collieSidebar))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(free ? Color.collieDanger : Color.collieBorder, lineWidth: 1))
            }
            if paddock == nil, let w = Self.homeWarning(cwd: cwd, free: original == nil ? free : original?.sandbox == .free) {
                Text(w).font(.collieUI(12)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true)
            }
            if needsRestart {
                Text(tr("Pastor, preset, comando e pasta valem depois de reiniciar", "Shepherd, preset, command and folder take effect after a restart")).font(.collieUI(12)).foregroundStyle(Color.collieAttention)
            }
            if newClaudeFolder {
                Text(tr("O Claude Code pode pedir para confiar nesta pasta — o nó vai indicar 'precisa de atenção'.", "Claude Code may ask to trust this folder — the node will show 'needs attention'."))
                    .font(.collieUI(12)).foregroundStyle(Color.collieMuted)
            }
            if original != nil, [.claude, .codex, .cursor].contains(preset) {
                Text(tr("A sessão do agente será reiniciada ao reiniciar", "The agent session will restart on restart")).font(.collieUI(12)).foregroundStyle(Color.collieMuted)
            }
            if let error { Text(error).foregroundStyle(Color.collieDanger).font(.collieUI(12)) }
            HStack(spacing: 10) {
                Spacer()
                Button(tr("Cancelar", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary))
                if original == nil {
                    Button(tr("Criar terminal", "Create terminal"), action: create).keyboardShortcut(.defaultAction).disabled(!valid || busy)
                        .buttonStyle(CollieButtonStyle(.primary))
                } else {
                    Button(tr("Salvar e reiniciar", "Save and restart")) { save(restart: true) }.disabled(!valid || busy).buttonStyle(CollieButtonStyle(.secondary))
                    Button(tr("Salvar", "Save")) { save(restart: false) }.keyboardShortcut(.defaultAction).disabled(!valid || busy)
                        .buttonStyle(CollieButtonStyle(.primary))
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 26).padding(.vertical, 24).frame(width: 560)
        .background(Color.collieSurface)
    }

    /// R32: a sandboxed terminal at `~` has the whole home as its project (rc files and agent config stay closed).
    static func homeWarning(cwd: String, free: Bool) -> String? {
        guard !free, URL(fileURLWithPath: cwd).standardizedFileURL.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path else { return nil }
        return tr("O projeto será toda a sua pasta pessoal: o agente poderá ler e alterar tudo nela (menos segredos, rc do shell e configuração global dos agentes). Prefira a pasta do projeto.", "The project will be your whole home folder: the agent will be able to read and change everything in it (except secrets, shell rc and the agents' global config). Prefer the project folder.")
    }

    private func label(_ text: String) -> some View { Text(text).font(.collieUI(13, .medium)).foregroundStyle(Color.collieText) }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) { label(title); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: cwd)
        if p.runModal() == .OK, let u = p.url { cwd = u.path }
    }

    private func create() {
        busy = true; error = nil
        let n = name.trimmingCharacters(in: .whitespaces), c = command.trimmingCharacters(in: .whitespaces)
        let paddock = paddock, dir = paddock?.path ?? cwd
        Task {
            do {
                let id = try await client.spawn(name: n, preset: preset, command: preset == .custom ? c : nil, cwd: dir,
                                           shepherd: shepherd, paddock: paddock?.name, sandbox: free ? .free : .sandboxed)
                if let l = chosenLot { try await client.setLot(n, l.name) }   // grouping only, never a leash
                if case .create(let at?) = mode {
                    canvas.setFrame(CGRect(origin: at, size: CanvasState.defaultTerminalSize), for: id)
                }
                let d = UserDefaults.standard
                d.set(presetRaw, forKey: "new.preset"); d.set(command, forKey: "new.command")
                d.set(cwd, forKey: "new.cwd"); d.set(shepherd, forKey: "new.shepherd")
                if preset == .claude {
                    d.set(Array(Set((d.stringArray(forKey: Self.trustedKey) ?? []) + [dir])), forKey: Self.trustedKey)
                }
                dismiss()
            } catch { self.error = "\(error)"; busy = false }
        }
    }

    private func save(restart: Bool) {
        guard let o = original, let c = changes else { return }
        busy = true; error = nil
        Task {
            do {
                try await client.update(o.name, newName: c.newName, shepherd: c.shepherd, preset: c.preset,
                                        command: c.command, cwd: c.cwd, restart: restart)
                if client.lot(of: o.id)?.id != lotId { try await client.setLot(c.newName ?? o.name, chosenLot?.name) }
                dismiss()
            } catch { self.error = "\(error)"; busy = false }
        }
    }
}

/// The agent cards' copy: name (Space Grotesk) and command (DM Mono). A preset not listed shows its raw value.
extension Preset {
    var cardTitle: String { [.shell: "Shell", .claude: "Claude", .codex: "Codex", .cursor: "Cursor", .custom: tr("Próprio", "Custom")][self] ?? rawValue.capitalized }
    var cardCommand: String { [.shell: "zsh", .cursor: "cursor-agent", .custom: tr("comando", "command")][self] ?? rawValue }
}
