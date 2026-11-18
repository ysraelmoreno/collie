import SwiftUI
import CollieTheme
import CollieClient
import CollieProtocol
import ColliePlugins

/// Preferências › Memória › "Curador da memória" (spec 2026-11-17 curator provider §6–7): `memory.curator`'s status read
/// into what the section shows. Pure: the view only draws it and sends what `choose` returns.
struct CuratorSettings: Equatable {
    struct Row: Equatable, Identifiable {
        var provider: String, installed: Bool, available: Bool, availability: String, consentNeeded: Bool, destination: String
        var id: String { provider }
        var name: String { provider.capitalized }
        /// Available now, or only a consent away (the sheet).
        var selectable: Bool { available || consentNeeded }
        var detail: String {
            let inst = installed ? "instalado" : "não instalado"
            if available { return "\(inst) · disponível · dados vão para \(CuratorSettings.to(destination))" }
            if consentNeeded {
                return "\(inst) · falta seu consentimento: "
                    + (availability.contains("cobrança por uso") ? "login com cobrança por uso" : "dados vão para \(CuratorSettings.to(destination))")
            }
            return "\(inst) · indisponível: \(availability)"
        }
    }

    var info: CuratorInfo
    var rows: [Row]
    /// From `test` (`models()`, no token spent); [] when not asked or free text.
    var models: [String]
    var testLine: String?

    /// An older daemon (no `provider`): nothing here works until it restarts.
    var restartNote: String? { info.provider == nil ? "reinicie o serviço para usar isto" : nil }
    var trustNote: String? {
        info.trust == "limited" ? "Confiança limitada: criar vira proposta; ativar, apagar ou reescrever vira pergunta." : nil
    }
    /// The model picker: Claude's list as is ("" would reach `--model`); another provider also offers its account default.
    var modelChoices: [String] { (info.provider ?? "claude") == "claude" ? models : [""] + models }

    static func from(reply: JSONValue) -> CuratorSettings? {
        guard case .object(let o) = reply, let data = try? JSONEncoder().encode(reply),
              let info = try? JSONDecoder().decode(CuratorInfo.self, from: data) else { return nil }
        let rows = (info.providers ?? []).map {
            Row(provider: $0.provider, installed: $0.installed, available: $0.available, availability: $0.availability,
                consentNeeded: $0.consentNeeded, destination: $0.destination)
        }
        var models: [String] = [], testLine: String?
        if case .object(let t)? = o["test"] {
            if case .array(let ms)? = t["models"] { models = ms.compactMap { if case .string(let s) = $0 { s } else { nil } } }
            if case .string(let a)? = t["availability"] {
                testLine = "Teste: \(a)" + (models.isEmpty ? "" : " · modelos: " + models.joined(separator: ", "))
            }
        }
        return CuratorSettings(info: info, rows: rows, models: models, testLine: testLine)
    }

    /// `memory.curator`'s args to choose `row`; nil while it needs a consent not yet accepted (open the sheet instead).
    static func choose(_ row: Row, accepted: Bool) -> [String: JSONValue]? {
        if row.consentNeeded { return accepted ? ["consent": .string(row.provider), "provider": .string(row.provider)] : nil }
        return ["provider": .string(row.provider)]
    }

    /// The consent sheet: where the data goes and that a per-use login bills each job.
    static func consentText(_ provider: String) -> String {
        switch provider {
        case "cursor":
            "O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia ao Cursor e aos fornecedores de modelo dele, sob o Privacy Mode e o plano da sua conta. Se o seu plano cobra por uso além do incluído, os jobs do curador contam. Nada é enviado por chave de API."
        case "claude":
            "O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia à Anthropic pelo login do claude deste Mac. Esse login não é a assinatura: ele cobra por uso (conta de API) ou não foi reconhecido, e os jobs do curador contam na cobrança, até o limite diário. Nada é enviado por chave de API do seu shell."
        default:
            "O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia a \(provider.capitalized). Se o login cobra por uso, os jobs do curador contam."
        }
    }

    /// `testCall`'s results: "Chamada de teste: ops ok · items junk · chunks ok".
    static func testCallLine(_ reply: JSONValue) -> String? {
        guard case .object(let o) = reply, case .array(let xs)? = o["testCall"] else { return nil }
        let parts = xs.compactMap { x -> String? in
            guard case .object(let e) = x, case .string(let f)? = e["format"], case .string(let r)? = e["result"] else { return nil }
            return "\(f) \(r)"
        }
        return "Chamada de teste: " + parts.joined(separator: " · ")
    }

    static func to(_ destination: String) -> String {
        switch destination { case "Anthropic": "a Anthropic"; case "Cursor": "o Cursor"; default: destination }
    }
}

/// The section's view: one row per provider (installed, available, why), the model, the daily cap, the tests. Reads once
/// when shown and connected (with `test`, which spends nothing), and again after each change.
struct CuratorPreferences: View {
    let client: DaemonClient
    @State private var s: CuratorSettings?
    @State private var pending: CuratorSettings.Row?
    @State private var confirmCall = false
    @State private var working = false
    @State private var cap = ""
    @State private var callLine: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Curador da memória").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            if let s, let note = s.restartNote { muted(note) } else if let s { settings(s) } else { muted(connected ? "…" : "—") }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task(id: connected) { await load() }
        .alert("Enviar dados ao curador?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { row in
            Button("Confirmar") { send(CuratorSettings.choose(row, accepted: true)) }
            Button("Cancelar", role: .cancel) {}
        } message: { row in Text(CuratorSettings.consentText(row.provider)) }
        .confirmationDialog("Fazer 3 chamadas de teste?", isPresented: $confirmCall) {
            Button("Testar (contam 3 no limite de hoje)") { testCall() }
        } message: { Text("Uma por formato de resposta, com dados sintéticos. Nada é gravado na memória.") }
    }

    @ViewBuilder
    private func settings(_ s: CuratorSettings) -> some View {
        ForEach(s.rows) { row in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { pick(row) } label: {
                    Label(row.name, systemImage: s.info.provider == row.provider ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain).disabled(!connected || working || !row.selectable)
                Text(row.detail).font(.collieMono(12))
                    .foregroundStyle(row.available ? Color.collieMuted : Color.collieAttention).fixedSize(horizontal: false, vertical: true)
                if row.consentNeeded, s.info.provider == row.provider {
                    Button("Confirmar…") { pending = row }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || working)
                }
            }
        }
        if !s.info.available, let why = s.info.reason { muted("curador indisponível: \(why)") }
        if !s.modelChoices.isEmpty {
            Picker("Modelo", selection: Binding(get: { s.info.model ?? "" }, set: { send(["model": .string($0), "provider": .string(s.info.provider ?? "claude")]) })) {
                ForEach(s.modelChoices, id: \.self) { Text($0.isEmpty ? "padrão da conta" : $0).tag($0) }
            }
            .frame(maxWidth: 280).disabled(!connected || working)
        }
        HStack {
            Text("Limite").font(.collieUI(13))
            TextField("40", text: $cap).frame(width: 56).onSubmit { if let n = Int(cap) { send(["cap": .number(Double(max(0, n)))]) } }
            Text("jobs por dia").font(.collieUI(13)).foregroundStyle(Color.collieMuted)
        }
        if let t = s.trustNote { muted(t) }
        HStack {
            Button("Testar agora") { send([:]) }.buttonStyle(CollieButtonStyle(.quiet))
            Button("Testar com uma chamada…") { confirmCall = true }.buttonStyle(CollieButtonStyle(.quiet))
        }
        .disabled(!connected || working)
        if let t = s.testLine { muted(t) }
        if let callLine { muted(callLine) }
    }

    private var connected: Bool { client.state == .connected }

    private func pick(_ row: CuratorSettings.Row) {
        if let args = CuratorSettings.choose(row, accepted: false) { send(args) } else { pending = row }
    }

    private func load() async {
        guard connected else { return }
        await call([:])
    }

    /// Any change also asks `test` (no token): the rows, reasons and models come back fresh.
    private func send(_ args: [String: JSONValue]?) {
        guard let args else { return }
        working = true
        Task { await call(args); working = false }
    }

    private func call(_ args: [String: JSONValue]) async {
        do {
            var a = args; a["test"] = .bool(true)
            s = CuratorSettings.from(reply: try await client.adminCall("memory.curator", a))
            cap = s.map { String($0.info.cap) } ?? cap
            error = nil
        } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
    }

    private func testCall() {
        working = true; callLine = nil
        Task {
            do { callLine = CuratorSettings.testCallLine(try await client.adminCall("memory.curator", ["testCall": .bool(true)], timeout: 200)) }
            catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            await call([:])
            working = false
        }
    }

    private func muted(_ t: String) -> some View { Text(t).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
}
