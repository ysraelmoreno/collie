import Testing
import Foundation
import CollieProtocol
@testable import CollieApp

/// Preferências › Memória › "Curador da memória" (plan 2026-11-17 curator provider, Task 13): the model alone, no UI.
struct CuratorPreferencesTests {
    private func row(_ p: String, installed: Bool, available: Bool, why: String, consent: Bool = false) -> JSONValue {
        .object(["provider": .string(p), "installed": .bool(installed), "available": .bool(available), "availability": .string(why),
                 "consentNeeded": .bool(consent), "destination": .string(p == "claude" ? "Anthropic" : "Cursor")])
    }
    private func reply(provider: String? = "claude", rows: [JSONValue], test: JSONValue? = nil, trust: String = "full") -> JSONValue {
        var o: [String: JSONValue] = ["available": .bool(true), "today": .number(3), "cap": .number(40), "queued": .number(0),
                                      "failed": .number(0), "inputTokens": .number(0), "outputTokens": .number(0), "costUSD": .number(0),
                                      "model": .string("haiku"), "trust": .string(trust), "destination": .string("Anthropic"),
                                      "providers": .array(rows)]
        if let provider { o["provider"] = .string(provider) }
        if let test { o["test"] = test }
        return .object(o)
    }

    /// Each provider says installed or not, available or not, and why.
    @Test func rowsSayInstalledAvailableAndWhy() throws {
        let s = try #require(CuratorSettings.from(reply: reply(rows: [
            row("claude", installed: true, available: true, why: "disponível"),
            row("cursor", installed: false, available: false, why: "provedor ainda não habilitado nesta versão")])))
        #expect(s.rows.map(\.name) == ["Claude", "Cursor"])
        #expect(s.rows[0].detail == "instalado · disponível · dados vão para a Anthropic" && s.rows[0].selectable)
        #expect(s.rows[1].detail == "não instalado · indisponível: provedor ainda não habilitado nesta versão" && !s.rows[1].selectable)
        let missing = try #require(CuratorSettings.from(reply: reply(rows: [row("claude", installed: false, available: false, why: "claude não encontrado")])))
        #expect(missing.rows[0].detail == "não instalado · indisponível: claude não encontrado")
        let metered = CuratorSettings.Row(provider: "claude", installed: true, available: false,
                                          availability: "Claude: login com cobrança por uso ou não reconhecido; consentimento necessário",
                                          consentNeeded: true, destination: "Anthropic")
        #expect(metered.selectable && metered.detail == "instalado · falta seu consentimento: login com cobrança por uso")
    }

    /// Choosing a provider that needs consent sends nothing until the sheet is accepted; then consent and provider together.
    @Test func consentBeforeChoosing() {
        let cursor = CuratorSettings.Row(provider: "cursor", installed: true, available: false, availability: "falta confirmar nas Preferências",
                                         consentNeeded: true, destination: "Cursor")
        #expect(CuratorSettings.choose(cursor, accepted: false) == nil)
        #expect(CuratorSettings.choose(cursor, accepted: true) == ["consent": .string("cursor"), "provider": .string("cursor")])
        let claude = CuratorSettings.Row(provider: "claude", installed: true, available: true, availability: "disponível",
                                         consentNeeded: false, destination: "Anthropic")
        #expect(CuratorSettings.choose(claude, accepted: false) == ["provider": .string("claude")])
    }

    @Test func consentCopy() {
        #expect(CuratorSettings.consentText("cursor") == "O curador lê trechos das suas conversas, documentos e memórias deste Mac e os envia ao Cursor e aos fornecedores de modelo dele, sob o Privacy Mode e o plano da sua conta. Se o seu plano cobra por uso além do incluído, os jobs do curador contam. Nada é enviado por chave de API.")
        let c = CuratorSettings.consentText("claude")
        #expect(c.contains("Anthropic") && c.contains("cobra por uso") && c.contains("contam"), "\(c)")
    }

    /// An older daemon has no `provider`: the section asks for a restart; limited trust is said; models come from `test`.
    @Test func restartTrustAndModels() throws {
        let old = try #require(CuratorSettings.from(reply: reply(provider: nil, rows: [])))
        #expect(old.restartNote == "reinicie o serviço para usar isto")
        let s = try #require(CuratorSettings.from(reply: reply(rows: [], test: .object(["availability": .string("disponível"),
                                                                                       "models": .array([.string("haiku"), .string("sonnet")])]),
                                                               trust: "limited")))
        #expect(s.restartNote == nil && s.models == ["haiku", "sonnet"] && s.modelChoices == ["haiku", "sonnet"])
        #expect(s.trustNote == "Confiança limitada: criar vira proposta; ativar, apagar ou reescrever vira pergunta.")
        #expect(s.testLine == "Teste: disponível · modelos: haiku, sonnet")
        #expect(CuratorSettings.from(reply: .null) == nil)
    }

    /// "Entrar no Cursor para o curador" shows only for an installed Cursor that has no curator login yet.
    @Test func loginOfferedOnlyWhenLoggedOut() {
        func r(_ installed: Bool, _ why: String, _ p: String = "cursor") -> CuratorSettings.Row {
            .init(provider: p, installed: installed, available: false, availability: why, consentNeeded: false, destination: "Cursor")
        }
        #expect(r(true, "cursor sem login para o curador").canLogin)
        #expect(!r(false, "cursor não encontrado").canLogin && !r(true, "falta confirmar nas Preferências").canLogin)
        #expect(!r(true, "cursor sem login para o curador", "claude").canLogin)
        #expect(CuratorSettings.loginLabel == "Entrar no Cursor para o curador")
    }

    @Test func testCallLine() {
        let r: JSONValue = .object(["testCall": .array([.object(["format": .string("ops"), "result": .string("ok")]),
                                                        .object(["format": .string("items"), "result": .string("junk")])])])
        #expect(CuratorSettings.testCallLine(r) == "Chamada de teste: ops ok · items junk")
    }
}
