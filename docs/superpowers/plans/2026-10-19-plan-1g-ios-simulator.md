# Plano 1G — Simulador iOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O plug-in `device` passa a cobrir o Simulador iOS: painel com vídeo ao vivo e controle por mouse/teclado, e os mesmos comandos `orq device …` dos agentes (tela, árvore de UI, toque, gesto, texto, tecla, logs, instalar, abrir app), com eventos de conexão e crash.

**Architecture:** Mesmo desenho do 1F: tudo de dispositivo roda **no daemon**. Painel `device` ganha `state["platform"]` (`android` | `ios`); `DeviceService` despacha por plataforma — Android continua via adb/scrcpy; iOS via `xcrun simctl` (lista, boot, screenshot, logs, instalar, abrir app) e **AXe** (toque, gesto, texto, teclas, botões, árvore de UI e **vídeo** via `axe stream-video --format mjpeg`, decisão do usuário em 2026-10-19). Uma `SimSession` por painel relaya quadros JPEG pelo mesmo stream `ui.device`; o app mostra o JPEG e devolve gestos como `SimInput` (JSON) que o daemon executa com o AXe.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, Xcode 26 (`xcrun simctl`), **AXe v1.8.0** (MIT, CLI externo instalado pelo usuário; usa frameworks privados do simulador, isolados nele). Nenhuma dependência Swift nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.6 (Simulador iOS), §6, §5. Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: `main` em `d893e6a` (1A–1F). Referência de código: plug-in Android do 1F (`OrqDevice`, `Devices/DeviceService.swift`, `Devices/DeviceSession.swift`, `Sources/OrqPlugins/DevicePanel.swift`).

**Desvio da spec (decisão do usuário, 2026-10-19):** a spec pedia vídeo via ScreenCaptureKit da janela do Simulator.app. O usuário escolheu `axe stream-video`: sem permissão de Gravação de Tela, sem exigir janela visível, sem recorte de moldura, e compatível com o Xcode 27 (que dispensa o Simulator.app). Custo aceito: frameworks privados (dentro do AXe, versão fixada).

## Global Constraints

- macOS **15.0**, Swift 6.2, concorrência estrita. Nenhuma dependência Swift nova. **iPhone físico fora.**
- **AXe v1.8.0** é a versão testada (mínima aceita). AXe é procurado em: `ORQ_AXE`, `/opt/homebrew/bin/axe`, `/usr/local/bin/axe`. Ausente → `unavailable` com a mensagem exata: `AXe not found. Install it with brew install cameroncooke/axe/axe or set ORQ_AXE.` AXe é instalado pelo usuário (não embutido no app).
- `xcrun` em `/usr/bin/xcrun` (injetável nos testes). Sem Xcode → `unavailable`: `xcrun simctl not available. Install Xcode and run xcode-select --switch.`
- Plug-in único `device` (não um plug-in novo): mesmos nomes de comando para Android e iOS; o painel guarda `state["platform"]` (`"android"` quando ausente — painéis do 1F continuam funcionando).
- Coordenadas: Android em **pixels** do aparelho (1F); iOS em **pontos** lógicos (o que o AXe e o `describe-ui` usam). A ajuda dos comandos diz isso.
- **Corda é a única permissão** (decisão do usuário): mesma regra do 1F (`resolvePanel`; `device.list` sem painel, liberado).
- Vídeo: `axe stream-video --format mjpeg --fps 15 --quality 70 --scale 0.5 --udid <UDID>`; acima de **1 MiB** na fila de envio o quadro é descartado (todo JPEG é independente: nada de esperar quadro-chave). Processo encerrado ao fechar o painel e **5 s** depois do último espectador (mesma regra do 1F).
- Entrada do app → daemon em fila serial por sessão, no máximo **32** comandos pendentes (excesso é descartado, nunca acumula).
- Nada de I/O bloqueante no pool cooperativo; processos longos via `LongProcess` (grupo, pidfile, TERM→KILL).
- Protocolo `v: 1` (só frames/campos novos). Testes sem simulador real: `Tests/Fixtures/fake-xcrun.sh` + `Tests/Fixtures/fake-axe.sh`, suítes aninhadas na suíte `.serialized` `DeviceCommandTests` (o fake é configurado por `setenv`, como no 1F).

## Review Focus

1. **Simulador desligado ou nenhum ligado** → `device.list` mostra os iOS com `state: "shutdown"`; abrir painel num desligado faz `simctl boot` e espera ficar pronto (≤ 120 s); com nenhum UDID e 0 ou 2+ ligados, erro dizendo quais existem. Testes: Task 2 `openShutdownSimulatorBootsIt`, `openWithoutSerialAmongSimulators`.
2. **Simulador desligado no meio do vídeo** (usuário fecha, `simctl shutdown`) → `deviceStatus("ended")`, processo do AXe morto, nada órfão; `device.disconnected` emitido. Testes: Task 4 `streamExitEndsSession`, Task 3 `bootedToShutdownEmitsDisconnected`.
3. **Texto não digitável em US keyboard** (acento, emoji) em `device.text` iOS → recusado com mensagem clara; texto com `;`, `$(…)`, aspas chega literal (AXe recebe argv, sem shell). Testes: Task 1 `simTextValidation`, Task 2 `iosTextPassesLiterally`.
4. **App arrastando/rolando rápido** → entradas além de 32 pendentes são descartadas; o vídeo continua; nada cresce sem limite. Teste: Task 4 `inputBacklogIsBounded`.
5. **Comando sem equivalente no iOS** (`device.key Back`, `device.launch --activity`, instalar `.apk`) → erro `invalidArgs` explicando a diferença, nunca um comando errado no simulador. Teste: Task 2 `iosRejectsAndroidOnlyArgs`.

---

## File Structure

```
Sources/OrqDevice/SimCtl.swift          `simctl list devices -j` → [SimDevice]
Sources/OrqDevice/AXeTree.swift         JSON do `axe describe-ui` → [UINode] (reusa UINode/UITree.lines)
Sources/OrqDevice/MJPEG.swift           leitor incremental de quadros JPEG
Sources/OrqDevice/SimInput.swift        enum Codable de entrada (tap, swipe, text, key, button) + validação de texto
Sources/OrqDevice/IOSKeys.swift         nomes → HID usage; keyCode do macOS → HID usage
Sources/OrqDevice/IPSCrash.swift        relatório .ips → CrashEvent do simulador
Sources/OrqDaemonKit/Devices/Simulator.swift        localizar xcrun/AXe e executar
Sources/OrqDaemonKit/Devices/DeviceService+Android.swift   (extraído do DeviceService: comandos adb)
Sources/OrqDaemonKit/Devices/DeviceService+iOS.swift       comandos simctl/AXe
Sources/OrqDaemonKit/Devices/SimSession.swift      vídeo MJPEG + entrada de um painel iOS
Sources/OrqDaemonKit/Devices/DeviceService.swift   (despacho por plataforma, sessões, vigias)
Sources/OrqDaemonKit/Devices/LongProcess.swift     (+ modo binário: onData)
Sources/OrqCore/StreamFrames.swift                 (+ StreamFrame.jpeg)
Sources/OrqProtocol/Plugins.swift                  (ajuda dos comandos cita iOS)
Sources/OrqPlugins/DevicePanel.swift               (modo iOS: imagem JPEG, gestos → SimInput, barra Início/Bloquear)
Sources/OrqApp/OpenPanelSheet.swift                (lista simuladores)
Tests/Fixtures/{fake-xcrun.sh,fake-axe.sh}, Tests/Fixtures/ios/{devices.json,describe-ui.json,stream.mjpeg,crash.ips}
Tests/OrqDeviceTests/*, Tests/OrqDaemonKitTests/{SimCommandTests,SimWatchTests,SimSessionTests}.swift, Tests/OrqPluginsTests/DevicePanelTests.swift
README.md (seção Simulador iOS), docs/superpowers/plans/2026-10-18-phase1-roadmap.md
```

---

### Task 1: `OrqDevice` para iOS (simctl, árvore do AXe, MJPEG, entrada, teclas, crash)

**Files:** Create `Sources/OrqDevice/{SimCtl,AXeTree,MJPEG,SimInput,IOSKeys,IPSCrash}.swift`, `Tests/OrqDeviceTests/SimTests.swift`, fixtures em `Tests/Fixtures/ios/`

**Interfaces (public, puras, Sendable):**
```swift
public struct SimDevice: Equatable, Sendable, Codable { public var udid: String; public var name: String; public var state: String; public var runtime: String }   // state cru do simctl em minúsculas: "booted", "shutdown", ...
public enum SimCtl { public static func devices(_ json: Data) -> [SimDevice] }   // só isAvailable == true; runtime "iOS 26.3" derivado da chave
public enum AXeTree {
    /// Mesma regra de corte e refs do UITree (e1…, cap 2000); bounds em pontos; cls = tipo do elemento.
    public static func parse(_ json: Data, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool, screen: CGSize?)   // screen = frame do elemento raiz
}
public struct MJPEGReader: Sendable { public init(); public mutating func feed(_ d: Data) -> [Data] }   // quadros SOI(FFD8)…EOI(FFD9); lixo entre quadros ignorado; quadro > 8 MiB descartado
public enum SimInput: Codable, Equatable, Sendable {
    case tap(x: Double, y: Double), swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double),
         text(String), key(UInt8), button(String)   // button ∈ home, lock
}
public enum SimText { public static func validate(_ s: String) throws(ProtocolError) }   // ASCII imprimível + \n; senão invalidArgs
public enum IOSKeys {
    public static func usage(named: String) -> UInt8?        // Enter 40, Escape 41, Backspace 42, Tab 43, Space 44, ArrowRight 79, ArrowLeft 80, ArrowDown 81, ArrowUp 82, número 0–255 passa direto; caixa ignorada
    public static func button(named: String) -> String?     // Home → "home", Lock/Power → "lock"
    public static func usage(macKeyCode: UInt16) -> UInt8?  // Return, Tab, Delete, Escape, setas, ForwardDelete(76)
}
public enum IPSCrash { public static func parse(_ ips: Data, udid: String) -> CrashEvent? }   // bug_type 309 e procPath contém "/Devices/<udid>/"; package = bundleID (ou procName)
```

- [ ] **Step 1: Capturar fixtures reais (somente leitura).** Baixar `AXe-macOS-v1.8.0-universal.tar.gz` (release `v1.8.0` de `cameroncooke/AXe`) para o scratchpad, sem instalar no sistema; com o simulador já ligado da máquina, rodar só comandos de leitura: `axe --help` e `--help` de `tap`, `swipe`, `type`, `key`, `button`, `describe-ui`, `stream-video`, `list-simulators` (conferir flags; registrar no relatório); `axe describe-ui --udid <UDID>` → `Tests/Fixtures/ios/describe-ui.json` (reduzir a ≤ 40 elementos mantendo a forma); `axe stream-video --format mjpeg --fps 15 --quality 70 --scale 0.5 --udid <UDID>` por ~1 s → `stream.mjpeg` (≤ 3 quadros, cortar o resto); `xcrun simctl list devices -j` → `devices.json` (anonimizar nada é preciso). Montar `crash.ips` sintético no formato `.ips` (linha 1 JSON cabeçalho com `bug_type: "309"`, depois JSON do corpo com `procPath` `/Users/x/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Bundle/Application/…/Foo.app/Foo` e `bundleInfo.CFBundleIdentifier`). Se uma flag do AXe divergir deste plano, seguir o AXe e anotar.
- [ ] **Step 2: Testes que falham** (`SimTests`):
  - `simctlParsesDevices`: fixture → contém o iPhone ligado com `state == "booted"`, `runtime` começando com `"iOS "`; indisponíveis ficam fora.
  - `axeTreeCompacts`: fixture → refs `e1…`, um botão com label conhecido da fixture, centro em pontos, `screen` igual ao frame raiz; `UITree.lines` funciona com esses nós; `axeTreeCaps` (cap 3 → truncated).
  - `mjpegSplitsAcrossChunks`: fixture entregue em pedaços de 1000 bytes → mesmo número de quadros, cada um começa `FF D8` e termina `FF D9`; `mjpegSkipsGarbage` (bytes antes do primeiro SOI e cabeçalhos multipart entre quadros) ; `mjpegDropsOversized`.
  - `simInputRoundTrip`: cada caso codifica/decodifica igual.
  - `simTextValidation`: `"ola mundo; $(rm) 'x'"` passa; `"ação"` e `"😀"` → `invalidArgs` "device.text on iOS supports US keyboard characters only; use the panel".
  - `iosKeyNames`: tabela acima; `"back"` → nil; `button(named: "home")` == "home".
  - `ipsCrashMatchesUdid`: fixture → `package` == bundle id; outro UDID → nil; `bug_type` diferente → nil.
- [ ] **Step 3:** Implementar (Foundation `JSONSerialization`/`Codable`; nada de AppKit).
- [ ] **Step 4:** `swift test --filter OrqDeviceTests` → PASS.
- [ ] **Step 5:** Commit `feat(device): simctl, AXe tree, MJPEG and simulator input`.

### Task 2: Comandos iOS no daemon (simctl + AXe), plataforma no painel

**Files:** Create `Sources/OrqDaemonKit/Devices/Simulator.swift`, `Sources/OrqDaemonKit/Devices/DeviceService+Android.swift`, `Sources/OrqDaemonKit/Devices/DeviceService+iOS.swift`, `Tests/Fixtures/fake-xcrun.sh`, `Tests/Fixtures/fake-axe.sh`, `Tests/OrqDaemonKitTests/SimCommandTests.swift`; Modify `Sources/OrqDaemonKit/Devices/DeviceService.swift`, `Sources/OrqDaemonKit/{PanelCommands,Daemon}.swift`, `Sources/OrqProtocol/Plugins.swift`

**Interfaces:**
- Consumes: Task 1 (`SimCtl`, `AXeTree`, `SimText`, `IOSKeys`).
- Produces: `struct Simulator { let xcrun: URL; let axe: URL?; static func locateAXe(env: [String: String]) -> URL?; func simctl(_ args: [String], timeout: Duration) async throws(ProtocolError) -> ProcessResult; func axe(_ args: [String], udid: String, timeout: Duration) async throws(ProtocolError) -> ProcessResult }` (axe ausente → mensagem exata; não-zero → `.internal` com stderr cortado em 500). `DaemonConfig.xcrunPath: URL` (padrão `/usr/bin/xcrun`), `DaemonConfig.axePath: URL?`.
- Produces: refatoração sem mudar comportamento: os casos adb de `DeviceService.run` vão para `DeviceService+Android.swift` (`runAndroid`); `run` despacha por `panel.state["platform"]` (`android` padrão). Os testes do 1F continuam passando sem alteração.
- Produces: `device.list` = Android (com `platform: "android"`) + simuladores (`{serial: udid, state, model: name, product: runtime, platform: "ios", panels}`); falha do adb ou do simctl não esconde a outra plataforma (só some a parte que falhou; se as duas falharem, o erro do adb).
- Produces: `panel.open device --serial S`: S é um serial adb **ou** um UDID; UDID → `state["platform"] = "ios"`; simulador `shutdown` → `simctl boot S` + `simctl bootstatus S -b` (timeout 120 s). Sem `--serial`: candidatos = Android `device` + iOS `booted`; regra de "exatamente um" do 1F sobre essa lista.
- Comandos iOS (mesmos nomes e params do 1F; `run` iOS em `DeviceService+iOS.swift`):
  - `screenshot` → `simctl io S screenshot <root>/screens/<panelId>-<epochMs>.png` → `{path,width,height}`
  - `ui` → `axe describe-ui --udid S` → `{tree,truncated}`; refs guardadas por painel (mesmo `refs` do 1F)
  - `tap` x y | `--ref` → `axe tap -x X -y Y --udid S` (pontos; centro do ref)
  - `swipe` → `axe swipe --start-x … --start-y … --end-x … --end-y … --duration <ms/1000> --udid S`
  - `text` → `SimText.validate` e `axe type <texto> --udid S` (argv, sem shell)
  - `key` → `IOSKeys.button` → `axe button <b>`; senão `IOSKeys.usage` → `axe key <n>`; senão `invalidArgs` "Key '<k>' has no iOS equivalent (Enter, Escape, Backspace, Tab, Space, arrows, Home, Lock or a HID usage 0-255)"
  - `logcat` → `simctl spawn S log show --last 5m --style compact` (cap 8 MiB), últimas `lines`, `--grep` local → `{text}`
  - `install` → caminho resolvido como no 1F, precisa ser diretório `.app` → `simctl install S <path>`; `.apk` → `invalidArgs` "iOS installs .app bundles"
  - `launch` → `--activity` → `invalidArgs` "--activity is Android-only"; bundle id `[A-Za-z0-9.-]+` → `simctl launch S <id>` → evento `device.app_launched {serial, package}`
- Ajuda dos comandos em `Plugins.swift`: título do plug-in continua `Dispositivo`; resumos citam "Android (pixels) or iOS Simulator (points)" onde importa (`tap`, `swipe`, `install`, `key`).

`fake-xcrun.sh`: registra em `$ORQ_FAKE_XCRUN_LOG`; `simctl list devices -j` → `cat $ORQ_FAKE_SIM_DEVICES`; `simctl io S screenshot P` → copia `$ORQ_FAKE_ADB_PNG` para P; `simctl boot`/`bootstatus`/`install`/`launch` registram (launch imprime `<id>: 123`); `simctl spawn S log show …` → `cat $ORQ_FAKE_SIM_LOG`. `fake-axe.sh`: registra em `$ORQ_FAKE_AXE_LOG`; `describe-ui` → `cat` fixture; o resto sai 0 (Task 4 acrescenta `stream-video`).

- [ ] **Step 1: Testes que falham** (`SimCommandTests`, aninhada em `DeviceCommandTests`):
  - `listMergesPlatforms`: um Android + um iOS ligado + um iOS desligado → 3 linhas com `platform`; adb ausente → só os iOS.
  - `openShutdownSimulatorBootsIt`: log tem `simctl boot U` e `simctl bootstatus U -b`; painel com `platform == "ios"`.
  - `openWithoutSerialAmongSimulators`: 1 iOS ligado e nenhum Android → abre; 1 de cada → erro listando ambos.
  - `iosCommandsMapToTools`: `tap 10 20` → `axe tap -x 10 -y 20 --udid U`; `swipe … --ms 500` → `--duration 0.5`; `key Enter` → `axe key 40`; `key Home` → `axe button home`; `screenshot` → arquivo com 4×8; `ui` + `tap --ref e1` → centro do nó.
  - `iosTextPassesLiterally`: `text "a; $(x) 'b'"` → argv do axe contém exatamente `a; $(x) 'b'`.
  - `iosRejectsAndroidOnlyArgs`: `key Back`, `launch com.x --activity .Main`, `install foo.apk` → `invalidArgs` com as mensagens acima.
  - `launchEmitsAppLaunchedIOS`; `missingAXeIsUnavailable` (mensagem exata).
  - `canvasSimulatorNeedsCord` (mesma regra do 1F).
- [ ] **Step 2:** `swift test --filter SimCommandTests` → FAIL.
- [ ] **Step 3:** Implementar (primeiro a extração Android, rodar `DeviceCommandTests` verde, depois iOS).
- [ ] **Step 4:** `swift test --filter "DeviceCommand|SimCommand|PanelCommand|Commands|MCP"` → PASS.
- [ ] **Step 5:** Commit `feat(device): iOS Simulator commands via simctl and AXe`.

### Task 3: Vigias iOS — ligado/desligado e crashes

**Files:** Create `Tests/OrqDaemonKitTests/SimWatchTests.swift`; Modify `Sources/OrqDaemonKit/Devices/DeviceService.swift` (ou `+iOS`), `Sources/OrqDaemonKit/Daemon.swift`

**Interfaces:**
- Consumes: Task 1 (`SimCtl`, `IPSCrash`), Task 2 (`Simulator`).
- Produces: o laço de `poll()` do 1F também lê `simctl list devices -j` quando há painel iOS: transição de um UDID com painel para `booted` → `device.connected {serial}`; de `booted` para outro estado → `device.disconnected {serial}` (primeira leitura = linha de base, como no 1F). Crash iOS: enquanto houver painel iOS, a cada poll lista `DaemonConfig.crashReportsDir` (padrão `~/Library/Logs/DiagnosticReports`) por arquivos `.ips` com mtime posterior ao início do vigia e ainda não vistos; `IPSCrash.parse(_, udid:)` → `device.crash {serial, package, text}` (`text` = primeiras 4096 bytes do corpo). Arquivos já vistos guardados por nome (conjunto limitado a 1000; o mais antigo sai).
- Nenhum processo longo novo neste task.

- [ ] **Step 1: Testes que falham** (`SimWatchTests`, aninhada em `DeviceCommandTests`, `pollInterval` 0,2 s, `crashReportsDir` temporário):
  - `bootedToShutdownEmitsDisconnected` e `shutdownToBootedEmitsConnected`.
  - `newIpsForPanelSimulatorEmitsCrash`; `ipsForOtherUdidIgnored`; `oldIpsBeforeWatchIgnored`; `sameIpsReportedOnce`.
  - `noIosPanelNoSimctlPolling` (log do fake sem `simctl list` sem painel iOS).
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "SimWatch|DeviceWatch"` → PASS.
- [ ] **Step 5:** Commit `feat(device): iOS Simulator connection and crash watchers`.

### Task 4: Sessão de vídeo/entrada iOS (`axe stream-video`)

**Files:** Create `Sources/OrqDaemonKit/Devices/SimSession.swift`, `Tests/OrqDaemonKitTests/SimSessionTests.swift`; Modify `Sources/OrqDaemonKit/Devices/{LongProcess,DeviceService}.swift`, `Sources/OrqCore/StreamFrames.swift`, `Tests/Fixtures/fake-axe.sh`

**Interfaces:**
- Consumes: Task 1 (`MJPEGReader`, `SimInput`, `AXeTree`), Task 2 (`Simulator`).
- Produces: `StreamFrame.jpeg(Data)` (tag `jpeg`, `d` base64). Sessão iOS envia: `deviceStatus(connecting)`; `videoMeta(width:height:)` = tamanho da tela em **pontos** (do `screen` do `describe-ui`, arredondado); `deviceStatus(streaming)` no primeiro quadro; `jpeg` por quadro; `deviceStatus(ended|error, motivo)` no fim.
- Produces: `LongProcess` ganha `init(executable:args:env:runDir:onData:onExit:)` (stdout em pedaços binários, até 64 KiB por leitura); o init por linhas continua igual.
- Produces: `DeviceService.attach` escolhe `SimSession` para painéis iOS e `DeviceSession` (1F) para Android; ambas atrás de um protocolo interno `ViewerSession` (`join(_:ok:)`, `leave(_:)`, `input(_:)`, `end(_:)`, `isIdle`) — duas implementações, por isso o protocolo.
- `SimSession`: `LongProcess` `axe stream-video --format mjpeg --fps 15 --quality 70 --scale 0.5 --udid S`; `MJPEGReader` → por espectador: `queuedBytes > 1 MiB` → descarta o quadro; senão envia. Espectador novo recebe o último quadro guardado logo após meta/status. Entrada `.in(Data)` = JSON de `SimInput` → fila serial (máx. **32** pendentes; excesso descartado) → `axe tap|swipe|type|key|button … --udid S` (texto inválido descartado em silêncio). Fim do processo / panelClosed / stop / 5 s sem espectador → mesma limpeza do 1F (terminate, status).

`fake-axe.sh`: `stream-video` → grava `$$` (prefixo `axe `) em `$ORQ_FAKE_AXE_PIDS`, emite os quadros de `stream.mjpeg` em laço a cada 0,1 s (ou `$ORQ_FAKE_AXE_FRAMES` vezes e sai, se definido); `describe-ui` → fixture; demais registram e saem 0 (com `$ORQ_FAKE_AXE_SLEEP` opcional para simular lentidão).

- [ ] **Step 1: Testes que falham** (`SimSessionTests`, aninhada em `DeviceCommandTests`):
  - `streamDeliversMetaAndJpegs`: `ui.device` de painel iOS → `connecting`, `videoMeta` igual ao `screen` da fixture, `streaming`, ≥ 2 `jpeg` que começam `FF D8`; log do axe com as flags exatas de vídeo.
  - `inputRunsAxe`: `.in(SimInput.tap(x:10,y:20))` → log `tap -x 10 -y 20 --udid U`; `swipe` → flags com duração; `button("home")`.
  - `inputBacklogIsBounded`: `ORQ_FAKE_AXE_SLEEP=0.5`, 100 `tap` de uma vez → ≤ 33 execuções registradas ao final; stream não cortado.
  - `slowViewerDropsFrames`: cliente não lê por 3 s → sem `.overflow`, pico de fila < 1,5 MiB + 1 quadro.
  - `streamExitEndsSession`: `ORQ_FAKE_AXE_FRAMES=3` → `deviceStatus(ended)` e pid morto.
  - `lastViewerGraceStops` (grace injetável) e `panelCloseStopsNow`; `lateJoinerGetsLastFrame`.
  - `androidSessionUnchanged`: `DeviceSessionTests` do 1F continuam passando.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "SimSession|DeviceSession|Stream"` → PASS.
- [ ] **Step 5:** Commit `feat(device): iOS Simulator video and input over ui.device`.

### Task 5: App — painel iOS, simuladores no seletor, docs

**Files:** Modify `Sources/OrqPlugins/DevicePanel.swift`, `Sources/OrqApp/OpenPanelSheet.swift`, `README.md`, `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`; Test `Tests/OrqPluginsTests/DevicePanelTests.swift`

**Interfaces:**
- Consumes: Task 4 (frames `jpeg`, `videoMeta` em pontos), Task 1 (`SimInput`, `IOSKeys.usage(macKeyCode:)`), Task 2 (`device.list` com `platform`).
- Produces (internal, testáveis): `enum SimGesture { static func classify(down: CGPoint, up: CGPoint, seconds: Double) -> SimInput }` — deslocamento < 8 pt e < 0,5 s → `tap(up)`; senão `swipe(down→up, seconds: clamp(seconds, 0.1, 2))`. `struct ScrollAccumulator { mutating func add(dx: Double, dy: Double) ; mutating func flush(at center: CGPoint, screen: CGSize) -> SimInput? }` — soma deltas (trackpad: valor; roda: ×10), `flush` após 150 ms de silêncio vira `swipe` do centro no sentido do conteúdo, limitado a 40% da tela, `seconds: 0.3`.
- `DevicePanel` em modo iOS (`panel.state["platform"] == "ios"`): mesma view; quadros `jpeg` decodificados fora da main (`CGImageSource`) e aplicados como `layer.contents` na main com **um único slot** (sempre o mais novo; nada acumula); `videoRect`/`devicePoint` do 1F com o tamanho em pontos do `videoMeta`; mouse → `SimGesture` (sem eventos de movimento); rolagem → `ScrollAccumulator`; teclas especiais → `SimInput.key(IOSKeys.usage(macKeyCode:))`; texto → `SimInput.text` (só se `SimText.validate` aceitar); envio `.in(JSONEncoder().encode(input))`. Barra iOS: **Início** (`button("home")`) e **Bloquear** (`button("lock")`); sem Voltar/Recentes.
- `OpenPanelSheet`: o seletor lista Android `device` e iOS `booted`/`shutdown` como "iPhone 16e — iOS 26.3 (desligado)" etc.; escolher um desligado avisa "vai ligar o simulador".

- [ ] **Step 1: Testes que falham** (`DevicePanelTests`): `clickIsTap`, `dragIsSwipe` (duração limitada), `longPressStillTap` (< 8 pt, 0,4 s → tap), `scrollAccumulatesToSwipe` (trackpad dy −120 → swipe para cima, limitado a 40%), `iosPanelSendsSimInput` (painel iOS com `openStream` falso: clique em view 400×800 com meta 390×844 → `.in` decodifica como `tap` no ponto mapeado).
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift build`; suíte inteira `swift test` → PASS.
- [ ] **Step 5:** README: seção "Simulador iOS" (Xcode 26+, `brew install cameroncooke/axe/axe`, AXe 1.8.0 testado; abrir painel liga o simulador; coordenadas em pontos; limitações: só simulador, texto só teclado US no `device.text`, sem botões de volume/Siri na barra, vídeo depende do AXe acompanhar o Xcode). Roteiro: linha 1G aponta este plano. Commit `feat(app): iOS Simulator device panel`.

---

## Limitações conhecidas (aceitas neste plano)

- iPhone físico fora; nada de ScreenCaptureKit (decisão do usuário).
- AXe usa frameworks privados do simulador: uma atualização do Xcode pode quebrar vídeo/entrada até atualizar o AXe.
- Gestos do painel são toque e arrasto simples (sem multitoque/pinça); arrasto vira um `swipe` ao soltar (sem seguir o dedo em tempo real).
- ANR/travamentos sem relatório `.ips` não viram evento.
