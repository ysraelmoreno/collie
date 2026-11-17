import Testing
import Foundation
import CollieCore
import CollieClient
import CollieProtocol
@testable import CollieApp

/// Preferências › Atualizações and the install sheet (spec 2026-11-17 §3, §5): the model alone, no UI.
struct UpdateModelTests {
    static let en = Locale(identifier: "en_US")

    static func status(_ state: String, version: String = "0.2.0", size: Double = 41_711_021, engine: String = "0.7.0-c1",
                       phase: String? = nil, error: String? = nil, override: String? = nil, staged: String? = nil) -> UpdateStatus {
        var o: [String: JSONValue] = ["state": .string(state)]
        if state != "none", state != "disabled" {
            o["available"] = .object(["version": .string(version), "size": .number(size), "figcraftEngine": .string(engine),
                                      "page": .string("https://github.com/ysraelmoreno/collie/releases/tag/v\(version)")])
        }
        if let phase { o["job"] = .object(["phase": .string(phase), "bytes": .number(10), "total": .number(size)]) }
        if let error { o["error"] = .string(error) }
        if let override { o["override"] = .string(override) }
        if let staged { o["staged"] = .string(staged) }
        o["lastCheck"] = .string("2026-11-17T10:00:00Z")
        return UpdateStatus.from(.object(o))!
    }

    @Test func decodesStatus() {
        let s = Self.status("ready", staged: "/r/.update-staging/Collie-0.2.0.dmg")
        #expect(s.state == "ready" && s.available?.version == "0.2.0" && s.available?.size == 41_711_021)
        #expect(s.available?.figcraftEngine == "0.7.0-c1" && s.staged == "/r/.update-staging/Collie-0.2.0.dmg")
        #expect(s.lastCheck == ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z"))
        #expect(UpdateStatus.from(.object([:])) == nil)
    }

    @Test func cardShowsVersionAndSize() {
        let c = UpdateModel.card(Self.status("available"), locale: Self.en)
        #expect(c?.title == "Collie 0.2.0 disponível · 41.7 MB")
        #expect(c?.link == "Ver novidades no GitHub")
        #expect(c?.page == URL(string: "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0"))
        #expect(c?.primary == "Instalar…" && c?.skip == "Pular esta versão")
        #expect(UpdateModel.card(Self.status("none")) == nil)
        #expect(UpdateModel.card(Self.status("disabled")) == nil)
    }

    @Test func cardWhileDownloading() {
        let c = UpdateModel.card(Self.status("available", phase: "downloading"), locale: Self.en)
        #expect(c?.primary == nil && c?.progress == "10 bytes de 41.7 MB")
        #expect(UpdateModel.card(Self.status("available", phase: "verifying"))?.progress == "Conferindo assinatura…")
    }

    @Test func failedCardShowsTheError() {
        let c = UpdateModel.card(Self.status("failed", phase: "failed", error: "a release mudou durante o download"), locale: Self.en)
        #expect(c?.error == "a release mudou durante o download" && c?.primary == "Tentar de novo")
    }

    @Test func badgeStates() {
        #expect(UpdateModel.badge(nil) == nil)
        #expect(UpdateModel.badge(Self.status("none")) == nil)
        #expect(UpdateModel.badge(Self.status("available")) == "↑")
        #expect(UpdateModel.badge(Self.status("ready")) == "↑")
        #expect(UpdateModel.badge(Self.status("available", phase: "downloading")) == "↓")
        #expect(UpdateModel.badge(Self.status("failed", phase: "failed")) == "!")
    }

    @Test func activityCountsOpenAndBusyTerminals() {
        func t(_ name: String) -> TerminalRecord { TerminalRecord(id: UUID(), name: name, preset: .claude, command: nil, cwd: "/", isShepherd: false) }
        let a = t("collie-dx"), b = t("apps-dev"), c = t("shell"), d = t("old")
        let act = UpdateModel.activity(terminals: [a, b, c, d], badges: [a.id: .working, b.id: .working, c.id: .idle, d.id: .stopped])
        #expect(act.open == 3 && act.busy == ["collie-dx", "apps-dev"])
    }

    @Test func sheetNoTerminals() {
        let s = UpdateModel.sheet(version: "0.2.0", open: 0, busy: [], restart: false, engine: nil)
        #expect(s.title == "Instalar Collie 0.2.0")
        #expect(s.intro == "O Collie vai fechar e reabrir")
        #expect(s.options.isEmpty && s.primary == "Instalar e reabrir" && s.onQuit == "Instalar ao sair")
    }

    @Test func sheetWithTerminals() {
        let s = UpdateModel.sheet(version: "0.2.0", open: 3, busy: ["collie-dx", "apps-dev"], restart: false, engine: nil)
        #expect(s.intro == "Há 3 terminais abertos (2 agentes trabalhando agora: collie-dx, apps-dev).")
        #expect(s.options == ["Atualizar só o app — os terminais continuam rodando.",
                              "Atualizar e reiniciar o serviço — fecha os 3 terminais."])
        #expect(s.primary == "Instalar e reabrir")   // "only the app" is the default: no wait
        let one = UpdateModel.sheet(version: "0.2.0", open: 1, busy: [], restart: false, engine: nil)
        #expect(one.intro == "Há 1 terminal aberto.")
        #expect(one.options[1] == "Atualizar e reiniciar o serviço — fecha o terminal.")
    }

    @Test func sheetBusyShowsWait() {
        let s = UpdateModel.sheet(version: "0.2.0", open: 3, busy: ["collie-dx", "apps-dev"], restart: true, engine: nil)
        #expect(s.primary == "Esperar e instalar")
        #expect(s.waiting == "esperando collie-dx, apps-dev…")
        let idle = UpdateModel.sheet(version: "0.2.0", open: 3, busy: [], restart: true, engine: nil)
        #expect(idle.primary == "Instalar e reabrir" && idle.waiting == nil)
    }

    @Test func sheetEngineChange() {
        let e = UpdateModel.engineChange(manifest: "0.8.0-c1", installed: "0.7.0-c1")
        #expect(e == "0.8.0-c1")
        #expect(UpdateModel.engineChange(manifest: "0.7.0-c1", installed: "0.7.0-c1") == nil)
        #expect(UpdateModel.engineChange(manifest: "0.8.0-c1", installed: nil) == nil)   // no engine downloaded: nothing blocks
        let s = UpdateModel.sheet(version: "0.2.0", open: 0, busy: [], restart: false, engine: e)
        #expect(s.engine == "O desenho fica indisponível até baixar o motor 0.8.0-c1 depois de reiniciar o serviço")
    }

    @Test func unknownCommandShowsRestartForChecks() {
        let e = RestartHint.wrap(ProtocolError(code: .invalidArgs, message: "Unknown command 'app.update.status'"))
        #expect(UpdateModel.loadError(e) == "reinicie o serviço para procurar atualizações")
        #expect(UpdateModel.loadError(ProtocolError(code: .invalidArgs, message: "Unknown command 'app.update.status'"))
                == "reinicie o serviço para procurar atualizações")
        #expect(UpdateModel.loadError(ProtocolError(code: .unavailable, message: "x")) == "x")
    }

    @Test func overrideShown() {
        #expect(UpdateModel.sourceNote(Self.status("none", override: "file:///tmp/u/update.json")) == "fonte de teste: file:///tmp/u/update.json")
        #expect(UpdateModel.sourceNote(Self.status("none")) == nil)
    }

    @Test func stateLine() {
        let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!
        #expect(UpdateModel.stateLine(installed: "0.1.1", status: Self.status("none"), now: now)
                == "Versão instalada 0.1.1 · última verificação há 2 h")
        var s = Self.status("none"); s.error = "The Internet connection appears to be offline."
        #expect(UpdateModel.stateLine(installed: "0.1.1", status: s, now: now) == "Versão instalada 0.1.1 · sem conexão")
        #expect(UpdateModel.stateLine(installed: "0.1.1", status: nil, now: now) == "Versão instalada 0.1.1")
    }

    @Test func refusalTexts() {
        let move = "Mova o Collie para /Applications para atualizar por aqui"
        for r: AppUpdateSwap.Refusal in [.translocated, .readOnly, .notWritable, .tccFolder] { #expect(UpdateModel.text(r) == move, "\(r)") }
        #expect(UpdateModel.text(.localBuild) == "Build local: atualize pelos scripts")
        #expect(UpdateModel.text(.lowSpace) == "Espaço insuficiente")
        #expect(UpdateModel.text(.badVersion("0.1.9")) == "o dmg traz a versão 0.1.9, não a anunciada; nada foi instalado")
        #expect(UpdateModel.text(.badSignature) == "a assinatura do app baixado não confere; nada foi instalado")
        #expect(UpdateModel.text(.swapFailed("Permission denied")) == "não foi possível instalar: Permission denied")
        #expect(UpdateModel.offersDownloadPage(.translocated) && UpdateModel.offersDownloadPage(.notWritable))
        #expect(!UpdateModel.offersDownloadPage(.badSignature) && !UpdateModel.offersDownloadPage(.localBuild))
    }

    @Test func notifyOncePerReadyVersion() {
        #expect(UpdateModel.shouldNotify(Self.status("ready"), lastNotified: nil) == "0.2.0")
        #expect(UpdateModel.shouldNotify(Self.status("ready"), lastNotified: "0.2.0") == nil)
        #expect(UpdateModel.shouldNotify(Self.status("available"), lastNotified: nil) == nil)
    }

    @Test func updatedNotice() {
        #expect(UpdateModel.updatedNotice(justUpdated: "0.2.0", running: "0.2.0") == "Atualizado para 0.2.0")
        #expect(UpdateModel.updatedNotice(justUpdated: "0.2.0", running: "0.1.1") == nil)   // the swap didn't take
        #expect(UpdateModel.updatedNotice(justUpdated: nil, running: "0.2.0") == nil)
    }

    @Test func rollbackLabel() {
        #expect(UpdateModel.rollbackLabel(previous: "0.1.1") == "Voltar para 0.1.1")
        #expect(UpdateModel.rollbackLabel(previous: nil) == nil)
    }
}

extension UpdateModelTests {
    /// The daemon's `available` is the whole checked manifest: the app decodes it strictly for `prepare`.
    @Test func availableCarriesTheManifest() {
        let full: [String: JSONValue] = [
            "format": .number(1), "version": .string("0.2.0"), "tag": .string("v0.2.0"), "dmg": .string("Collie-0.2.0.dmg"),
            "size": .number(100), "sha256": .string(String(repeating: "a", count: 64)), "minimumSystemVersion": .string("15.0"),
            "teamId": .string("AG8JQAH6YB"), "figcraftEngine": .string("0.7.0-c1"),
            "page": .string("https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0")]
        let s = UpdateStatus.from(.object(["state": .string("ready"), "available": .object(full)]))
        #expect(s?.available?.manifest?.sha256 == String(repeating: "a", count: 64))
        #expect(Self.status("ready").available?.manifest == nil)   // a partial reply: nothing to install from
    }
}
