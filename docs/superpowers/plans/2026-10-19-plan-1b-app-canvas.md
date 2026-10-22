# Plano 1B — App shell, canvas e terminais — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um app macOS (`Orq.app`) com canvas infinito onde cada nó é um terminal ao vivo do daemon `orqd`, ligados por cordas que definem quem conversa com quem, sobrevivendo a reinícios do app e do daemon.

**Architecture:** O daemon (plano 1A) continua dono dos PTYs. Ganha uma **conexão de fluxo** no mesmo socket (frames JSON por linha) para a UI anexar a um terminal (saída ao vivo + entrada + resize) e para receber eventos do workspace. O app é um cliente: `DaemonClient` (reconexão), `CanvasState` (geometria pura, testável), viewport AppKit hospedando nós SwiftUI, nó de terminal com SwiftTerm. Layout do canvas é do app (`layout.json`), separado do `workspace.json` do daemon.

**Tech Stack:** Swift 6.2, SwiftPM, SwiftUI + AppKit, **SwiftTerm** (MIT; primeira dependência externa, permitida pelo spec §3/§5), Swift Testing, launchd (LaunchAgent).

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (§4, §5, §6.3, §10). Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: código do plano 1A em `main` (656138e). Referência de UX: a análise de referência (local, não publicada) §3.1–3.2.

## Global Constraints

- macOS deployment target **15.0**; Swift tools 6.2; language mode Swift 6 (strict concurrency).
- Única dependência nova permitida: **SwiftTerm** (versão fixada por `exact:` no Package.swift).
- Nomes: app `Orq`, bundle id `dev.orq.app`, LaunchAgent label `dev.orq.daemon`; nada com prefixo `maestri`. Clean-room: não copiar código/textos/ícones do Maestri.
- **Cordas são a única permissão, inclusive para o Maestro** (decisão do usuário 2026-10-19).
- Protocolo versionado (`v: 1`), erros tipados, nunca truncar em silêncio.
- Anti-metas: RAM limitada (buffers com teto), terminais fora da tela não renderizam, nada pesado na main thread, falhas dão erro claro e rápido; app ou daemon caindo não pode travar o outro.
- O app autentica no daemon com o **admin token** (lido de `admin.token`); o app nunca é descendente de um terminal, então passa no filtro de ancestralidade do 1A.

## Review Focus

1. **Daemon reinicia com o app aberto** → app mostra "desconectado", reconecta com backoff (≤ 5 s após o socket voltar), reanexa nós; terminais mortos pelo reinício aparecem "parados" com ação *Reiniciar*. Teste: Task 3 `clientReconnectsAfterDaemonRestart` + Task 2 `restartKillsOrphanGroups`.
2. **Rajada de saída (MBs) com UI lenta** → fila de envio do fluxo com teto (**4 MiB**); estourou → daemon envia `{"t":"overflow"}` e fecha; cliente reanexa com replay do buffer. RAM do daemon não cresce. Teste: Task 1 `slowReaderIsCutNotBuffered`.
3. **20 terminais no canvas, maioria fora da tela** → nós fora do viewport (+ margem 200 pt) desanexam a view do SwiftTerm (fluxo pausado); voltar à tela reanexa com replay. Teste: Task 4 `visibleNodesCullsOffscreen` + Task 6 `offscreenNodeDetachesStream`.
4. **Fechar nó / matar terminal** → view, fluxo e frames liberados (sem vazamento). Teste: Task 6 `closingNodeReleasesStream`.
5. **Redimensionar nó** → PTY recebe novo tamanho (`stty size` reflete), com debounce de 100 ms. Teste: Task 1 `resizeFrameReachesPty`.

---

## File Structure

```
Package.swift                                   (+ SwiftTerm, + targets OrqClient, OrqCanvas, OrqApp)
Sources/OrqProtocol/StreamFrames.swift          frames do fluxo (UI ⇄ daemon)
Sources/OrqProtocol/Commands.swift              (+ admin.disconnect, admin.restart)
Sources/OrqDaemonKit/StreamHub.swift            conexões de fluxo, fila com teto, eventos
Sources/OrqDaemonKit/UnixSocket.swift           (+ modo fluxo após primeira linha)
Sources/OrqDaemonKit/OrphanReaper.swift         pidfiles + kill de grupos órfãos no boot
Sources/OrqDaemonKit/AttentionDetector.swift    padrões "precisa de atenção" por preset
Sources/OrqClient/DaemonClient.swift            cliente async + reconexão + eventos
Sources/OrqClient/TerminalStream.swift          anexar/escrever/resize/replay
Sources/OrqClient/DaemonLauncher.swift          LaunchAgent install/bootstrap
Sources/OrqCanvas/CanvasState.swift             geometria pura (@Observable)
Sources/OrqCanvas/Layout.swift                  layout.json (frames por terminal)
Sources/OrqApp/OrqApp.swift                     @main, janela, toolbar
Sources/OrqApp/CanvasViewport.swift             NSView: pan/zoom/minimap, hospeda nós
Sources/OrqApp/TerminalNodeView.swift           SwiftTerm ⇄ TerminalStream
Sources/OrqApp/CordLayer.swift                  desenho/arraste de cordas
Sources/OrqApp/NewTerminalSheet.swift           presets, nome, pasta, Maestro
scripts/bundle-app.sh                           monta Orq.app (orqd + orq + app)
Tests/OrqDaemonKitTests/StreamTests.swift, OrphanTests.swift, AttentionTests.swift
Tests/OrqClientTests/…   Tests/OrqCanvasTests/…
```

---

### Task 1: Conexão de fluxo no daemon (attach + eventos)

**Files:** Create `Sources/OrqProtocol/StreamFrames.swift`, `Sources/OrqDaemonKit/StreamHub.swift`; Modify `UnixSocket.swift`, `CommandRouter.swift`, `AskCoordinator`/`TerminalRegistry` (ganchos de saída/eventos); Test `Tests/OrqDaemonKitTests/StreamTests.swift`

**Interfaces:**
- Produces:
```swift
public enum StreamFrame: Codable, Sendable, Equatable {        // uma linha JSON por frame, chave "t"
  case out(Data)                 // {"t":"out","d":"<base64>"}       daemon → UI
  case replay(Data, truncated: Bool)  // primeiro frame após attach: buffer em memória atual
  case `in`(Data)                // UI → daemon (teclado)
  case resize(cols: UInt16, rows: UInt16)
  case event(WorkspaceEvent)     // daemon → UI (no fluxo de eventos)
  case exited(code: Int32)
  case overflow                  // daemon cortou por fila cheia; cliente deve reanexar
}
public enum WorkspaceEvent: Codable, Sendable, Equatable {
  case spawned(TerminalRecord), exited(UUID, Int32), removed(UUID),
       connected(Connection), disconnected(Connection),
       attention(UUID, reason: String), status(UUID, StatusBadge)
}
public enum StatusBadge: String, Codable, Sendable { case idle, working, attention, stopped }
```
- Abertura: o cliente envia a **primeira linha** como `Request` normal com `command: "ui.attach"` (args `{terminal: <uuid>}`) ou `"ui.events"`, autenticada com **admin token**; se ok, o servidor responde uma linha `Response(ok:true)` e a conexão vira fluxo de `StreamFrame` nos dois sentidos (não fecha). Requisições não-`ui.*` seguem o comportamento atual (responde e fecha).
- `StreamHub` (actor no daemon): registra fluxos por terminal e de eventos; recebe saída do PTY via `onOutput`; cada fluxo tem fila de envio com teto **4 MiB** → excedeu: envia `.overflow` e fecha; nunca bloqueia o PTY nem o actor.
- `badge`: `working` enquanto há ask em voo para o terminal ou saída nos últimos 2 s; `attention` ver Task 7; `idle` caso contrário; `stopped` se não roda. Emitido só em mudanças.

- [ ] **Step 1: Write failing tests:**
  - `attachReplaysThenStreams`: terminal `sh` imprime `hello`; attach → primeiro frame `.replay` contém `hello`; enviar `.in("echo x\r")` → próximos `.out` contêm `x`.
  - `resizeFrameReachesPty`: `.resize(cols: 100, rows: 30)` e depois `.in("stty size\r")` → saída contém `30 100`.
  - `eventsStreamReportsLifecycle`: assinar `ui.events`; `admin.spawn` B, `admin.connect A B`, `admin.kill B` → recebe `.spawned`, `.connected`, `.removed` nessa ordem.
  - `slowReaderIsCutNotBuffered`: anexar e não ler; terminal imprime 20 MiB → cliente recebe `.overflow` ao voltar a ler; footprint do daemon (via `Daemon` interno) não cresce > 8 MiB.
  - `attachRequiresAdminToken`: token de terminal → `.unauthorized`.
  - `exitedFrameOnProcessExit`: terminal `sh -c "exit 3"` → `.exited(code: 3)`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS (full `swift test` 2×).
- [ ] **Step 5:** Commit `feat(daemon): streaming attach and workspace events for the UI`.

---

### Task 2: Reinício do daemon — matar órfãos, pidfiles, `admin.restart`, `admin.disconnect`

**Files:** Create `Sources/OrqDaemonKit/OrphanReaper.swift`; Modify `CommandRouter.swift`, `Commands.swift`, `Daemon.swift`; Test `Tests/OrqDaemonKitTests/OrphanTests.swift`

**Interfaces:**
- Produces:
```swift
enum OrphanReaper {
  static func record(pid: pid_t, terminal: UUID, in runDir: URL) throws   // run/terminals/<id>.pid (pgid = pid por SETSID)
  static func forget(terminal: UUID, in runDir: URL)
  static func reapAll(in runDir: URL) -> Int   // SIGHUP no grupo, 2 s, SIGKILL; remove pidfiles; retorna nº de grupos mortos
}
```
- Decisão (**[call]**): adoção é impossível (o master do PTY morre com o daemon), então no boot o daemon **mata** grupos órfãos dos pidfiles antes de servir; registros ficam como `stopped`.
- `admin.restart <name>`: relança um registro parado com o mesmo id/cordas (reusa o "respawn in place" do 1A). `admin.disconnect <a> <b>`: remove a corda, idempotente; emite `.disconnected`.

- [ ] **Step 1: Write failing tests:**
  - `restartKillsOrphanGroups`: daemon real (binário), spawn `custom` `trap '' HUP; sleep 300`, SIGKILL no daemon, confirmar filho vivo; reiniciar daemon → filho morre em ≤ 3 s; `list` mostra o registro como não-rodando.
  - `pidfileRemovedOnNormalExit`: terminal sai → pidfile some.
  - `restartRelaunchesStoppedRecordKeepingCords`: A–B ligados, kill do processo B (não do registro), `admin.restart B` → B roda com mesmo id, `list` de A contém B.
  - `disconnectIsIdempotent`.
- [ ] **Step 2–4:** RED → GREEN. **Step 5:** Commit `feat(daemon): reap orphaned terminals on start; restart and disconnect`.

---

### Task 3: `OrqClient` — cliente do daemon com reconexão

**Files:** Create `Sources/OrqClient/DaemonClient.swift`, `TerminalStream.swift`; Test `Tests/OrqClientTests/DaemonClientTests.swift`

**Interfaces:**
- Consumes: `StreamFrame`, `WorkspaceEvent`, `Request/Response`, `Paths`.
- Produces:
```swift
public enum ConnectionState: Sendable, Equatable { case connected, disconnected(reason: String) }
@MainActor @Observable public final class DaemonClient {
  public init(paths: Paths = Paths())
  public private(set) var state: ConnectionState
  public private(set) var terminals: [TerminalRecord]       // espelho via eventos + list inicial
  public private(set) var connections: [Connection]
  public private(set) var badges: [UUID: StatusBadge]
  public func start()                                        // conecta, assina ui.events, reconecta com backoff 0.25→2 s
  public func spawn(name: String, preset: Preset, command: String?, cwd: String, maestro: Bool) async throws -> UUID
  public func connect(_ a: String, _ b: String) async throws
  public func disconnect(_ a: String, _ b: String) async throws
  public func kill(_ name: String) async throws
  public func restart(_ name: String) async throws
  public func attach(_ id: UUID) -> TerminalStream
}
public final class TerminalStream: Sendable {
  public var frames: AsyncStream<StreamFrame> { get }        // .replay primeiro; reanexa sozinho após .overflow/queda
  public func send(_ bytes: Data)
  public func resize(cols: UInt16, rows: UInt16)              // debounce 100 ms
  public func close()
}
```
- Snapshot inicial: o daemon precisa de `ui.snapshot` (admin) → `{terminals, connections, badges}`; adicionar no router (mesma task).
- Nenhum I/O de socket na main thread; o estado publicado é atualizado no MainActor.

- [ ] **Step 1: Write failing tests** (daemon real em processo filho, raiz curta `/tmp/orq-…`):
  - `clientMirrorsWorkspace`: `start()`, `spawn` A e B, `connect` → `terminals.count == 2`, `connections.count == 1` em ≤ 2 s.
  - `clientReconnectsAfterDaemonRestart`: SIGKILL no daemon → `state` vira `.disconnected` em ≤ 2 s; reiniciar daemon → `.connected` em ≤ 5 s e `terminals` repovoado (A parado).
  - `streamReattachesAfterOverflow`: forçar overflow (cliente pausado) → `frames` emite novo `.replay` e continua.
- [ ] **Step 2–4:** RED → GREEN. **Step 5:** Commit `feat(client): daemon client with reconnect and terminal streams`.

---

### Task 4: `OrqCanvas` — geometria do canvas e layout

**Files:** Create `Sources/OrqCanvas/CanvasState.swift`, `Layout.swift`; Test `Tests/OrqCanvasTests/CanvasStateTests.swift`

**Interfaces:**
- Produces:
```swift
@MainActor @Observable public final class CanvasState {
  public var offset: CGPoint; public var zoom: CGFloat          // zoom ∈ [0.25, 2.0]
  public var frames: [UUID: CGRect]                              // em coordenadas do canvas
  public var selection: Set<UUID>
  public func toScreen(_ p: CGPoint) -> CGPoint; public func toCanvas(_ p: CGPoint) -> CGPoint
  public func zoom(by factor: CGFloat, around screenPoint: CGPoint)   // ponto sob o cursor fica fixo
  public func pan(by screenDelta: CGSize)
  public func visibleNodes(viewport: CGSize, margin: CGFloat = 200) -> Set<UUID>
  public func placeNew(size: CGSize = .init(width: 640, height: 400), viewport: CGSize) -> CGRect   // centro visível, sem sobrepor (desloca 32 pt)
  public func fitAll(viewport: CGSize)
}
public struct LayoutFile: Codable { public var schemaVersion = 1; public var offset: CGPoint; public var zoom: CGFloat; public var frames: [UUID: CGRect] }
public enum LayoutStore { public static func load(_ url: URL) -> LayoutFile?; public static func save(_ f: LayoutFile, to url: URL) throws }   // <root>/workspaces/<id>/layout.json, escrita atômica, debounce 500 ms no chamador
```
- [ ] **Step 1: Write failing tests:**
  - `zoomKeepsCursorPointFixed`: `toCanvas(p)` antes == depois de `zoom(by: 1.5, around: p)`.
  - `zoomIsClamped`: zoom 10× → 2.0; 0.01× → 0.25.
  - `visibleNodesCullsOffscreen`: nó a 5000 pt fora → não visível; nó a 150 pt da borda → visível (margem).
  - `placeNewAvoidsOverlap`: 3 `placeNew` seguidos → 3 retângulos sem interseção.
  - `layoutRoundTrips`.
- [ ] **Step 2–4:** RED → GREEN. **Step 5:** Commit `feat(canvas): pure canvas geometry and layout persistence`.

---

### Task 5: App shell, empacotamento e LaunchAgent

**Files:** Modify `Package.swift` (+ `.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "<última release estável — fixar>")`, target executável `OrqApp`); Create `Sources/OrqApp/OrqApp.swift`, `Sources/OrqClient/DaemonLauncher.swift`, `scripts/bundle-app.sh`, `Resources/Info.plist`; Test `Tests/OrqClientTests/DaemonLauncherTests.swift`

**Interfaces:**
- Produces:
```swift
public enum DaemonLauncher {
  public static func plist(orqdPath: String, root: URL) -> Data          // Label dev.orq.daemon, ProgramArguments [orqd, --root, root], KeepAlive true, RunAtLoad true, StandardErrorPath ~/Library/Logs/Orq/orqd.log
  public static func ensureRunning(orqdPath: String, root: URL) throws   // escreve ~/Library/LaunchAgents/dev.orq.daemon.plist só se mudou; launchctl bootstrap gui/<uid> (ou kickstart se já carregado)
}
```
- `bundle-app.sh`: `swift build -c release`, monta `build/Orq.app/Contents/{MacOS/{Orq,orqd,orq},Info.plist}`, assinatura ad-hoc (`codesign -s -`), hardened runtime. Info.plist: `CFBundleIdentifier dev.orq.app`, `LSMinimumSystemVersion 15.0`.
- App: ao abrir, `DaemonLauncher.ensureRunning` (usando o `orqd` de dentro do bundle; em `swift run`, o de `.build`) e `DaemonClient.start()`; janela única com toolbar (Novo terminal, Ajustar à tela, zoom %) e indicador de conexão.
- **[call]** LaunchAgent em vez de processo filho: daemon sobrevive a crash/quit do app (spec §4); o app avisa no primeiro uso ("O Orq instalará um serviço em segundo plano") e há item de menu *Parar serviço*.

- [ ] **Step 1: Write failing tests:** `plistHasKeepAliveAndRoot` (decodifica o plist e checa chaves/valores acima); `ensureRunningIsIdempotent` usando um diretório de LaunchAgents injetável e um `launchctl` falso (closure injetável) — não tocar o launchd real em teste.
- [ ] **Step 2–4:** RED → GREEN. `scripts/bundle-app.sh` roda e gera `build/Orq.app` (verificar `codesign -v`).
- [ ] **Step 5 (manual):** abrir `build/Orq.app`; confirmar janela, indicador "conectado", `launchctl print gui/$UID/dev.orq.daemon` ativo. Registrar no PR.
- [ ] **Step 6:** Commit `feat(app): app shell, bundle script and launchd-managed daemon`.

---

### Task 6: Viewport do canvas e nó de terminal

**Files:** Create `Sources/OrqApp/CanvasViewport.swift`, `TerminalNodeView.swift`; Test `Tests/OrqClientTests/NodeLifecycleTests.swift` (lógica de ciclo de vida isolada da view)

**Interfaces:**
- Consumes: `CanvasState`, `DaemonClient.attach`, `TerminalStream`.
- Produces: `NodeController` (testável, sem AppKit): `init(id:, client:)`, `setVisible(_:)` (visível → `attach`; invisível → `close()` do stream), `close()`, `var streamOpen: Bool`.
- Viewport (NSView): pan com dois dedos/scroll e espaço+arrastar; pinça e ⌘+/⌘−/⌘0 para zoom; minimap no canto (clique navega); nós SwiftUI em `NSHostingView` posicionados por `CanvasState.toScreen`; nós fora de `visibleNodes` não têm view de terminal montada.
- Nó: barra de título (nome, preset, badge, menu: Reiniciar, Matar, Fechar nó), corpo = SwiftTerm `TerminalView` alimentado por `frames` e enviando teclado por `send`; redimensionar o nó → `resize` (cols/rows calculados pela métrica da fonte).

- [ ] **Step 1: Write failing tests:** `offscreenNodeDetachesStream` (`setVisible(false)` → `streamOpen == false`; `true` → reabre e primeiro frame é `.replay`); `closingNodeReleasesStream` (após `close()`, referência fraca ao stream fica nil).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual, checklist no PR):** 20 terminais `shell` criados; pan/zoom fluidos; nós fora da tela sem atualizar; digitar em um nó funciona; redimensionar reflete em `stty size`; matar daemon (`launchctl kickstart -k`) → nós mostram "desconectado" e voltam.
- [ ] **Step 6:** Commit `feat(app): canvas viewport and live terminal nodes`.

---

### Task 7: Cordas, novo terminal e "precisa de atenção"

**Files:** Create `Sources/OrqApp/CordLayer.swift`, `NewTerminalSheet.swift`, `Sources/OrqDaemonKit/AttentionDetector.swift`; Test `Tests/OrqDaemonKitTests/AttentionTests.swift`

**Interfaces:**
- Produces:
```swift
struct AttentionDetector {             // daemon, alimentado pela saída sem ANSI de cada terminal
  init(preset: Preset)
  mutating func feed(_ text: String) -> String?   // retorna o motivo ao detectar
}
```
- Padrões (**[call]**, lista curta, só em inglês, case-insensitive): `claude` → `"do you trust the files in this folder"`, `"trust this folder"`; todos → `"(y/n)"`, `"[y/n]"`, `"press enter to continue"`. Detectou → evento `.attention(id, reason)` + badge `attention`; qualquer entrada do usuário (`.in`) ou novo ask limpa o badge.
- Cordas: arrastar da alça do nó A até o nó B → `client.connect`; corda = curva Bézier entre centros das bordas; clique na corda seleciona, ⌫ → `disconnect`. Nada de física de corda nesta fase (**[call]**, YAGNI).
- Novo terminal: folha com nome, preset (shell/claude/codex/custom + comando), pasta (NSOpenPanel), toggle Maestro; lembra últimos valores (UserDefaults). Ao criar com preset `claude` em pasta nova, a folha avisa: "O Claude Code pode pedir para confiar nesta pasta — o nó vai indicar 'precisa de atenção'."
- App: badge `attention` dispara notificação do macOS (UserNotifications; pede permissão uma vez) com o motivo e foca o nó ao clicar.

- [ ] **Step 1: Write failing tests:** `detectsClaudeTrustPrompt` (texto real do prompt, com ANSI removido, partido em dois `feed`), `detectsGenericYesNo`, `noFalsePositiveOnNormalOutput` (100 linhas de log comum → nil), `inputClearsAttentionBadge` (daemon: detecção → evento; `.in` → badge `idle`).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual):** criar Claude em pasta não confiável → badge + notificação; responder no nó → badge some. Ligar dois terminais por corda e verificar `orq list` em cada um.
- [ ] **Step 6:** Commit `feat(app): cords, new-terminal sheet and attention badges`.

---

## Fora do 1B (registrado)
- Credencial de Maestro para comandos administrativos (recruit/connect) → **1C**.
- Física de corda, grupos, minimapa avançado, temas → depois.
- Sistema de plug-ins e docas → **1D** (o viewport deixa espaço para docas, mas não as implementa).

## Self-review (feito)
- **Spec:** canvas/terminais/cordas/presets (§5) T4–T7; app e daemon separados que sobrevivem um ao outro (§4) T1–T3, T5; terminais fora da tela não renderizam e RAM com teto (§10) T1, T4, T6; cordas como única permissão (decisão 2026-10-19) T7 via `admin.connect`; pendências herdadas do 1A: reinício do daemon T2, aviso de confiança do Claude T7; credencial do Maestro movida para 1C.
- **Tipos:** `StreamFrame`, `WorkspaceEvent`, `StatusBadge`, `TerminalStream`, `DaemonClient`, `CanvasState` com os mesmos nomes em T1–T7.
- **Proporção:** 7 tasks; UI validada por checklist manual onde teste automatizado de AppKit não compensa.
