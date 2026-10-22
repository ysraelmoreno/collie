import SwiftUI
import OrqCanvas
import OrqClient
import OrqCore
import OrqPlugins
import OrqProtocol
import OrqTheme

/// Plug-in, name, placement, initial URL (browser) and storage scope (default: isolated), the device (device plug-in),
/// or the design file (design plug-in: `design.files`, or a new one through `design.new`).
/// Remembers nothing: a panel is a deliberate act.
struct OpenPanelSheet: View {
    let client: DaemonClient
    let canvas: CanvasState
    /// Canvas point of a right-click: the panel opens there, on the canvas.
    var at: CGPoint?
    @Environment(\.dismiss) private var dismiss
    @State private var plugin = PluginRegistry.all.first?.id ?? ""
    @State private var name = ""
    @State private var placement = PluginRegistry.all.first?.defaultPlacement ?? .canvas
    @State private var url = ""
    @State private var storage = StorageScope.isolated
    @State private var error: String?
    @State private var busy = false
    @State private var devices: [(serial: String, label: String, off: Bool, platform: String)] = []
    @State private var serial = ""
    @State private var files: [String] = []
    @State private var file = ""
    @State private var newFile = ""

    private var spec: PluginSpec? { PluginRegistry.spec(plugin) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Abrir painel").font(.orqUI(20, .semibold)).foregroundStyle(Color.orqText)
            Picker("Plug-in", selection: $plugin) {
                ForEach(PluginRegistry.all, id: \.id) { Text($0.title).tag($0.id) }
            }
            .onChange(of: plugin) { _, _ in if let s = spec { placement = s.defaultPlacement } }
            TextField("Nome (opcional)", text: $name).orqField()
            if at == nil {
            Picker("Posição", selection: $placement) {
                ForEach(PanelMenu.order.filter { spec?.placements.contains($0) ?? false }, id: \.self) {
                    Text(PanelMenu.labels[$0] ?? $0.rawValue).tag($0)
                }
            }
            }
            if plugin == "device" {
                HStack {
                    Picker("Aparelho", selection: $serial) {
                        if devices.isEmpty { Text("Nenhum aparelho conectado").tag("") }
                        ForEach(devices, id: \.serial) { Text($0.label).tag($0.serial) }
                    }
                    Button("Atualizar") { Task { await loadDevices() } }
                }
                if let d = devices.first(where: { $0.serial == serial }), d.off {
                    Text(d.platform == "android" ? "Abrir vai ligar o emulador (pode levar até 3 min)." : "Abrir vai ligar o simulador (pode levar até 2 min).").foregroundStyle(Color.orqMuted).font(.orqUI(12))
                }
            } else if plugin == "design" {
                Picker("Arquivo", selection: $file) {
                    if files.isEmpty { Text("Nenhum arquivo").tag("") }
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField("Novo arquivo…", text: $newFile).orqField()
                    Button("Criar", action: createFile).disabled(busy || newFile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                if plugin == "browser" { TextField("URL inicial", text: $url).orqField(mono: true) }
                Picker("Armazenamento", selection: $storage) {
                    Text("Isolado").tag(StorageScope.isolated)
                    Text("Workspace").tag(StorageScope.workspace)
                    Text("Global").tag(StorageScope.global)
                }
            }
            if let error { Text(error).foregroundStyle(Color.orqDanger).font(.orqUI(12)) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Abrir", action: open).keyboardShortcut(.defaultAction).buttonStyle(OrqButtonStyle(.primary))
                    .disabled(spec == nil || busy || (plugin == "device" && serial.isEmpty) || (plugin == "design" && file.isEmpty))
            }
        }
        .buttonStyle(OrqButtonStyle(.secondary))
        .padding(24).frame(width: 440).background(Color.orqSurface)
        .task(id: plugin) {
            if plugin == "device" { await loadDevices() }
            if plugin == "design" { await loadFiles() }
        }
    }

    /// `device.list`: Android devices adb can talk to (`state == device`: not offline/unauthorized) and iOS Simulators
    /// booted or shut down (opening a shut-down one boots it).
    private func loadDevices() async {
        do {
            guard case .array(let a) = try await client.adminCall("device.list", [:]) else { return }
            devices = a.compactMap { v in
                guard case .object(let o) = v, case .string(let s)? = o["serial"], case .string(let state)? = o["state"] else { return nil }
                if o["platform"] == .string("ios") {
                    guard state == "booted" || state == "shutdown", case .string(let m)? = o["model"] else { return nil }
                    let runtime: String = if case .string(let r)? = o["product"] { " — \(r)" } else { "" }
                    return (s, m + runtime + (state == "shutdown" ? " (desligado)" : ""), state == "shutdown", "ios")
                }
                if state == "off", case .string(let m)? = o["model"] { return (s, "\(m) (desligado)", true, "android") }
                guard state == "device" else { return nil }
                if case .string(let m)? = o["model"] { return (s, "\(m.replacingOccurrences(of: "_", with: " ")) (\(s))", false, "android") }
                return (s, s, false, "android")
            }
            devices = devices.filter { !($0.off && $0.platform == "android") } + devices.filter { $0.off && $0.platform == "android" }   // off emulators after the live ones
            for i in devices.indices where devices.filter({ $0.label == devices[i].label }).count > 1 {
                devices[i].label += " [\(devices[i].serial.prefix(8))]"   // two identical labels: tell them apart
            }
            if !devices.contains(where: { $0.serial == serial }) { serial = devices.first?.serial ?? "" }
            error = nil
        } catch { self.error = error.message }
    }

    /// `design.files`: the design files on the local engine (the first call can take a moment: it starts the engine).
    private func loadFiles() async {
        do {
            guard case .array(let a) = try await client.adminCall("design.files", [:]) else { return }
            files = a.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { n } else { nil } }
            if !files.contains(file) { file = files.first ?? "" }
            error = nil
        } catch { self.error = error.message }
    }

    private func createFile() {
        busy = true; error = nil
        let n = newFile.trimmingCharacters(in: .whitespaces)
        Task {
            do throws(ProtocolError) {
                if case .object(let o) = try await client.adminCall("design.new", ["name": .string(n)]), case .string(let made)? = o["name"] {
                    await loadFiles(); file = made; newFile = ""
                }
            } catch { self.error = error.message }
            busy = false
        }
    }

    private func open() {
        if plugin == "work", let p = WorkPanel.existing(in: client.panels) {   // one per workspace: focus it
            NotificationCenter.default.post(name: .orqFocusPanel, object: p.id); dismiss(); return
        }
        busy = true; error = nil
        let n = name.trimmingCharacters(in: .whitespaces), u = url.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                // a right-click on the canvas opens there, unless the plug-in only docks (Trabalho, Memória…): its default dock
                let onCanvas = at != nil && spec?.placements.contains(.canvas) == true
                let p = onCanvas ? .canvas : at == nil ? placement : (spec?.defaultPlacement ?? placement)
                let id = try await client.openPanel(plugin: plugin, name: n, placement: p, url: plugin == "browser" ? u : nil,
                                                    storage: storage, serial: plugin == "device" ? serial : nil,
                                                    file: plugin == "design" ? file : nil)
                if onCanvas, let at { canvas.setFrame(CGRect(origin: at, size: plugin == "device" ? CGSize(width: 360, height: 720) : plugin == "design" ? CGSize(width: 1100, height: 720) : CanvasState.defaultTerminalSize), for: id) }
                dismiss()
            } catch { self.error = "\(error)"; busy = false }
        }
    }
}
