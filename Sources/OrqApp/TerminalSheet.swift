import AppKit
import SwiftUI
import OrqCanvas
import OrqClient
import OrqCore
import OrqTheme

/// Creates (name, preset, command for custom, folder, Maestro; remembers the last values) or edits a terminal.
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
    @State private var maestro: Bool
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
            _maestro = State(initialValue: d.bool(forKey: "new.maestro"))
        case .edit(let t):
            _name = State(initialValue: t.name); _presetRaw = State(initialValue: t.preset.rawValue)
            _command = State(initialValue: t.command ?? ""); _cwd = State(initialValue: t.cwd); _maestro = State(initialValue: t.isMaestro)
        }
    }

    private var original: TerminalRecord? { if case .edit(let t) = mode { t } else { nil } }
    /// Edit: the terminal's own floor (it cannot change folder); create: the floor being shown.
    private var floor: Floor? {
        client.floors.first { $0.id == (original.map(\.floorId) ?? client.currentFloor) }
    }
    private var preset: Preset { Preset(rawValue: presetRaw) ?? .shell }
    private var newClaudeFolder: Bool {
        original == nil && preset == .claude
            && !(UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? []).contains(floor?.path ?? cwd)
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !(floor?.path ?? cwd).isEmpty
            && (preset != .custom || !command.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    private var changes: (newName: String?, maestro: Bool?, preset: Preset?, command: String?, cwd: String?)? {
        original.map { editArgs(original: $0, name: name, maestro: maestro, preset: preset, command: command, cwd: floor == nil ? cwd : $0.cwd) }
    }
    /// Launch settings changed under a running process: they apply only after a restart.
    private var needsRestart: Bool {
        guard let o = original, let c = changes, client.badges[o.id] != .stopped else { return false }
        return c.maestro != nil || c.preset != nil || c.command != nil || c.cwd != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? "Novo terminal" : "Editar terminal").font(.orqUI(20, .semibold)).foregroundStyle(Color.orqText)
            VStack(alignment: .leading, spacing: 8) {
                label("Agente")
                // one card per preset: a new one (e.g. Cursor) shows up here unchanged
                HStack(spacing: 8) {
                    ForEach(Preset.allCases, id: \.rawValue) { p in
                        ChoiceCard(p.cardTitle, subtitle: p.cardCommand, selected: preset == p, action: { presetRaw = p.rawValue }) { EmptyView() }
                    }
                }
            }
            if preset == .custom { field("Comando") { TextField("Comando", text: $command).orqField(mono: true) } }
            HStack(alignment: .top, spacing: 14) {
                field("Nome") { TextField("Nome", text: $name).orqField() }
                field("Andar") {
                    Text(floor?.name ?? "Térreo").font(.orqUI(14)).foregroundStyle(Color.orqTextSecondary).frame(height: 36)
                }
            }
            if floor == nil {
                field("Pasta") {
                    HStack(spacing: 6) {
                        TextField("Pasta", text: $cwd).orqField(mono: true)
                        Button("Escolher", action: pick).buttonStyle(OrqButtonStyle(.secondary))
                    }
                }
            }
            Toggle(isOn: $maestro) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maestro").font(.orqUI(14, .semibold)).foregroundStyle(Color.orqText)
                    Text("Pode recrutar agentes, abrir painéis e criar andares. Só alcança quem estiver ligado a ele por corda.")
                        .font(.orqUI(13)).foregroundStyle(Color.orqTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orqSidebar))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orqBorder, lineWidth: 1))
            if needsRestart {
                Text("Maestro, preset, comando e pasta valem depois de reiniciar").font(.orqUI(12)).foregroundStyle(Color.orqAttention)
            }
            if newClaudeFolder {
                Text("O Claude Code pode pedir para confiar nesta pasta — o nó vai indicar 'precisa de atenção'.")
                    .font(.orqUI(12)).foregroundStyle(Color.orqMuted)
            }
            if original != nil, preset == .claude || preset == .codex {
                Text("A sessão do agente será reiniciada ao reiniciar").font(.orqUI(12)).foregroundStyle(Color.orqMuted)
            }
            if let error { Text(error).foregroundStyle(Color.orqDanger).font(.orqUI(12)) }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(OrqButtonStyle(.secondary))
                if original == nil {
                    Button("Criar terminal", action: create).keyboardShortcut(.defaultAction).disabled(!valid || busy)
                        .buttonStyle(OrqButtonStyle(.primary))
                } else {
                    Button("Salvar e reiniciar") { save(restart: true) }.disabled(!valid || busy).buttonStyle(OrqButtonStyle(.secondary))
                    Button("Salvar") { save(restart: false) }.keyboardShortcut(.defaultAction).disabled(!valid || busy)
                        .buttonStyle(OrqButtonStyle(.primary))
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 26).padding(.vertical, 24).frame(width: 560)
        .background(Color.orqSurface)
    }

    private func label(_ text: String) -> some View { Text(text).font(.orqUI(13, .medium)).foregroundStyle(Color.orqText) }

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
        let floor = floor, dir = floor?.path ?? cwd
        Task {
            do {
                let id = try await client.spawn(name: n, preset: preset, command: preset == .custom ? c : nil, cwd: dir,
                                           maestro: maestro, floor: floor?.name)
                if case .create(let at?) = mode {
                    canvas.setFrame(CGRect(origin: at, size: CanvasState.defaultTerminalSize), for: id)
                }
                let d = UserDefaults.standard
                d.set(presetRaw, forKey: "new.preset"); d.set(command, forKey: "new.command")
                d.set(cwd, forKey: "new.cwd"); d.set(maestro, forKey: "new.maestro")
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
                try await client.update(o.name, newName: c.newName, maestro: c.maestro, preset: c.preset,
                                        command: c.command, cwd: c.cwd, restart: restart)
                dismiss()
            } catch { self.error = "\(error)"; busy = false }
        }
    }
}

/// The agent cards' copy: name (Space Grotesk) and command (DM Mono). A preset not listed shows its raw value.
extension Preset {
    var cardTitle: String { [.shell: "Shell", .claude: "Claude", .codex: "Codex", .custom: "Próprio"][self] ?? rawValue.capitalized }
    var cardCommand: String { [.shell: "zsh", .custom: "comando"][self] ?? rawValue }
}
