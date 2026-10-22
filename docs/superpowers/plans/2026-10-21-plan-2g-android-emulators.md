# Plano 2G — Abrir emuladores Android desligados — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A lista de aparelhos do Orq mostra os emuladores Android (AVDs) instalados e desligados, e abrir um painel num deles liga o emulador, espera o Android terminar de iniciar e abre o painel. É o que o iOS já faz com simuladores desligados.

**Architecture:** O daemon acha o binário `emulator` do SDK, como já acha o `adb`. `emulator -list-avds` dá os AVDs. Os que já rodam são reconhecidos por `adb -s emulator-NNNN emu avd name` e não se repetem. Um AVD desligado entra no `device.list` com serial `avd:<nome>` e estado `off`. `panel.open device --serial avd:<nome>` liga o emulador fora dos grupos de processo do daemon e espera por `adb devices -l`, pelo nome do AVD e por `sys.boot_completed`, até 180 s. O painel fica com o serial real (`emulator-NNNN`). Ninguém do Orq desliga o emulador: fechar o painel ou parar o serviço o deixa ligado (decisão do usuário, 2026-10-21).

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing; Android SDK `emulator` + `adb` (já usados); nenhuma dependência nova.

**Spec:** pedido do usuário em 2026-10-21 ("listar emuladores instalados e abrir, sem precisar abrir antes"; "deixa ligado ao fechar") sobre a spec `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (painel de dispositivo, Fase 1F). Base: `main` com 2E e 2F. Independe do 3R e do 3A.

## Global Constraints

- **Nada é desligado pelo Orq:** nem o emulador (fechar painel, parar o serviço ou falhar a espera não o matam), nem o servidor do adb (`kill-server` nunca é enviado, como hoje).
- O emulador é lançado **fora** dos grupos de processo do daemon (como `Adb.startServer`): o timeout ou `terminate()` de um `BoundedProcess`/`LongProcess` não pode levá-lo junto.
- Sem configuração global do usuário: nada é escrito no SDK nem em `~/.android`. Só se lê.
- Nada de I/O bloqueante no pool cooperativo. Lançar e esperar processo vai em `DispatchQueue.global()`, como `startServer`; o sondar usa `Task.sleep`.
- Protocolo `v: 1`, só acréscimos: linhas novas no `device.list` (`state: "off"`, serial `avd:<nome>`) e uma forma nova de `--serial`. O `timeoutSeconds` do `panel.open` sobe de 130 para 190 (o de quem chama: `DaemonClient` 130 → 190).
- Textos de UI em **português**; erros do daemon em inglês, como os demais `device.*`.
- **Corda é a única permissão:** `device.list` e `panel.open` mantêm as regras de hoje (`panel.open` só Maestro/app).

## Review Focus

1. **AVD já ligado por fora do Orq** (pelo Android Studio) → não aparece como "desligado"; abrir usa o `emulator-NNNN` que já roda, sem lançar outro. Teste: Task 2 `listHidesRunningAvd`, Task 3 `openRunningAvdDoesNotLaunch`.
2. **Dois `panel.open` do mesmo AVD ao mesmo tempo** (app e Maestro) → um só `emulator -avd` lançado; os dois painéis ficam com o mesmo serial. Teste: Task 3 `concurrentOpensLaunchOnce`.
3. **O emulador sai logo** (AVD quebrado, sem hipervisor, imagem faltando) → erro em segundos com as últimas linhas do log do emulador, sem esperar 180 s. Teste: Task 3 `emulatorExitsEarlyFails`.
4. **Já existe outro emulador rodando** (`emulator-5554` de outro AVD) → o painel fica com o serial do AVD pedido (`emulator-5556`), nunca com o primeiro emulador que aparecer. Teste: Task 3 `picksSerialByAvdName`.
5. **Só platform-tools instalado** (sem `emulator`) → `device.list` igual a hoje, sem erro; abrir `avd:X` → `.unavailable` "Android emulator not found…". Teste: Task 2 `missingEmulatorListsAsToday`, Task 3 `openAvdWithoutEmulatorFails`.

---

## File Structure

```
Sources/OrqDevice/AdbParsing.swift                     + avds(_:) (saída de -list-avds)
Sources/OrqDaemonKit/Devices/Emulator.swift            Emulator.locate, launch (fora do grupo), log
Sources/OrqDaemonKit/Devices/DeviceService+Android.swift  avds(), bootAvd(_:)
Sources/OrqDaemonKit/Devices/DeviceService.swift       resolveSerial aceita avd:<nome>; init ganha emulator + emulatorBoot
Sources/OrqDaemonKit/DeviceCommands.swift              device.list com AVDs desligados
Sources/OrqDaemonKit/{Daemon,CommandRouter}.swift      config.emulatorPath
Sources/OrqProtocol/Commands.swift                     panel.open: timeout 190, help do --serial
Sources/OrqClient/DaemonClient.swift                   timeout 190
Sources/OrqApp/OpenPanelSheet.swift                    AVDs "(desligado)" + aviso
Sources/OrqDaemonKit/OrqOrientation.swift              dica avd:<nome>
Tests/Fixtures/fake-emulator.sh, Tests/Fixtures/fake-adb.sh
Tests/OrqDeviceTests/ParsingTests.swift, Tests/OrqDaemonKitTests/EmulatorTests.swift
README.md, docs/superpowers/plans/2026-10-20-phase2-roadmap.md
```

---

### Task 1: Achar o `emulator` e ler a lista de AVDs

**Files:** Create `Sources/OrqDaemonKit/Devices/Emulator.swift`; Modify `Sources/OrqDevice/AdbParsing.swift`, `Tests/OrqDeviceTests/ParsingTests.swift`, `Tests/OrqDaemonKitTests/EmulatorTests.swift` (create)

**Interfaces:**
- Produces:
  - `AdbParsing.avds(_ out: String) -> [String]`: um nome por linha, sem espaços nas pontas. Pula linhas vazias e as de log do emulador, que contêm `" | "` (por exemplo `INFO    | Storing crashdata in: …`). Sem duplicatas, na ordem de saída.
  - `struct Emulator: Sendable { let url: URL; static func locate(env: [String: String], home: String) -> URL?; static let missing: ProtocolError }`.
    - `locate` devolve o primeiro executável entre `ORQ_EMULATOR`, `$ANDROID_HOME/emulator/emulator`, `$ANDROID_SDK_ROOT/emulator/emulator` e `~/Library/Android/sdk/emulator/emulator`.
    - `missing` tem código `.unavailable` e a mensagem `"Android emulator not found. Install it with Android Studio (SDK Manager → Android Emulator) or set ORQ_EMULATOR."`.
  - `func listAvds(timeout: Duration) async throws(ProtocolError) -> [String]`, que roda `-list-avds` por `BoundedProcess` (é curto, sai sozinho).

- [ ] **Step 1: Testes que falham:**

```swift
// ParsingTests
@Test func avdsSkipsLogLines() {
    let out = "INFO    | Storing crashdata in: /tmp/x\nPixel_7_API_34\n\nTablet_API_33\nPixel_7_API_34\n"
    #expect(AdbParsing.avds(out) == ["Pixel_7_API_34", "Tablet_API_33"])
}
// EmulatorTests
@Test func locatePrefersOverrideThenSdk() throws {
    let dir = try tmpExecutable("emulator/emulator")   // helper: cria <tmp>/emulator/emulator com chmod 755
    #expect(Emulator.locate(env: ["ANDROID_HOME": dir.path], home: "/nonexistent")?.path == dir.appendingPathComponent("emulator/emulator").path)
    #expect(Emulator.locate(env: [:], home: "/nonexistent") == nil)
}
```

- [ ] **Step 2:** `swift test --filter "avdsSkipsLogLines|locatePrefersOverrideThenSdk"` → FAIL.
- [ ] **Step 3: Implementar** `AdbParsing.avds`, `Emulator.locate`, `Emulator.missing` e `Emulator.listAvds`.
- [ ] **Step 4:** mesmo comando → PASS.
- [ ] **Step 5: Commit** `feat(device): locate the Android emulator and parse -list-avds`

---

### Task 2: AVDs desligados no `device.list`

**Files:** Modify `Sources/OrqDaemonKit/Daemon.swift` (`public var emulatorPath: URL?`), `CommandRouter.swift` (passa `emulator:` ao `DeviceService`), `Devices/DeviceService.swift` (init), `Devices/DeviceService+Android.swift`, `DeviceCommands.swift`, `Tests/Fixtures/fake-adb.sh`; Create `Tests/Fixtures/fake-emulator.sh`; Modify `Tests/OrqDaemonKitTests/EmulatorTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `DeviceService.init(…, emulator: @escaping @Sendable () -> URL? = { nil }, emulatorBoot: Duration = .seconds(180), …)`.
  - `struct Avd: Sendable, Equatable { var name: String; var serial: String? }`, onde `serial` é o `emulator-NNNN` em que o AVD já roda, ou nil.
  - `func avds() async -> [Avd]`. Sem `emulator`, ou com `-list-avds` falhando, devolve `[]`, nunca um erro. Para cada serial `emulator-*` em estado `device`, roda `adb -s <serial> emu avd name`; a primeira linha é o nome e o `OK` é ignorado. Se esse comando falhar, o serial fica sem nome.
  - Em `device.list`, cada AVD com `serial == nil` vira a linha `{"serial": "avd:<nome>", "state": "off", "model": <nome com "_" → " ">, "product": null, "platform": "android", "panels": []}`, depois das linhas do adb e antes dos simuladores.
- Fixtures:
  - `fake-emulator.sh`:
    - `-list-avds` imprime o arquivo `$ORQ_FAKE_EMULATOR_AVDS`.
    - `-avd <nome> …` acrescenta `launch <nome> $$` a `$ORQ_FAKE_EMULATOR_LOG`. Se `$ORQ_FAKE_EMULATOR_FAIL` estiver definido, imprime `FATAL | broken AVD` em stdout e sai com 1.
    - Senão, espera `${ORQ_FAKE_EMULATOR_DELAY:-0}` s, acrescenta `$ORQ_FAKE_EMULATOR_SERIAL device product:sdk model:<nome>` ao arquivo de devices do fake adb e grava `<serial> <nome>` em `$ORQ_FAKE_ADB_AVDNAMES`.
    - Por fim, `exec sleep 600`.
  - `fake-adb.sh`:
    - `emu avd name` imprime o nome do serial em `$ORQ_FAKE_ADB_AVDNAMES` e depois `OK`; sem linha para o serial, sai com 1.
    - `shell getprop sys.boot_completed` imprime `${ORQ_FAKE_ADB_BOOTED:-1}`.

- [ ] **Step 1: Testes que falham** (`EmulatorTests`, no molde de `DeviceCommandTests`, com `configure: { $0.adbPath = fakeAdb; $0.emulatorPath = fakeEmulator }`):

```swift
@Test func listShowsOffAvds() async throws {
    // AVDs: Pixel_7_API_34, Tablet_API_33; nada rodando
    let rows = try await deviceList()
    let off = rows.filter { $0["state"] == "off" }
    #expect(off.map { $0["serial"] } == ["avd:Pixel_7_API_34", "avd:Tablet_API_33"])
    #expect(off.first?["model"] == "Pixel 7 API 34" && off.first?["platform"] == "android")
}
@Test func listHidesRunningAvd() async throws {
    // devices: emulator-5554 device; AVDNAMES: "emulator-5554 Pixel_7_API_34"
    let rows = try await deviceList()
    #expect(!rows.contains { $0["serial"] == "avd:Pixel_7_API_34" })
    #expect(rows.contains { $0["serial"] == "avd:Tablet_API_33" })
    #expect(rows.contains { $0["serial"] == "emulator-5554" && $0["state"] == "device" })
}
@Test func missingEmulatorListsAsToday() async throws {
    // emulatorPath aponta para um caminho inexistente
    let rows = try await deviceList()
    #expect(!rows.contains { $0["state"] == "off" } && rows.contains { $0["serial"] == "emulator-5554" })
}
```

- [ ] **Step 2:** `swift test --filter EmulatorTests` → FAIL.
- [ ] **Step 3: Implementar** a config, o init, `avds()`, as linhas do `device.list` e os fixtures.
- [ ] **Step 4:** `swift test --filter "EmulatorTests|DeviceCommandTests"` → PASS. Os testes que já existiam não mudam: sem `emulatorPath` nos testes, o fallback de `Emulator.locate` pode achar o SDK real da máquina, então o `configure` de `DeviceCommandTests` ganha `$0.emulatorPath = URL(fileURLWithPath: "/nonexistent")`.
- [ ] **Step 5: Commit** `feat(device): list installed Android emulators that are off`

---

### Task 3: Ligar o AVD ao abrir o painel

**Files:** Modify `Sources/OrqDaemonKit/Devices/Emulator.swift`, `DeviceService.swift`, `DeviceService+Android.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqClient/DaemonClient.swift`, `Tests/OrqDaemonKitTests/EmulatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - **`Emulator.launch`:** `func launch(avd: String, log: URL, sdkRoot: URL) async throws(ProtocolError) -> Int32` devolve o pid.
    - Roda `<emulator> -avd <nome>` com `Process` comum em `DispatchQueue.global()`, como em `Adb.startServer`: fora de qualquer grupo de processo do daemon, stdin em `/dev/null`, stdout e stderr acrescentados a `log`.
    - O ambiente é o do daemon com `ANDROID_SDK_ROOT = sdkRoot`, a pasta-avó do binário `emulator`.
    - O daemon **não** guarda o `Process` para matar depois.
  - **`DeviceService.bootAvd`:** `func bootAvd(_ name: String) async throws(ProtocolError) -> String` devolve o serial `emulator-NNNN`.
    - Um `Task` por nome num `[String: Task<String, Error>]`: chamadas paralelas esperam o mesmo, e ele sai do dicionário ao terminar.
    - Passos:
      1. `avds()`: se o AVD já roda, devolve o serial dele sem lançar.
      2. Lança o emulador com log em `<runDir>/emulator-<nome>.log`, truncado a cada lançamento.
      3. Sonda a cada 1 s: `adb devices -l`; para cada `emulator-*` em `device`, sem nome conhecido ainda, `emu avd name`; quando aparece o AVD pedido, `shell getprop sys.boot_completed` até dar `1`.
    - O prazo é `emulatorBoot` (180 s).
    - Se o processo sai antes do prazo (`kill(pid, 0)` falha), lança `ProtocolError(.internal, "Emulator '<nome>' exited: <últimas 5 linhas do log, até 500 caracteres>")`.
    - Se o prazo acaba, lança `ProtocolError(.timeout, "Emulator '<nome>' did not finish booting in 180 s (it is left running)")`. O emulador fica ligado.
  - **`resolveSerial`:** `"avd:<nome>"` → `bootAvd(nome)` → `(serial, "android")`. Sem `emulator`, lança `Emulator.missing`. Nome que não está em `-list-avds` → `.invalidArgs`, com a lista de AVDs conhecidos.
  - **Timeouts:** `panel.open` passa a `timeoutSeconds: 190`, com o comentário "a shut-down simulator (120 s) or Android emulator (180 s) boots first". O help do `serial` vira `"Android serial, avd:<AVD name> (boots it), or iOS Simulator UDID (boots a shut-down one); default: the only one online"`. `DaemonClient.openPanel` usa 190 quando há `serial`.

- [ ] **Step 1: Testes que falham** (prazo curto nos testes: `emulatorBoot: .seconds(5)`; fake emulator com `DELAY=1`, `SERIAL=emulator-5556`):

```swift
@Test func openOffAvdBootsAndUsesSerial() async throws {
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "placement": "dock.right"])
    #expect(panelState(r)["serial"] == "emulator-5556")
    #expect(emulatorLog().filter { $0.hasPrefix("launch Pixel_7_API_34") }.count == 1)
}
@Test func concurrentOpensLaunchOnce() async throws {
    async let a = admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "a"])
    async let b = admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "b"])
    _ = try await (a, b)
    #expect(emulatorLog().filter { $0.hasPrefix("launch") }.count == 1)
}
@Test func openRunningAvdDoesNotLaunch() async throws {
    // emulator-5554 já roda Pixel_7_API_34
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
    #expect(panelState(r)["serial"] == "emulator-5554" && emulatorLog().isEmpty)
}
@Test func picksSerialByAvdName() async throws {
    // emulator-5554 roda Tablet_API_33; pedir Pixel_7_API_34 → emulator-5556
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
    #expect(panelState(r)["serial"] == "emulator-5556")
}
@Test func emulatorExitsEarlyFails() async throws {
    // ORQ_FAKE_EMULATOR_FAIL=1
    let started = ContinuousClock.now
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
    #expect(r.error?.message.contains("broken AVD") == true && ContinuousClock.now - started < .seconds(4))
}
@Test func bootTimeoutLeavesEmulatorRunning() async throws {
    // ORQ_FAKE_ADB_BOOTED=0: nunca termina de iniciar
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])
    #expect(r.error?.code == .timeout)
    #expect(kill(fakeEmulatorPid(), 0) == 0)   // ainda vivo; o teste o mata no fim
}
@Test func closePanelLeavesEmulatorRunning() async throws {
    _ = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34", "name": "d"])
    _ = try await admin("panel.close", ["name": "d"])
    #expect(kill(fakeEmulatorPid(), 0) == 0)
}
@Test func openAvdWithoutEmulatorFails() async throws {
    let r = try await admin("panel.open", ["plugin": "device", "serial": "avd:Pixel_7_API_34"])   // emulatorPath inexistente
    #expect(r.error?.code == .unavailable)
}
```

(Cada teste mata no fim o `sleep 600` do fake emulator, pelo pid que o log guarda.)

- [ ] **Step 2:** `swift test --filter EmulatorTests` → FAIL.
- [ ] **Step 3: Implementar** `Emulator.launch`, `bootAvd`, o ramo `avd:` em `resolveSerial` e os timeouts.
- [ ] **Step 4:** `swift test --filter "EmulatorTests|DeviceCommandTests|DeviceWatchTests"` → PASS.
- [ ] **Step 5: Verificar à mão** (com Android Studio e um AVD criado; todos os emuladores desligados): `orq device list` mostra `avd:<nome> off`; `orq panel open device --serial avd:<nome>` (de um Maestro) liga o emulador, o painel mostra o vídeo e `orq device list` passa a mostrar `emulator-5554 device`; fechar o painel deixa o emulador ligado.
- [ ] **Step 6: Commit** `feat(device): boot an Android emulator that is off when its panel opens`

---

### Task 4: App, orientação e docs

**Files:** Modify `Sources/OrqApp/OpenPanelSheet.swift`, `Sources/OrqDaemonKit/OrqOrientation.swift`, `Tests/OrqDaemonKitTests/OrqOrientationTests.swift`, `README.md`, `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`

**Interfaces:**
- Consumes: as linhas `state: "off"` do Task 2.

- [ ] **Step 1: Folha "Abrir painel".**
  - Em `loadDevices`, linha Android com `state == "off"` entra como `(serial, "\(model) (desligado)", off: true)`, depois dos aparelhos ligados.
  - O aviso passa a depender da plataforma: "Abrir vai ligar o emulador (pode levar até 3 min)." no Android e o texto atual no iOS. Para isso a tupla ganha `platform`.
- [ ] **Step 2: Orientação.** A dica `device [--serial <id>]` vira `device [--serial <id|avd:<nome>>]`. O teste da orientação passa a esperar o texto novo.
- [ ] **Step 3: Verificar:** `swift build --product OrqApp`. No app, Abrir painel → Dispositivo lista "Pixel 7 API 34 (desligado)" com o aviso; Abrir liga o emulador e mostra o vídeo.
- [ ] **Step 4: Docs.**
  - **README**, seção de dispositivos: emuladores desligados aparecem como `avd:<nome>`; abrir liga o emulador (até 3 min); o Orq nunca o desliga; `ORQ_EMULATOR` aponta um binário fora do SDK padrão.
  - **Roteiro da fase 2:** linha 2G.
- [ ] **Step 5: Commit** `feat(app): open Android emulators that are off; docs`
