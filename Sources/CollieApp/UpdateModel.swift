import Foundation
import CollieCore
import CollieClient
import CollieProtocol

/// `app.update.status`, decoded tolerantly (like `DesignEngineStatus.from`): nil only when `state` is missing.
struct UpdateStatus: Equatable {
    struct Available: Equatable {
        var version: String; var size: Int64; var page: URL?; var figcraftEngine: String?
        /// The whole manifest the daemon checked (nil when the reply lacks a field): what `AppUpdateSwap.prepare` checks against.
        var manifest: UpdateManifest?
    }
    struct Job: Equatable { var phase: String; var bytes: Int64 = 0; var total: Int64 = 0; var error: String? }
    /// none | available | ready | failed | disabled
    var state: String
    var available: Available?
    var job: Job?
    var lastCheck: Date?
    var error: String?
    var override: String?
    var staged: String?

    static let runningPhases: Set<String> = ["downloading", "verifying"]
    var running: Bool { job.map { Self.runningPhases.contains($0.phase) } ?? false }

    static func from(_ v: JSONValue) -> UpdateStatus? {
        guard case .object(let o) = v, case .string(let state)? = o["state"] else { return nil }
        func s(_ d: [String: JSONValue]?, _ k: String) -> String? { if case .string(let x)? = d?[k] { x } else { nil } }
        func n(_ d: [String: JSONValue]?, _ k: String) -> Int64? { if case .number(let x)? = d?[k] { Int64(exactly: x.rounded()) } else { nil } }
        func obj(_ k: String) -> [String: JSONValue]? { if case .object(let x)? = o[k] { x } else { nil } }
        let a = obj("available"), j = obj("job")
        return UpdateStatus(
            state: state,
            available: s(a, "version").map { Available(version: $0, size: n(a, "size") ?? 0, page: s(a, "page").flatMap(URL.init(string:)),
                                                       figcraftEngine: s(a, "figcraftEngine"),
                                                       manifest: a.flatMap { try? UpdateManifest.decode(JSONEncoder().encode(JSONValue.object($0))) }) },
            job: s(j, "phase").map { Job(phase: $0, bytes: n(j, "bytes") ?? 0, total: n(j, "total") ?? 0, error: s(j, "error")) },
            lastCheck: s(o, "lastCheck").flatMap { ISO8601DateFormatter().date(from: $0) },
            error: s(o, "error"), override: s(o, "override"), staged: s(o, "staged"))
    }

    static func pollInterval(_ s: UpdateStatus?) -> Duration { s?.running == true ? .seconds(1) : .seconds(3) }
}

/// The "Collie X disponível" card of Preferências › Atualizações.
struct UpdateCard: Equatable {
    var title: String
    var link = "Ver novidades no GitHub"
    var page: URL?
    /// nil while a download runs (Cancelar is the view's).
    var primary: String?
    var skip: String?
    var progress: String?
    var error: String?
}

/// The install sheet's copy (spec §3): what runs now, the two choices, the buttons.
struct InstallSheetText: Equatable {
    var title: String
    var intro: String
    /// Empty without open terminals; else [only the app (the default), restart the service].
    var options: [String]
    var optionNotes: [String]
    var primary: String
    var onQuit = "Instalar ao sair"
    var waiting: String?
    var engine: String?
}

/// Preferências › Atualizações and the install sheet, as pure functions over `app.update.status` (spec 2026-11-17).
enum UpdateModel {
    static let moveToApplications = "Mova o Collie para /Applications para atualizar por aqui"
    static let localBuild = "Build local: atualize pelos scripts"
    static let restartForChecks = "reinicie o serviço para procurar atualizações"
    static let notifiedKey = "update.notifiedVersion"
    static let justUpdatedKey = "update.justUpdated"
    static let restartedKey = "update.restartedService"
    static let onQuitKey = "update.installOnQuit"

    static func size(_ n: Int64, _ locale: Locale) -> String { n.formatted(.byteCount(style: .file).locale(locale)) }

    static func card(_ s: UpdateStatus, locale: Locale = .current) -> UpdateCard? {
        guard let a = s.available, ["available", "ready", "failed"].contains(s.state) else { return nil }
        var c = UpdateCard(title: "Collie \(a.version) disponível · \(size(a.size, locale))", page: a.page)
        switch s.job?.phase {
        case "downloading": c.progress = "\(size(s.job!.bytes, locale)) de \(size(s.job!.total > 0 ? s.job!.total : a.size, locale))"
        case "verifying": c.progress = "Conferindo assinatura…"
        default:
            c.skip = "Pular esta versão"
            if s.state == "failed" { c.error = s.error ?? s.job?.error; c.primary = "Tentar de novo" } else { c.primary = "Instalar…" }
        }
        return c
    }

    /// The sidebar item's badge: `↓` while downloading, `!` after a failure, `↑` when a version is offered.
    static func badge(_ s: UpdateStatus?) -> String? {
        guard let s else { return nil }
        if s.running { return "↓" }
        switch s.state {
        case "failed": return "!"
        case "available", "ready": return "↑"
        default: return nil
        }
    }

    /// Terminals that would close on a service restart (any badge but stopped) and the agents working now.
    static func activity(terminals: [TerminalRecord], badges: [UUID: StatusBadge]) -> (open: Int, busy: [String]) {
        let open = terminals.filter { badges[$0.id].map { $0 != .stopped } ?? false }
        return (open.count, open.filter { badges[$0.id] == .working }.map(\.name))
    }

    /// Sparkle's relaunch is on hold: who is working now and what the two buttons do.
    static func busyNotice(version: String, busy: [String]) -> String {
        let n = busy.count == 1 ? "1 agente trabalhando" : "\(busy.count) agentes trabalhando"
        return "Há \(n) agora: \(busy.joined(separator: ", ")). Atualizar para \(version) fecha e reabre o Collie; "
            + "\"Depois\" espera os agentes terminarem e então instala."
    }

    /// `restart`: the "restart the service" choice is selected (a busy agent then makes the install wait).
    static func sheet(version: String, open: Int, busy: [String], restart: Bool, engine: String?) -> InstallSheetText {
        let intro: String, options: [String], notes: [String]
        if open == 0 {
            intro = "O Collie vai fechar e reabrir"; options = []; notes = []
        } else {
            let terms = open == 1 ? "Há 1 terminal aberto" : "Há \(open) terminais abertos"
            let agents = busy.isEmpty ? "" : " (\(busy.count == 1 ? "1 agente trabalhando" : "\(busy.count) agentes trabalhando") agora: \(busy.joined(separator: ", ")))"
            intro = terms + agents + "."
            options = ["Atualizar só o app — os terminais continuam rodando.",
                       "Atualizar e reiniciar o serviço — fecha \(open == 1 ? "o terminal" : "os \(open) terminais")."]
            notes = ["O serviço antigo segue até você reiniciá-lo. Os hooks e o MCP dos agentes já passam a ser os da versão nova; "
                     + "um comando novo responde \"\(RestartHint.text)\".",
                     "Agentes voltam pelo resume."]
        }
        let wait = restart && !busy.isEmpty
        return InstallSheetText(title: "Instalar Collie \(version)", intro: intro, options: options, optionNotes: notes,
                                primary: wait ? "Esperar e instalar" : "Instalar e reabrir",
                                waiting: wait ? "esperando \(busy.joined(separator: ", "))…" : nil,
                                engine: engine.map { "O desenho fica indisponível até baixar o motor \($0) depois de reiniciar o serviço" })
    }

    /// I10: the new version pins another engine than the downloaded one; nil when it is the same or none is downloaded.
    static func engineChange(manifest: String?, installed: String?) -> String? {
        guard let manifest, let installed, manifest != installed else { return nil }
        return manifest
    }

    /// An `app.update.*` error for the page: a daemon from before the updater (unknown command) needs a restart.
    static func loadError(_ e: ProtocolError) -> String {
        if e.message.contains(RestartHint.text) || RestartHint.wrap(e).message.contains(RestartHint.text) { return restartForChecks }
        return e.message
    }

    static func sourceNote(_ s: UpdateStatus?) -> String? { s?.override.map { "fonte de teste: \($0)" } }

    /// "Versão instalada X · última verificação há 2 h" (or "sem conexão" after a failed read).
    static func stateLine(installed: String, status: UpdateStatus?, now: Date = Date()) -> String {
        let base = "Versão instalada \(installed)"
        guard let s = status else { return base }
        if s.error != nil, s.state != "failed" { return base + " · sem conexão" }
        guard let t = s.lastCheck else { return base }
        let secs = max(0, Int(now.timeIntervalSince(t)))
        let ago = secs < 60 ? "agora" : secs < 3600 ? "há \(secs / 60) min" : secs < 86_400 ? "há \(secs / 3600) h" : "há \(secs / 86_400) d"
        return base + " · última verificação " + ago
    }

    static func text(_ r: AppUpdateSwap.Refusal) -> String {
        switch r {
        case .translocated, .readOnly, .notWritable, .tccFolder: moveToApplications
        case .localBuild: localBuild
        case .lowSpace: "Espaço insuficiente"
        case .badVersion(let v): "o dmg traz a versão \(v), não a anunciada; nada foi instalado"
        case .badSignature: "a assinatura do app baixado não confere; nada foi instalado"
        case .swapFailed(let m): "não foi possível instalar: \(m)"
        }
    }

    /// Where the app sits keeps it from updating itself: offer "Baixar o dmg" (the release page) instead.
    static func offersDownloadPage(_ r: AppUpdateSwap.Refusal) -> Bool {
        switch r { case .translocated, .readOnly, .notWritable, .tccFolder: true; default: false }
    }

    /// The version to announce with one system notification (once per version ready), or nil.
    static func shouldNotify(_ s: UpdateStatus, lastNotified: String?) -> String? {
        guard s.state == "ready", let v = s.available?.version, v != lastNotified else { return nil }
        return v
    }

    static func updatedNotice(justUpdated: String?, running: String) -> String? {
        guard let v = justUpdated, v == running else { return nil }
        return "Atualizado para \(v)"
    }

    static func rollbackLabel(previous: String?) -> String? { previous.map { "Voltar para \($0)" } }
}
