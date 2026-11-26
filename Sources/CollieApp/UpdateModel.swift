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
    var link = tr("Ver novidades no GitHub", "See what's new on GitHub")
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
    var onQuit = tr("Instalar ao sair", "Install on quit")
    var waiting: String?
    var engine: String?
}

/// Preferências › Atualizações and the install sheet, as pure functions over `app.update.status` (spec 2026-11-17).
enum UpdateModel {
    static var moveToApplications: String { tr("Mova o Collie para /Applications para atualizar por aqui", "Move Collie to /Applications to update from here") }
    static var localBuild: String { tr("Build local: atualize pelos scripts", "Local build: update with the scripts") }
    static var restartForChecks: String { tr("reinicie o serviço para procurar atualizações", "restart the service to check for updates") }
    static let notifiedKey = "update.notifiedVersion"
    static let justUpdatedKey = "update.justUpdated"
    static let restartedKey = "update.restartedService"
    static let onQuitKey = "update.installOnQuit"

    static func size(_ n: Int64, _ locale: Locale) -> String { n.formatted(.byteCount(style: .file).locale(locale)) }

    static func card(_ s: UpdateStatus, locale: Locale = .current) -> UpdateCard? {
        guard let a = s.available, ["available", "ready", "failed"].contains(s.state) else { return nil }
        var c = UpdateCard(title: tr("Collie \(a.version) disponível · \(size(a.size, locale))", "Collie \(a.version) available · \(size(a.size, locale))"), page: a.page)
        switch s.job?.phase {
        case "downloading": c.progress = tr("\(size(s.job!.bytes, locale)) de \(size(s.job!.total > 0 ? s.job!.total : a.size, locale))", "\(size(s.job!.bytes, locale)) of \(size(s.job!.total > 0 ? s.job!.total : a.size, locale))")
        case "verifying": c.progress = tr("Conferindo assinatura…", "Checking signature…")
        default:
            c.skip = tr("Pular esta versão", "Skip this version")
            if s.state == "failed" { c.error = s.error ?? s.job?.error; c.primary = tr("Tentar de novo", "Try again") } else { c.primary = tr("Instalar…", "Install…") }
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

    /// `restart`: the "restart the service" choice is selected (a busy agent then makes the install wait).
    static func sheet(version: String, open: Int, busy: [String], restart: Bool, engine: String?) -> InstallSheetText {
        let intro: String, options: [String], notes: [String]
        if open == 0 {
            intro = tr("O Collie vai fechar e reabrir", "Collie will close and reopen"); options = []; notes = []
        } else {
            let names = busy.joined(separator: ", ")
            let termsPt = open == 1 ? "Há 1 terminal aberto" : "Há \(open) terminais abertos"
            let agentsPt = busy.isEmpty ? "" : " (\(busy.count == 1 ? "1 agente trabalhando" : "\(busy.count) agentes trabalhando") agora: \(names))"
            let termsEn = open == 1 ? "There is 1 open terminal" : "There are \(open) open terminals"
            let agentsEn = busy.isEmpty ? "" : " (\(busy.count == 1 ? "1 agent working" : "\(busy.count) agents working") now: \(names))"
            intro = tr(termsPt + agentsPt + ".", termsEn + agentsEn + ".")
            options = [tr("Atualizar só o app — os terminais continuam rodando.", "Update only the app — terminals keep running."),
                       tr("Atualizar e reiniciar o serviço — fecha \(open == 1 ? "o terminal" : "os \(open) terminais").",
                          "Update and restart the service — closes \(open == 1 ? "the terminal" : "all \(open) terminals").")]
            notes = [tr("O serviço antigo segue até você reiniciá-lo. Os hooks e o MCP dos agentes já passam a ser os da versão nova; um comando novo responde \"\(RestartHint.text)\".",
                        "The old service keeps running until you restart it. The agents' hooks and MCP already become the new version's; a new command answers \"\(RestartHint.text)\"."),
                     tr("Agentes voltam pelo resume.", "Agents come back through resume.")]
        }
        let wait = restart && !busy.isEmpty
        return InstallSheetText(title: tr("Instalar Collie \(version)", "Install Collie \(version)"), intro: intro, options: options, optionNotes: notes,
                                primary: wait ? tr("Esperar e instalar", "Wait and install") : tr("Instalar e reabrir", "Install and reopen"),
                                waiting: wait ? tr("esperando \(busy.joined(separator: ", "))…", "waiting for \(busy.joined(separator: ", "))…") : nil,
                                engine: engine.map { tr("O desenho fica indisponível até baixar o motor \($0) depois de reiniciar o serviço", "Design stays unavailable until you download engine \($0) after restarting the service") })
    }

    /// I10: the new version pins another engine than the downloaded one; nil when it is the same or none is downloaded.
    static func engineChange(manifest: String?, installed: String?) -> String? {
        guard let manifest, let installed, manifest != installed else { return nil }
        return manifest
    }

    /// An `app.update.*` error for the page: a daemon from before the updater (unknown command) needs a restart.
    static func loadError(_ e: ProtocolError) -> String {
        if RestartHint.isHint(e.message) || RestartHint.isHint(RestartHint.wrap(e).message) { return restartForChecks }
        return e.message
    }

    static func sourceNote(_ s: UpdateStatus?) -> String? { s?.override.map { tr("fonte de teste: \($0)", "test source: \($0)") } }

    /// "Versão instalada X · última verificação há 2 h" (or "sem conexão" after a failed read).
    static func stateLine(installed: String, status: UpdateStatus?, now: Date = Date()) -> String {
        let base = tr("Versão instalada \(installed)", "Installed version \(installed)")
        guard let s = status else { return base }
        if s.error != nil, s.state != "failed" { return tr("Versão instalada \(installed) · sem conexão", "Installed version \(installed) · offline") }
        guard let t = s.lastCheck else { return base }
        let secs = max(0, Int(now.timeIntervalSince(t)))
        let agoPt = secs < 60 ? "agora" : secs < 3600 ? "há \(secs / 60) min" : secs < 86_400 ? "há \(secs / 3600) h" : "há \(secs / 86_400) d"
        let agoEn = secs < 60 ? "just now" : secs < 3600 ? "\(secs / 60) min ago" : secs < 86_400 ? "\(secs / 3600) h ago" : "\(secs / 86_400) d ago"
        return tr("Versão instalada \(installed) · última verificação \(agoPt)", "Installed version \(installed) · last check \(agoEn)")
    }

    static func text(_ r: AppUpdateSwap.Refusal) -> String {
        switch r {
        case .translocated, .readOnly, .notWritable, .tccFolder: moveToApplications
        case .localBuild: localBuild
        case .lowSpace: tr("Espaço insuficiente", "Not enough space")
        case .badVersion(let v): tr("o dmg traz a versão \(v), não a anunciada; nada foi instalado", "the dmg has version \(v), not the announced one; nothing was installed")
        case .badSignature: tr("a assinatura do app baixado não confere; nada foi instalado", "the downloaded app's signature does not match; nothing was installed")
        case .swapFailed(let m): tr("não foi possível instalar: \(m)", "could not install: \(m)")
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
        return tr("Atualizado para \(v)", "Updated to \(v)")
    }

    static func rollbackLabel(previous: String?) -> String? { previous.map { tr("Voltar para \($0)", "Go back to \($0)") } }
}
