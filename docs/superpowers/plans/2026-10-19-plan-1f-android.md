# Plano 1F — Dispositivos Android (+ editar terminal, menu do canvas) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Painel de dispositivo Android (emulador ou celular) com vídeo ao vivo e controle pelo mouse/teclado, comandos `orq device …` para agentes via adb, e — pedido do usuário em 2026-10-19 — editar um terminal depois de criado (inclusive virar/deixar de ser Maestro) e menu de botão direito no canvas.

**Architecture:** O motor de dispositivos roda **no daemon** (`DeviceService`, actor): comandos de agente executam `adb` (via `BoundedProcess`), vigias de longa duração (`LongProcess`) acompanham conexão e crashes, e uma `DeviceSession` por painel sobe o `scrcpy-server` (versão fixada, embutida no app) no aparelho e retransmite os pacotes H.264 para o app por um stream `ui.device` (mesmo canal JSON-lines dos outros `ui.*`). O app só exibe (`AVSampleBufferDisplayLayer`, que decodifica com VideoToolbox) e devolve toques/teclas como mensagens de controle do scrcpy. O protocolo do scrcpy (pacotes, mensagens de controle, mapa de teclas, árvore de UI, logs de crash) fica num módulo puro novo, `OrqDevice`, compartilhado por daemon e app. Plug-in `device` declara `runsInDaemon: true`: o router executa seus comandos no daemon em vez de mandá-los ao app.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, AVFoundation/CoreMedia/VideoToolbox (app), adb do Android platform-tools (do usuário), scrcpy-server **v3.3.1** (Apache-2.0, binário embutido). Nenhuma dependência Swift nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.6 (Android), §6 (plug-ins), §5 (cordas). Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: `main` em `881d27a` (1A–1E + correção do WebKit). Pedidos novos do usuário (2026-10-19, fora da spec): "editar um terminal que criei, podendo transformar em Maestro depois de criado" e "botão direito no Canvas → opções, criar terminal, etc.".

## Global Constraints

- macOS **15.0**, Swift 6.2, concorrência estrita. Nenhuma dependência Swift nova.
- Clean-room em relação ao Maestri. O scrcpy é outro projeto (Apache-2.0): reimplementamos o **protocolo** lendo a documentação/fonte da versão fixada, sem copiar código; o `scrcpy-server` vai embutido com `NOTICE` (Apache-2.0) em `Resources/`.
- **scrcpy-server v3.3.1** fixo: a string de versão passada ao servidor é exatamente `3.3.1`; trocar só deliberadamente (atualiza script + hash + testes de layout).
- Reusa o servidor adb existente (porta 5037); **nunca** `adb kill-server`. Conecta a dispositivos já rodando; iniciar AVD fica fora.
- adb é procurado em: `ORQ_ADB`, `$ANDROID_HOME/platform-tools/adb`, `$ANDROID_SDK_ROOT/platform-tools/adb`, `~/Library/Android/sdk/platform-tools/adb`, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb` (o daemon do launchd não tem PATH útil). Ausente → erro `unavailable` com a mensagem exata: `adb not found. Install Android platform-tools (brew install --cask android-platform-tools) or set ORQ_ADB.`
- **Corda é a única permissão** (decisão do usuário): comandos `device.*` com painel seguem `ConnectionGraph.resolvePanel` (canvas: só quem tem corda; doca: todos). `device.list` não tem painel e é liberado a qualquer terminal (só lista).
- Processos por painel encerrados ao fechar o painel (grupo de processos, TERM→KILL) e quando o app deixa de assistir por **5 s**; FPS limitado (`max_fps=30`, `max_size=1280`, `video_bit_rate=4000000`).
- Vídeo nunca derruba o stream por atraso do app: acima de **1 MiB** na fila de envio, pacotes não-chave são descartados até o próximo quadro-chave.
- Nada sai da máquina; nada é instalado no aparelho além do `scrcpy-server` em `/data/local/tmp/orq-scrcpy-server.jar` e dos APKs que um agente pedir explicitamente (`device.install`).
- `admin.update` (editar terminal) é **só admin** (app/usuário), recusado de terminais gerenciados como todo `admin.*`: agente nunca se promove a Maestro.
- Protocolo `v: 1` (só comandos/frames/eventos novos). Testes sem aparelho real: `Tests/Fixtures/fake-adb.sh` + servidor scrcpy falso em TCP local. Suítes com processos `.serialized`.

## Review Focus

1. **Nenhum aparelho / adb ausente / aparelho "unauthorized"** → `device.list` responde lista vazia ou com `state: "unauthorized"`; abrir painel sem `--serial` com 0 ou 2+ aparelhos dá erro dizendo quais existem; o painel mostra o estado em texto e o app não trava. Testes: Task 4 `listShowsUnauthorized`, `openWithoutSerialNeedsExactlyOne`, `missingAdbIsUnavailable`.
2. **Aparelho desconectado no meio do vídeo** (cabo puxado, emulador fechado) → o stream recebe `deviceStatus("ended", …)`, o daemon mata o processo e remove o `forward`; nada fica órfão. Teste: Task 6 `serverExitEndsSessionAndCleansUp`.
3. **App lento para consumir vídeo** → o daemon descarta P-frames, nunca corta o stream nem cresce memória. Teste: Task 6 `slowConsumerDropsUntilKeyframe`.
4. **Texto com espaço, aspas, `;`, `$(…)` ou acento em `device.text`** → espaço/aspas/símbolos chegam literais (escapados para o shell do aparelho); não-ASCII é recusado com mensagem clara, nunca executa nada no shell do aparelho. Teste: Task 3 `inputTextEscapesShell` + Task 4 `textRejectsNonASCII`.
5. **Renomear terminal para nome de painel/terminal existente, ou editar enquanto um ask está pendente** → recusado com `invalidArgs` (nome) / ask continua (keyed por id). Teste: Task 1 `renameRefusesTakenName`, `renameKeepsPendingAsk`.

---

## File Structure

```
Sources/OrqProtocol/Commands.swift          (+ admin.update, ui.device; panel.open --serial)
Sources/OrqProtocol/Plugins.swift           (+ PluginSpec.runsInDaemon, PluginRegistry.device)
Sources/OrqCore/StreamFrames.swift          (+ WorkspaceEvent.terminal, StreamFrame.video/.videoMeta/.deviceStatus)
Sources/OrqDaemonKit/CommandRouter.swift    (+ admin.update; relaunch() extraído de admin.restart; runsInDaemon → deviceCommand)
Sources/OrqDaemonKit/UnixSocket.swift       (+ Connection.queuedBytes)
Sources/OrqDevice/                          módulo puro novo
  ScrcpyProtocol.swift   leitura de codec meta/pacotes; codificação de mensagens de controle
  AndroidKeys.swift      nomes → keycodes Android; keyCode macOS → keycode Android
  UITree.swift           XML do uiautomator → nós com refs e linhas compactas
  AdbParsing.swift       `adb devices -l`, cabeçalho PNG, escape de `input text`
  CrashLog.swift         agrupa linhas do buffer de crash em eventos
  AnnexB.swift           NALs Annex-B → SPS/PPS e payload AVCC
Sources/OrqDaemonKit/Devices/Adb.swift          localizar + executar adb
Sources/OrqDaemonKit/Devices/LongProcess.swift  filho de longa duração (grupo, pidfile, linhas de stdout)
Sources/OrqDaemonKit/Devices/DeviceService.swift actor: comandos, vigias, sessões
Sources/OrqDaemonKit/Devices/DeviceSession.swift vídeo/controle de um painel
Sources/OrqDaemonKit/DeviceCommands.swift       device.* no router
Sources/OrqPlugins/DevicePanel.swift            painel (vídeo + input + barra Voltar/Início/Recentes)
Sources/OrqPlugins/PluginPanelView.swift        (+ PanelHostContext.openStream)
Sources/OrqApp/TerminalSheet.swift              (renomeia NewTerminalSheet: criar/editar)
Sources/OrqApp/CanvasViewport.swift, TerminalNodeView.swift, OrqApp.swift, OpenPanelSheet.swift
Sources/OrqClient/DaemonClient.swift            (+ update, openPanel → UUID, openStream, devices)
scripts/fetch-scrcpy-server.sh, scripts/bundle-app.sh, Resources/NOTICE-scrcpy
Tests/Fixtures/fake-adb.sh, Tests/Fixtures/h264/ (idr-64.h264, gerado uma vez com ffmpeg)
Tests/OrqDeviceTests/*, Tests/OrqDaemonKitTests/{TerminalUpdateTests,DeviceCommandTests,DeviceWatchTests,DeviceSessionTests}.swift,
Tests/OrqPluginsTests/DevicePanelTests.swift, Tests/OrqClientTests/TerminalUpdateClientTests.swift
```

`Package.swift`: alvo `OrqDevice` (sem dependências); `OrqDaemonKit` e `OrqPlugins` dependem dele; `testTarget OrqDeviceTests`.

---

### Task 1: `admin.update` — editar terminal (nome, Maestro, preset, comando, pasta)

**Files:** Modify `Sources/OrqProtocol/Commands.swift`, `Sources/OrqCore/StreamFrames.swift`, `Sources/OrqDaemonKit/CommandRouter.swift`, `Sources/OrqClient/DaemonClient.swift`; Test `Tests/OrqDaemonKitTests/TerminalUpdateTests.swift`, `Tests/OrqClientTests/TerminalUpdateClientTests.swift`

**Interfaces:**
- Produces: comando `admin.update` — params `name` (posicional, obrigatório: nome atual), `newName`, `maestro` (`"true"|"false"` ou bool), `preset`, `command`, `cwd`, `restart` (flag). Resultado `{"id", "name", "restartNeeded": Bool, "restarted": Bool}`.
- Produces: `WorkspaceEvent.terminal(TerminalRecord)` (upsert; tag `"terminal"`, chave `r`). `DaemonClient.apply` faz upsert como `.spawned`.
- Produces: `DaemonClient.update(_ name: String, newName: String?, maestro: Bool?, preset: Preset?, command: String?, cwd: String?, restart: Bool) async throws -> (restartNeeded: Bool, restarted: Bool)`.
- Produces: `CommandRouter.relaunch(_ t: TerminalRecord) async throws -> [String: JSONValue]` — corpo atual de `admin.restart` depois da checagem "already running" (piso/chão, `discard`, `launch`, `ensureFloor`); `admin.restart` passa a chamá-lo.

Regras: admin-only (mesmo `adminOnly`). `newName` passa por `reserve` (recusa nome de painel e lançamento em curso) e por `lookup` (recusa outro terminal com o nome, ignorando o próprio). Terminal de andar (`floorId != nil`) recusa `cwd` (`invalidArgs`: `"cwd of a floor terminal follows its floor"`). `preset == custom` exige `command` (o novo ou o já gravado). Persistir, emitir `.terminal(rec)`. `restartNeeded = running && (maestro|preset|command|cwd mudou)` (renomear não exige). Com `restart` e processo rodando → `relaunch` (mantém id e cordas); sem processo, `restart` também relança. Asks pendentes não são tocados (são por id).

- [ ] **Step 1: Testes que falham** (`TerminalUpdateTests`, `.serialized`, padrão de `MaestroTests`):
  - `promoteToMaestroTakesEffectImmediately`: terminal `a` (shell) sem Maestro → `recruit` por `a` falha com `.notMaestro`; `admin.update a --maestro true` → `restartNeeded == true`; `recruit` por `a` (token antigo) agora passa.
  - `demoteRemovesMaestroPowers`: inverso; `recruit` falha depois.
  - `renameRefusesTakenName`: `b` existe e painel `browser-1` existe → renomear `a` para `B` e para `browser-1` falham `.invalidArgs`; renomear `a` para `A` (mesmo terminal, caixa diferente) passa.
  - `renameKeepsPendingAsk`: `x` faz ask a `a` (fake-agent lento), `a` é renomeado para `c` durante o ask → resposta chega a `x` normalmente; `list` de `x` mostra `c`.
  - `updateFromManagedTerminalIsRefused`: chamada com token admin a partir de um filho de terminal gerenciado → `.unauthorized` (reaproveitar o helper do teste equivalente de `admin.spawn`).
  - `floorTerminalRefusesCwd`; `customNeedsCommand`.
  - `restartFlagRelaunchesInPlace`: `a` rodando; `update --preset custom --command "echo hi; sleep 30" --restart` → `restarted == true`, mesmo id, cordas de `a` intactas, novo pid ≠ antigo, scrollback mostra `hi`.
  - `updateEmitsTerminalEvent`: um `ui.events` recebe `.terminal` com o novo nome.
  - Cliente (`TerminalUpdateClientTests`): `apply(.terminal(r))` substitui o registro de mesmo id; `WorkspaceEvent.terminal` faz round-trip JSON.
- [ ] **Step 2:** `swift test --filter TerminalUpdate` → FAIL (comando desconhecido).
- [ ] **Step 3:** Implementar conforme Interfaces. `admin.update` no `switch` de `admin(_:)`.
- [ ] **Step 4:** `swift test --filter "TerminalUpdate|Maestro|Router"` → PASS.
- [ ] **Step 5:** Commit `feat(daemon): admin.update edits a terminal (name, maestro, launch settings)`.

### Task 2: App — editar terminal e menus de botão direito

**Files:** Rename `Sources/OrqApp/NewTerminalSheet.swift` → `Sources/OrqApp/TerminalSheet.swift`; Modify `Sources/OrqApp/{CanvasViewport,TerminalNodeView,OrqApp,OpenPanelSheet}.swift`, `Sources/OrqClient/DaemonClient.swift`; Test `Tests/OrqClientTests/TerminalUpdateClientTests.swift` (diff de edição), `Tests/OrqCanvasTests/CanvasStateTests.swift`

**Interfaces:**
- Consumes: `DaemonClient.update(...)` (Task 1).
- Produces: `struct TerminalSheet: View` com `enum Mode { case create(at: CGPoint?), edit(TerminalRecord) }`. Criar: igual ao sheet atual; se `at` (ponto do canvas) não é nil, depois do `spawn` grava `canvas.frames[id] = CGRect(origin: at, size: 640×400)`.
- Produces: `DaemonClient.openPanel(...)` passa a retornar `UUID` (id do painel do resultado) e ganha `serial: String? = nil` (usado na Task 7). `OpenPanelSheet(client:canvas:at:)`: com `at`, posição fixa em `.canvas` e frame do novo painel em `at` (tamanho padrão do PanelNodeView).
- Produces: `func editArgs(original: TerminalRecord, name: String, maestro: Bool, preset: Preset, command: String, cwd: String) -> (newName: String?, maestro: Bool?, preset: Preset?, command: String?, cwd: String?)` (internal, em `TerminalSheet.swift` ou `OrqClient`) — só o que mudou vai para o daemon.
- Produces: `CanvasState.defaultTerminalSize = CGSize(width: 640, height: 400)` (o `placeNew` passa a usá-lo).

UI:
- Modo editar: campos preenchidos; andar → mostra "Andar: x" sem pasta; aviso "Maestro, preset, comando e pasta valem depois de reiniciar" quando o terminal está rodando e algo desses mudou; botões **Salvar** e **Salvar e reiniciar** (este manda `restart: true`; com preset claude/codex mostra "A sessão do agente será reiniciada").
- `NodeTitleBar`: menu `…` ganha **Editar…** (primeiro item). O nó do terminal ganha o mesmo menu no botão direito (`menu(for:)` no NSView do título/borda; o terminal em si mantém o menu do SwiftTerm).
- Canvas vazio, botão direito (`CanvasViewport.menu(for:)`, só quando o clique não cai em nó): **Novo terminal aqui…**, **Abrir painel aqui…**, separador, **Ajustar à tela** (`fitAll`), **Zoom 100%**. O ponto vira coordenada do canvas (`canvas.toCanvas`). `CanvasView` recebe dois closures (`onNewTerminal(CGPoint)`, `onOpenPanel(CGPoint)`) e o `ContentView` apresenta os sheets.

- [ ] **Step 1: Testes que falham:** `editArgsSendsOnlyChanges` (só `maestro` mudou → só `maestro`; nome com espaços nas pontas é aparado e igual ao original → `newName` nil); `CanvasState` mantém `placeNew` com `defaultTerminalSize`.
- [ ] **Step 2:** `swift test --filter "TerminalUpdateClient|CanvasState"` → FAIL.
- [ ] **Step 3:** Implementar. `ContentView` guarda `@State var sheet: SheetKind?` (`.newTerminal(CGPoint?)`, `.edit(UUID)`, `.openPanel(CGPoint?)`) no lugar dos dois `Bool`; toolbar continua abrindo com `nil`.
- [ ] **Step 4:** `swift build` e `swift test --filter "OrqClientTests|OrqCanvasTests"` → PASS.
- [ ] **Step 5:** Commit `feat(app): edit terminals, canvas and node context menus`.

### Task 3: Módulo `OrqDevice` (protocolo scrcpy, teclas, árvore de UI, parsers)

**Files:** Create `Sources/OrqDevice/{ScrcpyProtocol,AndroidKeys,UITree,AdbParsing,CrashLog,AnnexB}.swift`, `Tests/OrqDeviceTests/*.swift`; Modify `Package.swift`

**Interfaces (todas `public`, puras, `Sendable`):**
```swift
public enum Scrcpy {
    public static let version = "3.3.1"
    public static let remoteJar = "/data/local/tmp/orq-scrcpy-server.jar"
    public struct CodecMeta: Equatable, Sendable { public var codec: UInt32; public var width: UInt32; public var height: UInt32 }  // 12 bytes BE
    public struct Packet: Equatable, Sendable { public var pts: UInt64; public var config: Bool; public var key: Bool; public var data: Data }
    /// Incremental: feed bytes, get whole packets (12-byte header: u64 pts_and_flags BE — bit63 config, bit62 key — then u32 len BE).
    public struct PacketReader: Sendable { public init(); public mutating func feed(_ d: Data) throws(ScrcpyError) -> [Packet] }
    public static func codecMeta(_ d: Data) -> CodecMeta?           // exatamente 12 bytes
    public enum Action: UInt8, Sendable { case down = 0, up = 1, move = 2 }
    public static func touch(_ a: Action, x: Int32, y: Int32, width: UInt16, height: UInt16, pointerId: UInt64 = .max) -> Data
    public static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, h: Float, v: Float) -> Data
    public static func key(_ a: Action, keycode: Int32, repeat: Int32 = 0, meta: Int32 = 0) -> Data
    public static func text(_ s: String) -> Data                      // UTF-8, corta em 300 bytes sem quebrar caractere
    public static func backOrScreenOn(_ a: Action) -> Data
    public static func resetVideo() -> Data
    public static func serverArgs(scid: String) -> [String]           // ver Step 3
}
public enum ScrcpyError: Error, Equatable { case packetTooLarge(Int) }  // > 16 MiB
public enum AndroidKeys {
    public static func keycode(named: String) -> Int32?   // "Enter"→66 "Back"→4 "Home"→3 "Tab"→61 "Escape"→111 "Backspace"→67 "Delete"→112
                                                          // "ArrowUp/Down/Left/Right"→19/20/21/22 "AppSwitch"→187 "Power"→26
                                                          // "VolumeUp/Down"→24/25 "Menu"→82; "KEYCODE_X" ou número passam direto; caixa ignorada
    public static func keycode(macKeyCode: UInt16) -> Int32?  // teclas especiais (Return, Tab, Delete, ForwardDelete, setas, Escape, Home, End, PageUp/Down)
}
public struct UINode: Equatable, Sendable { public var ref: String; public var cls: String; public var text: String; public var desc: String
    public var id: String; public var bounds: CGRect; public var clickable: Bool; public var depth: Int
    public var center: (x: Int, y: Int) { get } }
public enum UITree {
    /// Mantém nós com text, content-desc, resource-id ou clickable; refs e1, e2… em ordem de documento; no máximo `cap`.
    public static func parse(_ xml: Data, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool)
    public static func lines(_ nodes: [UINode]) -> String   // "  [e3] Button \"Entrar\" id=login_btn (540,1210) clickable" (2 espaços por depth; classe sem pacote)
}
public struct AdbDevice: Equatable, Sendable, Codable { public var serial: String; public var state: String; public var model: String?; public var product: String? }
public enum AdbParsing {
    public static func devices(_ out: String) -> [AdbDevice]   // `adb devices -l`; ignora cabeçalho e linhas "* daemon …"
    public static func pngSize(_ d: Data) -> (width: Int, height: Int)?
    public static func inputTextArg(_ s: String) throws(ProtocolError) -> String   // ver Step 3
}
public struct CrashEvent: Equatable, Sendable { public var package: String?; public var text: String }
public struct CrashLog: Sendable { public init(); public mutating func feed(line: String) -> [CrashEvent]; public mutating func flush() -> [CrashEvent] }
public enum AnnexB {
    public static func nalUnits(_ d: Data) -> [Data]                   // separa por 00 00 01 / 00 00 00 01, sem o prefixo
    public static func parameterSets(_ d: Data) -> (sps: Data, pps: Data)?   // NAL type 7 / 8 (primeiro de cada)
    public static func avcc(_ d: Data) -> Data                          // cada NAL com prefixo u32 BE de tamanho
}
```
(`OrqDevice` depende de `OrqProtocol` só para `ProtocolError`; ajustar `Package.swift` assim.)

- [ ] **Step 1: Verificar o protocolo na versão fixada.** Baixar o código da tag `v3.3.1` do scrcpy (só leitura, fora do repo, no scratchpad) e conferir: `server/src/main/java/com/genymobile/scrcpy/control/ControlMessageReader.java` (tipos e layouts), `app/src/control_msg.h` (números dos tipos, incluindo `RESET_VIDEO`), `doc/develop.md` (ordem dos sockets, byte dummy, codec meta, cabeçalho de pacote), `Options.java` (nomes dos parâmetros). Registrar no relatório os layouts conferidos. Layouts esperados (v3.x; corrigir se a fonte disser outra coisa e anotar): touch = tipo 2, action u8, pointerId u64, x i32, y i32, w u16, h u16, pressure u16 (0xFFFF solto=0 ao subir), actionButton u32, buttons u32 (32 bytes); scroll = tipo 3, x, y, w, h, hscroll i16, vscroll i16 (ponto fixo ±1→±0x7FFF, clamp ±16), buttons u32; key = tipo 0, action u8, keycode i32, repeat i32, meta i32 (14 bytes); text = tipo 1, len u32, bytes; back_or_screen_on = tipo 4, action u8; reset_video = tipo 17 (só o tipo). Inteiros big-endian. Mouse = pointerId `UInt64.max` (−1).
- [ ] **Step 2: Testes que falham** (`OrqDeviceTests`):
  - `packetReaderSplitsAcrossChunks`: dois pacotes (config 20 bytes, key 50 bytes) entregues em pedaços de 7 bytes → 2 pacotes com flags certas; `packetTooLargeThrows` para len 16 MiB + 1.
  - `codecMetaParses`: `68 32 36 34 | 00 00 04 38 | 00 00 09 60` → h264, 1080×2400.
  - `touchLayout`, `scrollLayout`, `keyLayout`, `textLayout`, `resetVideoLayout`: bytes exatos (golden) conforme Step 1; `textTruncatesOnCharacterBoundary` (299 bytes ASCII + "é" → 299 bytes).
  - `keyNames`: tabela acima, `"keycode_enter"`→66, `"66"`→66, `"Nope"`→nil.
  - `uiTreeCompacts`: fixture XML curto (FrameLayout > LinearLayout > Button text="Entrar" resource-id="app:id/login_btn" bounds="[400,1180][680,1240]" clickable="true", TextView vazio não-clicável descartado) → um nó `e1`, centro (540,1210), linha `[e1] Button "Entrar" id=login_btn (540,1210) clickable`; `uiTreeCaps` com cap 3 → `truncated`.
  - `devicesParses`: saída com `emulator-5554 device product:sdk_gphone64 model:sdk_gphone64_arm64 …`, `R58M unauthorized usb:1-1 transport_id:3`, linha `* daemon started successfully` → 2 aparelhos, estados certos.
  - `pngSizeReadsIHDR`; `inputTextEscapesShell`: `a b` → `'a%sb'`; `it's $(rm -rf /)` → `'it'\''s%s$(rm%s-rf%s/)'`; `"%s"` literal → `'\%s'`; não-ASCII (`"ação"`) → `.invalidArgs` "device.text supports ASCII only; use device.key or the panel for other characters".
  - `crashLogGroupsJavaCrash`: linhas `E/AndroidRuntime( 123): FATAL EXCEPTION: main`, `… Process: com.foo, PID: 123`, `… java.lang.IllegalStateException: boom` → 1 evento no `flush()` (ou ao chegar a próxima `FATAL EXCEPTION`), `package == "com.foo"`, `text` com as 3 linhas (≤ 4096 bytes); `crashLogNativeCrash`: `F/libc ( 456): Fatal signal 11 (SIGSEGV) … pid 456 (com.bar)` → package `com.bar`.
  - `annexBSplitsAndConverts`: `00 00 00 01 67 AA 00 00 01 68 BB 00 00 01 65 CC` → 3 NALs; `parameterSets` → (67 AA, 68 BB); `avcc` → `00 00 00 02 67 AA 00 00 00 02 68 BB 00 00 00 02 65 CC`.
- [ ] **Step 3: Implementar.** `serverArgs(scid:)` = `["CLASSPATH=\(remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", version, "scid=\(scid)", "log_level=info", "tunnel_forward=true", "audio=false", "control=true", "cleanup=true", "video_codec=h264", "max_size=1280", "max_fps=30", "video_bit_rate=4000000", "send_device_meta=false", "send_dummy_byte=true", "send_codec_meta=true", "send_frame_meta=true", "clipboard_autosync=false"]` (conferir nomes no Step 1). `inputTextArg`: só ASCII imprimível; aspas simples com `'` → `'\''`; espaço → `%s`; `%s` literal pré-existente → `\%s`.
- [ ] **Step 4:** `swift test --filter OrqDeviceTests` → PASS.
- [ ] **Step 5:** Commit `feat(device): scrcpy protocol, key map, ui tree and adb parsers`.

### Task 4: Plug-in `device` no daemon — adb e comandos de agente

**Files:** Create `Sources/OrqDaemonKit/Devices/{Adb,DeviceService}.swift`, `Sources/OrqDaemonKit/DeviceCommands.swift`, `Tests/Fixtures/fake-adb.sh`, `Tests/Fixtures/ui-dump.xml`, `Tests/Fixtures/screen.png` (PNG 4×8), `Tests/OrqDaemonKitTests/DeviceCommandTests.swift`; Modify `Sources/OrqProtocol/{Plugins,Commands}.swift`, `Sources/OrqDaemonKit/{CommandRouter,PluginHost,PanelCommands,Daemon}.swift`

**Interfaces:**
- Produces: `PluginSpec.runsInDaemon: Bool` (init com default `false`). `PluginRegistry.device` (id `device`, título `Dispositivo`, placements `[.canvas, .dockRight, .dockLeft, .dockBottom]`, default `.canvas`, `runsInDaemon: true`, eventos `["device.connected", "device.disconnected", "device.crash", "device.app_launched"]`). Comandos (todos ganham `--panel` automático; `device.list` o ignora):
  - `device.list` — aparelhos `[{serial,state,model,product,panels:[nome]}]` (timeout 15)
  - `device.screenshot` → `{path,width,height}` em `<root>/screens/<panelId>-<epochMs>.png` (30)
  - `device.ui` → `{tree: String, truncated: Bool}`; guarda os nós do painel para `--ref` (30)
  - `device.tap` `x` `y` posicionais opcionais ou `--ref eN` (15)
  - `device.swipe` `x1 y1 x2 y2` posicionais + `--ms` (1…10000, padrão 300) (20)
  - `device.text` `text` (`.rest`) (15) · `device.key` `key` (15)
  - `device.logcat` `--lines` (1…2000, padrão 200) `--grep` (substring, sem regex) (20)
  - `device.install` `path` posicional (relativo ao `cwd` do chamador; precisa existir e terminar em `.apk`) (300)
  - `device.launch` `package` posicional + `--activity` (30) → evento `device.app_launched {serial, package}`
- Produces: `panel.open … --serial S` (param novo); para `device`: `state["serial"]` = S, ou o único aparelho em estado `device`; 0 ou 2+ → `invalidArgs` "No device online" / "Several devices online (a, b); pass --serial".
- Produces: `struct Adb { let url: URL; static func locate(env: [String: String], home: String) -> URL?; func run(_ args: [String], serial: String?, timeout: Duration, cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult }` (não-zero → `.internal` com stderr cortado em 500 chars; `exec-out` usa `cap` 32 MiB para PNG). `DaemonConfig.adbPath: URL?` (testes apontam para o fake) — nil = `Adb.locate`.
- Produces: `actor DeviceService { init(root: URL, adb: @escaping @Sendable () -> URL?, emit: @escaping @Sendable (UUID, String, JSONValue) async -> Void); func run(_ command: String, panel: Panel?, args: [String: JSONValue], cwd: String?) async throws(ProtocolError) -> JSONValue; func resolveSerial(_ s: String?) async throws(ProtocolError) -> String; func panelClosed(_ id: UUID) async; func stop() async }` — `nonisolated let devices` no `CommandRouter`.
- Router: em `handle`, `if let (plugin, spec) = PluginRegistry.command(...)` → `plugin.runsInDaemon ? deviceCommand(...) : pluginCommand(...)`. `deviceCommand`: `principal` como `pluginCommand`; `device.list` sem painel; demais via `resolvePanel` (corda); serial do `panel.state["serial"]`; aparelho fora do ar → `.notFound` "Device S is offline". `remove(_ p: Panel)` chama `devices.panelClosed(p.id)` (apaga screenshots `screens/<id>-*`, refs, sessões). `Daemon.stop` → `devices.stop()`.

Comandos adb (o fake reconhece exatamente estes): `devices -l`; `-s S exec-out screencap -p`; `-s S shell uiautomator dump /sdcard/orq-ui.xml` seguido de `-s S exec-out cat /sdcard/orq-ui.xml`; `-s S shell input tap X Y`; `-s S shell input swipe X1 Y1 X2 Y2 MS`; `-s S shell input text ARG`; `-s S shell input keyevent K`; `-s S logcat -d -t N`; `-s S install -r PATH`; `-s S shell monkey -p PKG -c android.intent.category.LAUNCHER 1` ou `-s S shell am start -n PKG/ACT`.

`fake-adb.sh`: registra cada invocação (uma linha, args separados por `\t`) em `$ORQ_FAKE_ADB_LOG`; `devices -l` imprime `$ORQ_FAKE_ADB_DEVICES` (arquivo); screencap → `cat $ORQ_FAKE_ADB_PNG`; `cat /sdcard/orq-ui.xml` → `cat $ORQ_FAKE_ADB_UI`; `logcat -d` → linhas de `$ORQ_FAKE_ADB_LOGCAT`; `install` → `Success`; `monkey` → `Events injected: 1`; o resto sai 0. (Tasks 5/6 acrescentam ramos.)

- [ ] **Step 1: Testes que falham** (`DeviceCommandTests`, `.serialized`; daemon de teste com `adbPath` = fake):
  - `listShowsUnauthorized`; `missingAdbIsUnavailable` (`adbPath` inexistente e locate nil → mensagem exata das Global Constraints).
  - `openWithoutSerialNeedsExactlyOne` (0, 1, 2 aparelhos online); `openWithUnknownSerialFails`.
  - `canvasDeviceNeedsCord`: Maestro abre painel no canvas (corda automática); terminal `w` sem corda → `device.tap 1 1 --panel device-1` = `.notConnected`; depois de `admin.connect w device-1` → passa. `dockDeviceReachableByAll`.
  - `screenshotWritesPngWithSize` (arquivo existe sob `screens/`, `width 4 height 8`); `uiReturnsTreeAndTapByRef` (`device.ui` → contém `[e1]`; `device.tap --ref e1` → log com `input tap 540 1210`; `--ref e9` → `.notFound` "Unknown ref e9; run device.ui first").
  - `swipeKeyTextLogcat`: args exatos no log (`keyevent 66` para `Enter`; texto escapado; `logcat -d -t 50`; `--grep boom` filtra linhas).
  - `textRejectsNonASCII`; `installResolvesRelativeToCallerCwd` (e recusa `.txt` e caminho inexistente).
  - `launchEmitsAppLaunched`: `events` do Maestro mostra `device.app_launched` com `package`.
  - `closingPanelDeletesScreenshots`.
- [ ] **Step 2:** `swift test --filter DeviceCommandTests` → FAIL.
- [ ] **Step 3:** Implementar. Coordenadas `tap`/`swipe`: inteiros 0…100000 (`invalidArgs` fora disso).
- [ ] **Step 4:** `swift test --filter "DeviceCommand|PanelCommand|PluginHost|Commands"` → PASS (MCP lista as tools `device_*`; `CommandsTests` atualizado se contar tools).
- [ ] **Step 5:** Commit `feat(device): device plugin with adb agent commands`.

### Task 5: Vigias — conexão, crashes e processos de longa duração

**Files:** Create `Sources/OrqDaemonKit/Devices/LongProcess.swift`, `Tests/OrqDaemonKitTests/DeviceWatchTests.swift`; Modify `Sources/OrqDaemonKit/Devices/DeviceService.swift`, `Sources/OrqDaemonKit/Daemon.swift`, `Tests/Fixtures/fake-adb.sh`

**Interfaces:**
- Produces: `final class LongProcess: Sendable { init(executable: URL, args: [String], env: [String: String], runDir: URL, onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws(ProtocolError); var pid: pid_t { get }; func terminate() }` — `posix_spawn` com `SETPGROUP` (como `BoundedProcess`), stdin `/dev/null`, stdout em linhas (linha > 64 KiB é cortada), stderr descartado; pidfile via `OrphanReaper.record(pid:terminal:in:)` com um UUID próprio (o daemon reiniciado mata o grupo órfão); `terminate()` = TERM no grupo, KILL após 1 s, idempotente, remove o pidfile; pid entra em `BoundedProcess`'s conjunto vivo (expor `BoundedProcess.track/untrack`) para `adminOnly` recusar descendentes.
- Produces em `DeviceService`: `func watch(panels: [Panel]) async` — chamado pelo router depois de abrir/fechar painel `device` e no início do daemon com os painéis carregados. Enquanto houver ≥ 1 painel `device`: um laço lê `adb devices -l` a cada **2 s** (intervalo injetável `pollInterval`) e, na transição de um serial para `device`/fora, emite `device.connected` / `device.disconnected` `{serial}` para cada painel ligado a ele. Para cada serial online com painel: um `LongProcess` `adb -s S logcat -b crash -v brief -T <epoch>.000` (epoch de `adb -s S shell date +%s` no início do vigia) alimentando `CrashLog`; cada `CrashEvent` → `device.crash {serial, package, text}` (flush 300 ms depois da última linha). Vigia que cai é reiniciado com espera 2 s→30 s enquanto o aparelho estiver online; parado quando o último painel do serial fecha ou no `stop()`.

`fake-adb.sh`: `shell date +%s` → `1700000000`; `logcat -b crash …` → imprime `$ORQ_FAKE_ADB_CRASH` (se definido) e fica em `sleep 600` (precisa morrer com o grupo); grava `$$` em `$ORQ_FAKE_ADB_PIDS`.

- [ ] **Step 1: Testes que falham** (`DeviceWatchTests`, `.serialized`, `pollInterval` 0,2 s):
  - `connectAndDisconnectEvents`: arquivo de aparelhos alterna vazio → `emulator-5554 device` → vazio; `events` tem `device.connected` e depois `device.disconnected`.
  - `crashLogBecomesEvent`: `$ORQ_FAKE_ADB_CRASH` com um crash Java → `device.crash` com `package == "com.foo"`; o logcat foi chamado com `-T 1700000000.000`.
  - `closingLastPanelKillsWatchers`: pids do fake gravados; depois de `panel.close`, todos mortos em ≤ 3 s; sem pidfile em `run/terminals`.
  - `daemonStopKillsWatchers`; `watcherDescendantIsRefusedAdmin` (`adminOnly` recusa o pid do logcat).
  - `restartedDaemonReapsOrphanWatcher` (padrão de `OrphanTests`: pidfile + grupo vivo → morto no `start`).
- [ ] **Step 2:** `swift test --filter DeviceWatchTests` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `swift test --filter "DeviceWatch|DeviceCommand|Orphan"` → PASS.
- [ ] **Step 5:** Commit `feat(device): connection and crash watchers`.

### Task 6: Sessão de vídeo/controle e stream `ui.device`

**Files:** Create `Sources/OrqDaemonKit/Devices/DeviceSession.swift`, `scripts/fetch-scrcpy-server.sh`, `Resources/NOTICE-scrcpy`, `Tests/OrqDaemonKitTests/DeviceSessionTests.swift`; Modify `Sources/OrqCore/StreamFrames.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqDaemonKit/{UnixSocket,CommandRouter,Daemon}.swift`, `Sources/OrqDaemonKit/Devices/DeviceService.swift`, `Sources/orqd/main.swift`, `scripts/bundle-app.sh`, `Tests/Fixtures/fake-adb.sh`, `.gitignore`

**Interfaces:**
- Produces frames (`StreamFrame`, daemon → app): `.videoMeta(width: UInt32, height: UInt32)` (tag `videoMeta`), `.video(Data, pts: UInt64, config: Bool, key: Bool)` (tag `video`, `d` base64), `.deviceStatus(state: String, message: String?)` (tag `deviceStatus`; estados `connecting`, `streaming`, `ended`, `error`). App → daemon: `.in(Data)` = mensagens de controle scrcpy já codificadas, escritas como vieram no socket de controle (o app é admin).
- Produces: comando `ui.device` (param `panel` = id, admin, stream; `exposedToMCP: false`). `CommandRouter.stream` → `devices.attach(panel:conn:ok:)`; painel inexistente ou de outro plug-in → `notFound`.
- Produces: `UnixSocketServer.Connection.queuedBytes: Int` (bytes não enviados).
- Produces: `DaemonConfig.scrcpyServer: URL?`; `orqd/main.swift` resolve `ORQ_SCRCPY_SERVER` ou `<dir do orqd>/../Resources/scrcpy-server` (existente). Sem arquivo → status `error` "scrcpy-server is not bundled (run scripts/fetch-scrcpy-server.sh and rebuild)".
- `DeviceSession` (uma por painel, dentro do `DeviceService`): ao primeiro inscrito: `deviceStatus(connecting)`; `adb -s S push <jar> <remoteJar>`; `scid` = 8 hex aleatórios (31 bits); `adb -s S forward tcp:0 localabstract:scrcpy_<scid>` → porta (stdout); `LongProcess` `adb -s S shell <Scrcpy.serverArgs(scid:)>`; conectar em `127.0.0.1:porta` com nova tentativa a cada 100 ms por até **5 s**, cada tentativa só vale se ler o byte dummy; depois o socket de vídeo lê 12 bytes de codec meta (h264 = `0x68323634`, outro → `error`); conectar o socket de controle (sem dummy); `videoMeta`, `deviceStatus(streaming)`; leitura do vídeo numa thread própria → `PacketReader` → envio a cada inscrito com a regra: config sempre; se `queuedBytes > 1 MiB` → descarta e marca `waitKey` (manda `Scrcpy.resetVideo()` no controle uma vez); com `waitKey`, descarta não-chave; chave limpa `waitKey`. Leitura do socket de controle é descartada (clipboard/acks). Fim (EOF, erro, processo saiu): `deviceStatus(ended|error, motivo)`, `terminate()` do processo, `adb -s S forward --remove tcp:<porta>`, fecha sockets. Último inscrito saiu → fecha depois de **5 s** (cancelado se alguém entrar). `panelClosed`/`stop` fecham na hora. Sem reconexão automática (o painel tem "Reconectar").
- `scripts/fetch-scrcpy-server.sh`: baixa `https://github.com/Genymobile/scrcpy/releases/download/v3.3.1/scrcpy-server-v3.3.1` para `vendor/scrcpy-server` (git-ignored), confere SHA-256 fixo no script (calcular na primeira execução e gravar no script — registrar no relatório) e falha se divergir. `bundle-app.sh` copia `vendor/scrcpy-server` e `Resources/NOTICE-scrcpy` para `Contents/Resources/` (aviso, não erro, se faltar o jar).

`fake-adb.sh`: `forward tcp:0 …` → imprime `$ORQ_FAKE_ADB_PORT`; `forward --remove …` só registra; `shell CLASSPATH=…` → grava `$$` em `$ORQ_FAKE_ADB_PIDS` e `exec sleep 600`; `push` registra.

- [ ] **Step 1: Testes que falham** (`DeviceSessionTests`, `.serialized`; servidor scrcpy falso: `NWListener`/socket BSD em 127.0.0.1 porta 0 passada no env; 1ª conexão: dummy `00`, codec meta 64×64, pacote config, pacote key, 3 P; 2ª conexão: guarda bytes recebidos):
  - `streamDeliversMetaConfigAndKey`: cliente `ui.device` (StreamClient) recebe `deviceStatus(connecting)`, `videoMeta(64,64)`, `deviceStatus(streaming)`, `video(config)`, `video(key)`, 3 `video`; o log do fake tem `push`, `forward tcp:0 localabstract:scrcpy_<8 hex>` e `shell CLASSPATH=/data/local/tmp/orq-scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 3.3.1 …`.
  - `inputReachesControlSocket`: cliente manda `.in(Scrcpy.key(.down, keycode: 66))` → servidor falso recebe exatamente esses bytes.
  - `slowConsumerDropsUntilKeyframe`: servidor manda 40 MiB de P-frames de 256 KiB sem o cliente ler; depois o cliente lê: stream não foi cortado (sem `.overflow`), `queuedBytes` máximo observado < 1,5 MiB + 1 pacote, controle recebeu `resetVideo` uma vez, o primeiro `video` lido depois do descarte é `key`.
  - `serverExitEndsSessionAndCleansUp`: servidor fecha o socket de vídeo → `deviceStatus(ended)`; pid do `shell` morto; log tem `forward --remove tcp:<porta>`.
  - `lastViewerLeavingStopsAfterGrace` (grace injetável 0,3 s) e `reattachWithinGraceKeepsSession` (mesmo pid).
  - `panelCloseStopsSessionNow`; `missingJarReportsError`; `connectTimeoutReportsError` (porta sem servidor → `error` em ≤ 6 s, processo morto).
  - Frames novos: round-trip JSON de `videoMeta`, `video`, `deviceStatus`.
- [ ] **Step 2:** `swift test --filter DeviceSessionTests` → FAIL.
- [ ] **Step 3:** Implementar. Rodar `scripts/fetch-scrcpy-server.sh` uma vez (rede) e gravar o hash.
- [ ] **Step 4:** `swift test --filter "DeviceSession|DeviceWatch|DeviceCommand|Stream|UnixSocket"` → PASS; `scripts/bundle-app.sh` → `Contents/Resources/scrcpy-server` presente.
- [ ] **Step 5:** Commit `feat(device): scrcpy video/control session over ui.device`.

### Task 7: App — painel do dispositivo, abrir painel com aparelho, docs

**Files:** Create `Sources/OrqPlugins/DevicePanel.swift`, `Tests/OrqPluginsTests/DevicePanelTests.swift`, `Tests/Fixtures/h264/idr-64.h264`; Modify `Sources/OrqPlugins/PluginPanelView.swift`, `Sources/OrqClient/DaemonClient.swift`, `Sources/OrqApp/{OrqApp,OpenPanelSheet}.swift`, `Package.swift` (resources do teste, se preciso), `README.md`, `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`

**Interfaces:**
- Consumes: frames da Task 6; `OrqDevice` (Task 3); `openPanel(..., serial:)` (Task 2).
- Produces: `PanelHostContext.openStream: @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> StreamClient` (init com default que lança `unavailable`, para não quebrar chamadas existentes); `DaemonClient.openAdminStream(_:_:)` implementa (token admin, `StreamClient.open`).
- Produces: `final class DevicePanel: PluginPanelView` registrado como `"device"`; `handle` → `unavailable` ("device commands run in the daemon").
- Produces (testáveis, `internal`): `struct VideoFormat { static func description(sps: Data, pps: Data) -> CMVideoFormatDescription? ; static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: UInt64) -> CMSampleBuffer? }` (com `kCMSampleAttachmentKey_DisplayImmediately`); `func videoRect(view: CGSize, video: CGSize) -> CGRect` (aspect-fit centralizado); `func devicePoint(_ p: CGPoint, view: CGSize, video: CGSize) -> (x: Int32, y: Int32)?` (nil fora do vídeo; coordenadas em pixels do vídeo).

Comportamento: a view (fundo preto) tem `AVSampleBufferDisplayLayer` (`resizeAspect`), um rótulo de estado ("Conectando…", "Aparelho desconectado", erro) com botão **Reconectar**, e uma barra fina com **Voltar** (`backOrScreenOn` down/up), **Início** (keycode 3) e **Recentes** (187). Stream aberto em `viewDidMoveToWindow` com janela e fechado sem janela (o daemon encerra depois de 5 s) e em `close()`. Leitura numa thread própria (padrão `DaemonClient.frames`); `video(config)` → `AnnexB.parameterSets` → novo format; outros → `AnnexB.avcc` → `enqueue` na main; layer com `status == .failed` → `flush()` e espera a próxima chave. Mouse: down/drag/up → `Scrcpy.touch` (pointer do mouse) com tamanho do vídeo; scroll → `Scrcpy.scroll` (delta / 10); teclado com o painel em foco: `AndroidKeys.keycode(macKeyCode:)` → `key` down/up; caracteres imprimíveis → `Scrcpy.text`. Envio `.in(...)` serializado numa fila.
`OpenPanelSheet`: plug-in `device` → `Picker` de aparelhos (`adminCall("device.list")`, só `state == device`, botão "Atualizar"), sem URL/armazenamento; URL só para `browser`.

- [ ] **Step 1: Gerar fixture** (uma vez, ffmpeg local): `ffmpeg -f lavfi -i testsrc=size=64x64:rate=1 -frames:v 1 -c:v libx264 -profile:v baseline -bsf:v h264_mp4toannexb -f h264 Tests/Fixtures/h264/idr-64.h264` (registrar o comando no teste).
- [ ] **Step 2: Testes que falham** (`DevicePanelTests`):
  - `formatFromFixture`: `AnnexB.parameterSets` do fixture → `VideoFormat.description` com dimensões 64×64.
  - `decodesFixtureFrame`: IDR do fixture → `sampleBuffer` → `VTDecompressionSession` decodifica um `CVPixelBuffer` 64×64 (prova o caminho até o VideoToolbox).
  - `letterboxMapping`: view 400×400, vídeo 1080×2400 → rect `x≈110 w≈180`; ponto no centro → (540,1200); ponto em x=10 → nil.
  - `panelRegistersAndRefusesCommands`: `PluginViews.make` para painel `device` com `openStream` falso não lança; `handle("device.tap", …)` → `.unavailable`.
- [ ] **Step 3:** `swift test --filter DevicePanelTests` → FAIL; implementar; → PASS.
- [ ] **Step 4:** Suíte inteira `swift test` → PASS; `scripts/bundle-app.sh` ok.
- [ ] **Step 5:** README: seção "Dispositivos Android" (instalar platform-tools, depuração USB/emulador, `scripts/fetch-scrcpy-server.sh` antes do bundle, `orq device …`, limitações). Roteiro: linha 1F aponta este plano. Commit `feat(app): device panel with live video and input`.

---

## Limitações conhecidas (aceitas neste plano)

- Sem áudio, sem iniciar AVD, sem gravação de vídeo; iOS fica no 1G.
- `device.text` só ASCII (o `input text` do Android); acentos pelo painel (teclado → mensagem de texto do scrcpy).
- ANR não vira evento (não está no buffer de crash).
- Editar Maestro/preset/comando/pasta de um terminal rodando só vale por completo depois de reiniciar (o daemon já aplica a permissão de Maestro na hora; a lista de tools MCP do agente só muda no próximo lançamento).
