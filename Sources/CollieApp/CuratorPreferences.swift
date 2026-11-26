import SwiftUI
import CollieCore
import CollieTheme
import CollieClient
import CollieProtocol
import ColliePlugins

/// Preferências › Memória › "Curador da memória" (spec 2026-11-17 curator provider §6–7): `memory.curator`'s status read
/// into what the section shows. Pure: the view only draws it and sends what `choose` returns.
struct CuratorSettings: Equatable {
    struct Row: Equatable, Identifiable {
        var provider: String, installed: Bool, available: Bool, availability: String, consentNeeded: Bool, destination: String
        /// The daemon's stable reason code (`CuratorReason`: "noLogin", "paidLogin"…); `availability` is only text to show.
        var code: String? = nil
        var id: String { provider }
        var name: String { provider.capitalized }
        /// An installed Cursor with no curator login yet: offer "Entrar" (Collie never logs it in by itself).
        var canLogin: Bool { provider == "cursor" && installed && code == "noLogin" }
        /// Available now, or only a consent away (the sheet).
        var selectable: Bool { available || consentNeeded }
        var detail: String {
            let inst = installed ? tr("instalado", "installed") : tr("não instalado", "not installed")
            if available { return tr("\(inst) · disponível · dados vão para \(CuratorSettings.to(destination))", "\(inst) · available · data goes to \(CuratorSettings.to(destination))") }
            if consentNeeded {
                let why = code == "paidLogin" ? tr("login com cobrança por uso", "pay-per-use login")
                    : tr("dados vão para \(CuratorSettings.to(destination))", "data goes to \(CuratorSettings.to(destination))")
                return tr("\(inst) · falta seu consentimento: \(why)", "\(inst) · needs your consent: \(why)")
            }
            return tr("\(inst) · indisponível: \(availability)", "\(inst) · unavailable: \(availability)")
        }
    }

    static var loginLabel: String { tr("Entrar no Cursor para o curador", "Log in to Cursor for the curator") }

    var info: CuratorInfo
    var rows: [Row]
    /// From `test` (`models()`, no token spent); [] when not asked or free text.
    var models: [String]
    var testLine: String?

    /// An older daemon (no `provider`): nothing here works until it restarts.
    var restartNote: String? { info.provider == nil ? tr("reinicie o serviço para usar isto", "restart the service to use this") : nil }
    var trustNote: String? {
        info.trust == "limited"
            ? tr("Confiança limitada: criar vira proposta; ativar, apagar ou reescrever vira pergunta.",
                 "Limited trust: creating becomes a proposal; activating, deleting or rewriting becomes a question.") : nil
    }
    /// The model picker: Claude's list as is ("" would reach `--model`); another provider also offers its account default.
    var modelChoices: [String] { (info.provider ?? "claude") == "claude" ? models : [""] + models }

    static func from(reply: JSONValue) -> CuratorSettings? {
        guard case .object(let o) = reply, let data = try? JSONEncoder().encode(reply),
              let info = try? JSONDecoder().decode(CuratorInfo.self, from: data) else { return nil }
        // `code` isn't in `CuratorProviderEntry` (another module): read it from the reply
        var codes: [String: String] = [:]
        if case .array(let ps)? = o["providers"] {
            for case .object(let p) in ps { if case .string(let n)? = p["provider"], case .string(let c)? = p["code"] { codes[n] = c } }
        }
        let rows = (info.providers ?? []).map {
            Row(provider: $0.provider, installed: $0.installed, available: $0.available, availability: $0.availability,
                consentNeeded: $0.consentNeeded, destination: $0.destination, code: codes[$0.provider])
        }
        var models: [String] = [], testLine: String?
        if case .object(let t)? = o["test"] {
            if case .array(let ms)? = t["models"] { models = ms.compactMap { if case .string(let s) = $0 { s } else { nil } } }
            if case .string(let a)? = t["availability"] {
                testLine = tr("Teste: \(a)", "Test: \(a)") + (models.isEmpty ? "" : tr(" · modelos: ", " · models: ") + models.joined(separator: ", "))
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
            tr("O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia ao Cursor e aos fornecedores de modelo dele, sob o Privacy Mode e o plano da sua conta. Se o seu plano cobra por uso além do incluído, os jobs do curador contam. Nada é enviado por chave de API.",
               "The curator reads excerpts of your conversations, documents and memories on this Mac and sends them to Cursor and its model providers, under Privacy Mode and your account's plan. If your plan bills per use beyond what's included, the curator's jobs count. Nothing is sent by API key.")
        case "claude":
            tr("O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia à Anthropic pelo login do claude deste Mac. Esse login não é a assinatura: ele cobra por uso (conta de API) ou não foi reconhecido, e os jobs do curador contam na cobrança, até o limite diário. Nada é enviado por chave de API do seu shell.",
               "The curator reads excerpts of your conversations, documents and memories on this Mac and sends them to Anthropic through this Mac's claude login. That login isn't the subscription: it bills per use (API account) or wasn't recognized, and the curator's jobs count toward the bill, up to the daily limit. Nothing is sent by an API key from your shell.")
        default:
            tr("O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia a \(provider.capitalized). Se o login cobra por uso, os jobs do curador contam.",
               "The curator reads excerpts of your conversations, documents and memories on this Mac and sends them to \(provider.capitalized). If the login bills per use, the curator's jobs count.")
        }
    }

    /// `testCall`'s results: "Chamada de teste: ops ok · items junk · chunks ok" ("Test call: …").
    static func testCallLine(_ reply: JSONValue) -> String? {
        guard case .object(let o) = reply, case .array(let xs)? = o["testCall"] else { return nil }
        let parts = xs.compactMap { x -> String? in
            guard case .object(let e) = x, case .string(let f)? = e["format"], case .string(let r)? = e["result"] else { return nil }
            return "\(f) \(r)"
        }
        return tr("Chamada de teste: ", "Test call: ") + parts.joined(separator: " · ")
    }

    static func to(_ destination: String) -> String {
        switch destination {
        case "Anthropic": tr("a Anthropic", "Anthropic")
        case "Cursor": tr("o Cursor", "Cursor")
        default: destination
        }
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
            Text(tr("Curador da memória", "Memory curator")).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            if let s, let note = s.restartNote { muted(note) } else if let s { settings(s) } else { muted(connected ? "…" : "—") }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task(id: connected) { await load() }
        .alert(tr("Enviar dados ao curador?", "Send data to the curator?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { row in
            Button(tr("Confirmar", "Confirm")) { send(CuratorSettings.choose(row, accepted: true)) }
            Button(tr("Cancelar", "Cancel"), role: .cancel) {}
        } message: { row in Text(CuratorSettings.consentText(row.provider)) }
        .confirmationDialog(tr("Fazer 3 chamadas de teste?", "Make 3 test calls?"), isPresented: $confirmCall) {
            Button(tr("Testar (contam 3 no limite de hoje)", "Test (counts 3 toward today's limit)")) { testCall() }
        } message: { Text(tr("Uma por formato de resposta, com dados sintéticos. Nada é gravado na memória.", "One per answer format, with synthetic data. Nothing is written to memory.")) }
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
                if row.canLogin {
                    Button(CuratorSettings.loginLabel) { login() }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || working)
                }
                if row.consentNeeded, s.info.provider == row.provider {
                    Button(tr("Confirmar…", "Confirm…")) { pending = row }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || working)
                }
            }
        }
        if !s.info.available, let why = s.info.reason { muted(tr("curador indisponível: \(why)", "curator unavailable: \(why)")) }
        if !s.modelChoices.isEmpty {
            Picker(tr("Modelo", "Model"), selection: Binding(get: { s.info.model ?? "" }, set: { send(["model": .string($0), "provider": .string(s.info.provider ?? "claude")]) })) {
                ForEach(s.modelChoices, id: \.self) { Text($0.isEmpty ? tr("padrão da conta", "account default") : $0).tag($0) }
            }
            .frame(maxWidth: 280).disabled(!connected || working)
        }
        HStack {
            Text(tr("Limite", "Limit")).font(.collieUI(13))
            // empty: no cap (the default)
            TextField(tr("sem limite", "no limit"), text: $cap).frame(width: 84).onSubmit {
                let t = cap.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { send(["noCap": .bool(true)]) } else if let n = Int(t) { send(["cap": .number(Double(max(0, n)))]) }
            }
            Text(tr("jobs por dia (vazio: sem limite; 0: desligado)", "jobs per day (empty: no limit; 0: off)")).font(.collieUI(13)).foregroundStyle(Color.collieMuted)
        }
        if let t = s.trustNote { muted(t) }
        HStack {
            Button(tr("Testar agora", "Test now")) { send([:]) }.buttonStyle(CollieButtonStyle(.quiet))
            Button(tr("Testar com uma chamada…", "Test with a call…")) { confirmCall = true }.buttonStyle(CollieButtonStyle(.quiet))
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
            cap = s.map { $0.info.cap.map(String.init) ?? "" } ?? cap
            error = nil
        } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
    }

    /// A new terminal with the curator's own Cursor login (its cursor-home, never the user's `~/.cursor`); unsandboxed
    /// because it writes Collie's data dir. The rows refresh after (the runner retries a missing login within 30 s).
    private func login() {
        working = true; error = nil
        Task {
            do {
                guard case .object(let o) = try await client.adminCall("memory.curator", ["cursorLogin": .bool(true)]),
                      case .string(let line)? = o["cursorLogin"] else { throw ProtocolError(code: .internal, message: tr("resposta sem comando de login", "reply without a login command")) }
                _ = try await client.spawn(name: "cursor-login-" + UUID().uuidString.prefix(4).lowercased(), preset: .custom, command: line,
                                           cwd: NSHomeDirectory(), shepherd: false, sandbox: .free)
            } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            working = false
        }
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
