# Plano 1D — Sistema de plug-ins e Navegador — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Painéis de plug-in que ficam na doca ou no canvas, com comandos expostos automaticamente via CLI/MCP, acesso por corda/doca, um primeiro plug-in de Navegador (WKWebView controlável por agentes) e `panel.open` para o Maestro.

**Architecture:** O daemon é dono do **modelo** (painéis persistidos no `workspace.json`, acesso, roteamento de comandos). O app é o **host** que executa os painéis: abre um fluxo `ui.host` no daemon, e o daemon encaminha cada chamada de comando de plug-in (`browser.navigate`…) como frame para o app, com timeout e resultado limitado. O registro de plug-ins é compilado (`PluginRegistry`) e gera as `CommandSpec` que CLI e MCP já expõem. O Navegador vive num target novo `OrqPlugins` (testável) e o app só o hospeda.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI + AppKit, WebKit (WKWebView, `WKWebsiteDataStore(forIdentifier:)`). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (§6.1–6.4, §7.4, §10). Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: `main` em `b352e0c` (1A + 1B + 1C). Referência de comportamento: a análise de referência (local, não publicada) §3.4 (portal).

## Global Constraints

- macOS **15.0**, Swift 6.2, modo Swift 6 (concorrência estrita). Nenhuma dependência nova.
- **Cordas são a única permissão entre terminais, inclusive para o Maestro.** Para painéis (spec §6.2): painel **no canvas** só é alcançável por terminais ligados a ele por corda; painel **na doca** é global ao workspace (qualquer terminal). O admin (app) alcança todos.
- `admin.*`/`ui.*` continuam recusados de terminais gerenciados e de processos filhos do daemon (`descends` sobre `registry.livePids() ∪ BoundedProcess.livePids()`).
- Plug-ins de terceiros fora da v1, mas o modelo é o mesmo que um externo usaria (§6.4): **nada de atalho interno** — o Navegador se registra pelo mesmo `PluginRegistry`/`PluginSpec` e só recebe chamadas pelo canal `ui.host`.
- Painel fechado libera tudo (§6.3): webview desalocada, store `isolated` apagado do disco ao **excluir** o painel.
- Resultados de comando de plug-in limitados a **1 MiB** (truncou → `truncated: true`), timeout padrão **30 s** (`browser.wait` até 120 s). Nada pesado na main thread além do próprio WebKit.
- Protocolo `v: 1` (só comandos, frames e eventos novos). `workspace.json` passa a `schemaVersion: 3` e ainda lê v1/v2.
- Clean-room: não copiar código/JS/textos do portal do Maestri. Nomes `orq`, atributo DOM `data-orq-ref`.
- Testes de daemon usam `/bin/sh`; suítes pesadas `.serialized`; limites de tempo folgados (máquina carregada).

## Review Focus

1. **App fechado / host ausente** quando um agente chama `browser.*` → erro imediato `unavailable` "Orq app is not running", nunca trava até o timeout. Teste: Task 3 `callWithoutHostFailsFast`.
2. **Host lento ou travado** (página pesada, JS em loop) → timeout de 30 s com erro `timeout`, chamada seguinte funciona; a chamada pendente não vaza. Teste: Task 3 `hostTimeoutFreesCall`.
3. **Página gigante** (`browser.text`/`snapshot` de um site enorme) → resultado cortado em 1 MiB com `truncated: true`. Teste: Task 5 `snapshotIsBounded`.
4. **Terminal sem corda chama painel do canvas** de outro Maestro → `notConnected`; painel na doca → permitido. Teste: Task 2 `canvasPanelNeedsCord`, `dockPanelIsGlobal`.
5. **Excluir painel com store isolado** → dados do site removidos do disco (sem vazamento como no Maestri). Teste: Task 5 `deletingPanelRemovesIsolatedStore`.

---

## File Structure

```
Package.swift                                 (+ target OrqPlugins: OrqCore, OrqProtocol, WebKit)
Sources/OrqCore/Panels.swift                  Panel, PanelPlacement, StorageScope; Workspace.panels (schema 3)
Sources/OrqCore/StreamFrames.swift            (+ events .panel/.panelRemoved/.pluginEvent; StreamFrame .call/.reply)
Sources/OrqCore/ConnectionGraph.swift         (+ reachablePanels, resolvePanel)
Sources/OrqProtocol/Plugins.swift             PluginSpec, PluginRegistry (compilado), geração de CommandSpec
Sources/OrqProtocol/Commands.swift            (+ panel.open/close/move/list, events; all = core + registry)
Sources/OrqProtocol/Envelope.swift            (+ ErrorCode.unavailable)
Sources/OrqDaemonKit/PanelCommands.swift      panel.* + connect/disconnect com painéis
Sources/OrqDaemonKit/PluginHost.swift         fluxo ui.host, chamadas pendentes, timeout, teto
Sources/OrqPlugins/BrowserPanel.swift         WKWebView + store por escopo + limpeza
Sources/OrqPlugins/BrowserAutomation.swift    JS injetado (snapshot/refs, click, fill, type, key, scroll, text, wait, console)
Sources/OrqPlugins/BrowserCommands.swift      handler de browser.* para o host
Sources/OrqClient/HostConnection.swift        cliente do fluxo ui.host (reconexão junto com DaemonClient)
Sources/OrqApp/DockView.swift                 docas esquerda/direita/baixo com abas
Sources/OrqApp/PanelNodeView.swift            painel como nó do canvas
Sources/OrqApp/OpenPanelSheet.swift           abrir painel pelo usuário
Tests/OrqCoreTests/PanelModelTests.swift, Tests/OrqProtocolTests/PluginRegistryTests.swift
Tests/OrqDaemonKitTests/PanelCommandTests.swift, PluginHostTests.swift
Tests/OrqPluginsTests/BrowserAutomationTests.swift
```

---

### Task 1: Modelo de painéis e registro de plug-ins

**Files:** Create `Sources/OrqCore/Panels.swift`, `Sources/OrqProtocol/Plugins.swift`; Modify `Workspace.swift`, `StreamFrames.swift`, `ConnectionGraph.swift`, `Commands.swift`, `Envelope.swift`; Test `Tests/OrqCoreTests/PanelModelTests.swift`, `Tests/OrqProtocolTests/PluginRegistryTests.swift`

**Interfaces:**
```swift
public enum PanelPlacement: String, Codable, Sendable { case dockLeft = "dock.left", dockRight = "dock.right", dockBottom = "dock.bottom", canvas }
public enum StorageScope: String, Codable, Sendable { case isolated, workspace, global }   // padrão .isolated
public struct Panel: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID; public var name: String          // único entre terminais e painéis (case-insensitive)
  public var pluginId: String                           // "browser"
  public var placement: PanelPlacement
  public var floorId: UUID?                             // só relevante no canvas
  public var state: [String: JSONValue]                 // ex.: "url", "storage"
  public var createdBy: UUID?                           // Maestro que abriu; nil = app
}
Workspace.panels: [Panel]; schemaVersion = 3 (v1/v2 decodificam com panels = [])
WorkspaceEvent: .panel(Panel) (upsert), .panelRemoved(UUID), .pluginEvent(panel: UUID, name: String, payload: JSONValue)
WorkspaceSnapshot.panels: [Panel]
ConnectionGraph.reachablePanels(from: UUID, in: Workspace) -> [Panel]   // canvas: com corda; doca: todos
ConnectionGraph.resolvePanel(name: String?, plugin: String, from: UUID, in: Workspace) throws(ProtocolError) -> Panel
  // name nil: único painel alcançável daquele plugin, senão .ambiguous / .notFound; com nome: .notFound/.notConnected
ErrorCode.unavailable

public struct PluginSpec: Sendable {
  public var id: String; public var title: String
  public var placements: [PanelPlacement]; public var defaultPlacement: PanelPlacement
  public var commands: [CommandSpec]        // nomes "<id>.<cmd>"; cada um ganha o param "panel" (string, opcional)
  public var events: [String]               // "browser.loaded", "browser.console"
}
public enum PluginRegistry { public static let all: [PluginSpec]; public static func spec(_ id: String) -> PluginSpec?; public static func command(_ name: String) -> (PluginSpec, CommandSpec)? }
Commands.all = core + PluginRegistry.all.flatMap(\.commands)   // CLI e MCP passam a expô-los sem código extra
```
- **Comandos do Navegador** (todos com `panel` opcional; timeout 30 s salvo indicado):

| Comando | Params |
|---|---|
| `browser.navigate` | `url` (pos., obr.) |
| `browser.snapshot` | — (árvore compacta com refs `e1…`) |
| `browser.click` | `ref` (pos., obr.) |
| `browser.fill` | `ref` (pos., obr.), `text` (rest, obr.) |
| `browser.type` | `text` (rest, obr.) |
| `browser.key` | `key` (pos., obr.: `Enter`, `Tab`, `Escape`, `ArrowDown`…) |
| `browser.scroll` | `ref` ou `dy` (int) |
| `browser.eval` | `js` (rest, obr.) |
| `browser.text` | — |
| `browser.wait` | `text` ou `selector`, `timeout` (s, padrão 10, máx 120; spec timeout 120) |
| `browser.screenshot` | — → `{path}` PNG em `<root>/screens/<uuid>.png` (guarda as 50 mais recentes) |
| `browser.console` | `lines` (padrão 100, máx 500) |
| `browser.resize` | `width`, `height` (int, 320–4096) |
- **Comandos de painel** (core): `panel.open` (`plugin` pos. obr., `name`, `placement`, `url`, `storage`), `panel.close` (`name`), `panel.move` (`name`, `placement`), `panel.list`; `events` (`since` int, `panel`) — eventos recentes alcançáveis. MCP: nomes com `.` viram `_` (mecanismo do 1C).

- [ ] **Step 1: Write failing tests:**
  - `decodesV2WorkspaceWithoutPanels` (v2 → `panels == []`, regrava 3).
  - `panelEventsRoundTrip` (`"panel"`, `"panelRemoved"`, `"pluginEvent"`).
  - `canvasPanelReachableOnlyWithCord`, `dockPanelReachableByAll`, `resolvePanelWithoutNameNeedsSingleCandidate`.
  - `registryCommandsAppearInCommandsAndMCP`: `Commands.spec("browser.navigate") != nil`; `MCPSchema.tools()` contém `browser_navigate` com propriedade `panel`; nenhum nome de plug-in colide com o core.
  - `everyPluginCommandHasPanelParam`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(core): panels model and compiled plugin registry`.

---

### Task 2: Comandos de painel e cordas para painéis (daemon)

**Files:** Create `Sources/OrqDaemonKit/PanelCommands.swift`; Modify `CommandRouter.swift`, `MaestroCommands.swift`; Test `Tests/OrqDaemonKitTests/PanelCommandTests.swift`

**Interfaces:**
- Consumes: Task 1; reserva de nome, `cord/uncord`, `persist`, `hub.emit`, padrão de principal do `floor.*` (admin via `adminOnly` sem `terminalId`, ou token de terminal).
- **Regras:**

| Comando | Admin | Terminal |
|---|---|---|
| `panel.open` | sim | só Maestro. `placement` padrão do plugin. `canvas` → corda automática Maestro↔painel e `floorId` = andar do Maestro; doca → sem corda. `createdBy` = Maestro |
| `panel.close` | sim | só Maestro, painel `createdBy` == ele ou alcançável por corda |
| `panel.move` | sim | só Maestro criador |
| `panel.list` | todos | painéis alcançáveis (`reachablePanels`) |
| `events` | todos | eventos de painéis alcançáveis |

- Nome do painel: padrão `<plugin>-<n>` (menor n livre); colisão com terminal ou painel → `invalidArgs`. `plugin` desconhecido → `notFound`; `placement` fora de `PluginSpec.placements` → `invalidArgs`.
- `panel.open` com `url` grava `state["url"]`; `storage` grava `state["storage"]` (padrão `isolated`).
- `admin.connect`/`admin.disconnect` e o `connect`/`disconnect` do Maestro aceitam nomes de painel; corda terminal↔painel só faz sentido com painel no canvas (doca → `invalidArgs` "dock panels need no cord"); painel↔painel → `invalidArgs`. Regra do Maestro inalterada: as duas pontas precisam estar no alcance (para painel: `reachablePanels`).
- `panel.close`/`admin.kill` de painel: remove cordas, persiste, emite `.panelRemoved` (o host libera a webview e apaga o store isolado — Task 5).
- Eventos de plug-in: anel de **200** por painel no daemon; `events --since <seq>` devolve `{seq, panel, name, payload}` dos painéis alcançáveis, mais o `seq` atual.

- [ ] **Step 1: Write failing tests:** `maestroOpensCanvasPanelWithCord`, `dockPanelIsGlobal`, `canvasPanelNeedsCord` (via `panel.list`/`events` de um terminal sem corda), `nonMaestroCannotOpen`, `panelNameCollidesWithTerminal`, `placementMustBeAllowed`, `connectTerminalToCanvasPanel`, `dockPanelRefusesCord`, `closeRemovesCordsAndEmits`, `panelsSurviveRestart`, `eventsRingIsBoundedAndFiltered` (250 eventos → 200 guardados; terminal sem corda não vê evento de painel do canvas).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(daemon): panel commands and cords to canvas panels`.

---

### Task 3: Canal de host (`ui.host`) e roteamento de comandos de plug-in

**Files:** Create `Sources/OrqDaemonKit/PluginHost.swift`, `Sources/OrqClient/HostConnection.swift`; Modify `Sources/OrqCore/StreamFrames.swift`, `CommandRouter.swift`, `Sources/OrqProtocol/Commands.swift` (`ui.host`); Test `Tests/OrqDaemonKitTests/PluginHostTests.swift`

**Interfaces:**
```swift
// StreamFrame (novos): daemon → host
case call(id: String, panel: UUID, command: String, args: [String: JSONValue], timeoutSeconds: Double)
// host → daemon
case reply(id: String, result: JSONValue?, error: ProtocolError?)
case emit(panel: UUID, name: String, payload: JSONValue)   // vira .pluginEvent + anel de eventos
actor PluginHost {
  func attach(_ conn: StreamConn) async          // um host por vez; novo host substitui (antigo é fechado)
  func call(panel: Panel, command: String, args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue
}
public final class HostConnection: @unchecked Sendable {   // OrqClient
  public init(paths: Paths, token: () throws -> String,
              handler: @escaping @Sendable (_ panel: UUID, _ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue)
  public func start(); public func stop(); public func emit(panel: UUID, name: String, payload: JSONValue)
}
```
- `ui.host` é admin-only (ancestralidade incluída). O app abre ao conectar e reabre na reconexão (mesma política de backoff do `DaemonClient`).
- Router: comando cujo nome está em `PluginRegistry` → `resolvePanel` (admin: qualquer painel; terminal: alcance por corda/doca) → `PluginHost.call`. Sem host → `ProtocolError(.unavailable, "Orq app is not running")` **imediato**. Timeout = `CommandSpec.timeoutSeconds` (30 s; `browser.wait` 120 s) → `.timeout`; resposta tardia é descartada. Quem corta o resultado em 1 MiB é o host (Task 5, com `truncated: true`). O daemon é só a rede de segurança: `reply` maior que 1 MiB codificado → `ProtocolError(.internal, "plugin result exceeds 1 MiB")`.
- Host caiu com chamadas pendentes → todas falham com `.unavailable` na hora.
- Fila de chamadas pendentes limitada a **64** por host (excesso → `.unavailable` "host busy").

- [ ] **Step 1: Write failing tests** (host fake usando `HostConnection` num teste):
  - `callWithoutHostFailsFast` (< 1 s).
  - `callRoundTrip`: terminal com corda chama `browser.navigate --panel web https://x` → host recebe `(panelId, "browser.navigate", ["url": …])` → resposta chega ao terminal.
  - `hostTimeoutFreesCall`: host não responde, timeout de teste 1 s → `.timeout`; segunda chamada com host respondendo funciona.
  - `hostDropFailsPending`: host fecha com chamada pendente → `.unavailable` < 2 s.
  - `emitBecomesEvent`: `emit` vira `.pluginEvent` no `ui.events` e aparece em `events`.
  - `secondHostReplacesFirst`.
  - `terminalWithoutCordCannotCallCanvasPanel` (`.notConnected`) e `dockPanelCallableByAnyTerminal`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(daemon): ui.host channel and plugin command routing`.

---

### Task 4: App — docas, painéis no canvas e abrir painel

**Files:** Create `Sources/OrqApp/DockView.swift`, `PanelNodeView.swift`, `OpenPanelSheet.swift`; Modify `OrqApp.swift`, `CanvasViewport.swift`, `CordLayer.swift`, `Sources/OrqClient/DaemonClient.swift`, `Sources/OrqCanvas/Layout.swift`; Test `Tests/OrqClientTests/PanelClientTests.swift`

**Interfaces:**
- Consumes: Task 1–3. `DaemonClient`: `panels: [Panel]` (snapshot + eventos), `openPanel(plugin:name:placement:url:storage:)`, `closePanel(_:)`, `movePanel(_:to:)`; `HostConnection` iniciado/parado junto com a sessão.
- Protocolo de view de plug-in (o mesmo que um externo usaria): `@MainActor protocol PluginPanelView { init(panel: Panel, host: PanelHostContext); var view: NSView { get }; func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue; func close() }` e `@MainActor enum PluginViews { static func make(_ panel: Panel, …) -> PluginPanelView? }` (registro do lado do app, chave `pluginId`). O handler do `HostConnection` despacha para a instância viva do painel; painel sem instância (ex.: doca recolhida) → instância criada sob demanda.
- **Docas:** esquerda, direita e baixo, cada uma com abas dos painéis dela, redimensionáveis (`NSSplitView`), recolhidas quando vazias. Larguras/altura em UserDefaults.
- **Canvas:** painel com `placement == .canvas` vira nó (moldura em `layout.json` como os terminais; mesmo culling: fora da tela a view é **destacada mas não destruída** — webview continua viva só enquanto o painel existir). Filtragem por andar igual aos terminais.
- Menu do painel: Mover para ▸ (Doca esquerda/direita/baixo, Canvas), Fechar (confirmação; apaga dados se `isolated`).
- Cordas: arrastar de terminal até painel no canvas → `connect`.
- "Abrir painel…" (toolbar `plus.rectangle`): plugin, nome, posição, URL inicial, armazenamento (Isolado / Workspace / Global; padrão Isolado).
- Medidor (spec §6.3, **[call]** reduzido): na toolbar, RSS do app e contagem de painéis abertos por plug-in. RAM por webview não tem API pública (processo WebContent) → registrado como limitação.

- [ ] **Step 1: Write failing tests:** `appliesPanelEvents`, `visiblePanels(_:floor:)` (canvas filtrado por andar; doca sempre), `layoutKeepsPanelFrames`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual, checklist para o usuário):** abrir Navegador na doca direita e no canvas; mover entre doca e canvas; ligar corda; fechar painel.
- [ ] **Step 6:** Commit `feat(app): docks, canvas panel nodes and open-panel sheet`.

---

### Task 5: Plug-in Navegador

**Files:** Create `Sources/OrqPlugins/BrowserPanel.swift`, `BrowserAutomation.swift`, `BrowserCommands.swift`; Modify `Package.swift` (target `OrqPlugins` + `OrqPluginsTests`), `Sources/OrqApp/…` (registrar `browser` em `PluginViews`); Test `Tests/OrqPluginsTests/BrowserAutomationTests.swift`

**Interfaces:**
- Consumes: `PluginPanelView` (Task 4), comandos `browser.*` (Task 1), `HostConnection.emit` (Task 3).
- `@MainActor final class BrowserPanel: PluginPanelView` — `WKWebView` com `WKWebsiteDataStore`: `isolated` → `WKWebsiteDataStore(forIdentifier: panel.id)`; `workspace` → `forIdentifier: <UUID derivado do workspace id>`; `global` → `.default()`. `close()` desaloca a webview; ao **excluir** um painel `isolated`, `WKWebsiteDataStore.remove(forIdentifier:)`.
- `BrowserAutomation` (clean-room): um script de usuário injetado no início do documento que mantém `window.__orq` com: `snapshot(maxBytes)` (percorre o DOM visível; elementos interativos — `a, button, input, select, textarea, [role], [onclick], [contenteditable]` — recebem `data-orq-ref="eN"`; devolve linhas `- <role> "<nome acessível>" [ref=eN]` com indentação por profundidade, texto visível resumido), `click(ref)` (scrollIntoView + eventos de ponteiro/mouse + `click()`), `fill(ref, text)` (setter nativo de `value` + `input`/`change`), `type(text)` (no elemento focado), `key(name)` (`keydown`/`keypress`/`keyup` + ação padrão para Enter em formulário), `scroll(ref|dy)`, `text(maxBytes)`, `wait(text|selector, ms)` (MutationObserver + polling), e captura de `console.*`/erros num anel de **500** entradas devolvido por `browser.console` e emitido como evento `browser.console` (no máximo 10 por segundo).
- Ref inexistente → `notFound` "ref eN not found (take a new snapshot)". Resultados cortados em **1 MiB** (`truncated: true`).
- `browser.navigate` espera `didFinish` (ou erro de navegação → `invalidArgs` com a descrição) e emite `browser.loaded` `{url, title}`. **[call]** A URL atual fica só no host; o daemon guarda apenas a URL inicial (`state["url"]`), usada ao recriar a webview.
- `browser.screenshot`: `takeSnapshot` → PNG em `<root>/screens/<uuid>.png` (dir 0700), apaga além das 50 mais recentes; devolve `{path, width, height}`.
- `browser.resize`: muda o tamanho do conteúdo da webview (nó do canvas acompanha; na doca, só o viewport interno).
- `browser.eval`: resultado JSON-serializável ou `String(describing:)`; exceção JS → `invalidArgs` com a mensagem.

- [ ] **Step 1: Write failing tests** (WKWebView real com `loadHTMLString`, aguardando `didFinish`; `@MainActor`, `.serialized`):
  - `snapshotListsInteractiveElementsWithRefs` (botão, link, input aparecem com refs estáveis entre duas snapshots sem mudança de DOM).
  - `clickFiresHandler` (botão incrementa contador lido por `eval`).
  - `fillSetsValueAndFiresInput`.
  - `keyEnterSubmitsForm`.
  - `waitForTextAppears` (texto inserido após 300 ms por `setTimeout`).
  - `snapshotIsBounded` (página com 50 000 elementos → ≤ 1 MiB, `truncated == true`).
  - `consoleRingKeepsLast500`.
  - `unknownRefIsNotFound`.
  - `deletingPanelRemovesIsolatedStore` (grava `localStorage` num store isolado, exclui, `WKWebsiteDataStore.fetchAllDataStoreIdentifiers` não contém mais o id).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual, checklist):** Maestro: `orq panel open browser --placement canvas --url https://example.com` → nó aparece ligado ao Maestro; `orq browser snapshot`, `orq browser click e1`, `orq browser screenshot` → arquivo PNG; terminal sem corda → `notConnected`; fechar app → `orq browser text` dá "Orq app is not running".
- [ ] **Step 6:** Commit `feat(plugins): controllable browser panel`.

---

## Fora do 1D (registrado)
- Pré-visualização de artifacts no Navegador → plano de Artifacts (fase 2).
- Supervisor de processos auxiliares de plug-ins (§6.3) → quando o primeiro plug-in com processo existir (Design na fase 2, Dispositivos 1F).
- RAM por webview (sem API pública) → medidor reduzido (app RSS + contagem).
- Confiar em certificado autoassinado, user agent configurável, modo design de recorte → depois.
- Memória como plug-in de doca → **1E** (usa este sistema).

## Self-review (feito)
- **Spec §6.1:** painéis com posições doca/canvas e mover entre elas (T1, T2, T4); comandos com schema expostos via CLI e MCP automaticamente (T1); eventos para agentes e plug-ins (T2, T3). **§6.2:** regras de corda/doca (T1–T3); agentes abrem painéis — Maestro, sem confirmação, canvas já ligado a ele (T2). **§6.3:** fechar libera webview e dados (T4, T5); medidor reduzido (T4); supervisor fora (sem processo auxiliar no 1D). **§6.4:** Navegador usa o mesmo registro e o mesmo canal de um externo. **§7.4:** navegar, snapshot com refs, clicar, preencher, digitar, rolar, eval, screenshot, console, redimensionar, armazenamento por escopo com limpeza (T5).
- **Tipos:** `Panel`, `PanelPlacement`, `StorageScope`, `PluginSpec`, `PluginRegistry`, `PluginHost`, `HostConnection`, `PluginPanelView` iguais em T1–T5.
- **Proporção:** 5 tasks; UI validada por checklist manual; automação do Navegador testada com WKWebView real.
