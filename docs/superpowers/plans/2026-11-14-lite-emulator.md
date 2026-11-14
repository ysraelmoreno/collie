# Emulador leve `collie-lite` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `collie device lite create` cria o AVD `collie-lite` (leve em RAM e CPU) pelo `avdmanager`, e o Collie o sobe com flags extras.

**Architecture:** Funções puras (escolha de imagem, mesclagem de `config.ini`, argumentos) em `CollieDevice`; localização de ferramentas e execução do `avdmanager` no daemon, em `Sources/CollieDaemonKit/Devices/`; dois comandos `device.lite.create` e `device.lite.remove`, sem painel e só para admin; `Emulator.launch` acrescenta flags quando o AVD é `collie-lite`.

**Tech Stack:** Swift, swift-testing, `BoundedProcess`, Android SDK `cmdline-tools` (`avdmanager`).

**Spec:** `docs/superpowers/specs/2026-11-14-lite-emulator-design.md`

## Global Constraints

- Nome fixo do AVD: `collie-lite`. Escreve só em `~/.android/avd/collie-lite*`; nunca toca outros AVDs nem o SDK.
- Sem `avdmanager`: erro `unavailable`, sem criar arquivo à mão. Nunca baixa imagem de sistema.
- Valores do AVD (spec): `hw.lcd.width=720`, `hw.lcd.height=1280`, `hw.lcd.density=320`, `hw.ramSize=1536`, `hw.cpu.ncore=2`, `disk.dataPartition.size=2G`, `hw.camera.back=none`, `hw.camera.front=none`, `hw.audioInput=no`, `hw.audioOutput=no`, `hw.sensors.orientation=no`, `hw.sensors.proximity=no`, `hw.sensors.humidity=no`, `hw.sensors.pressure=no`, `hw.sensors.magnetic_field=no`, `hw.sensors.temperature=no`, `showDeviceFrame=no`; `hw.gpu.mode` decidido na Task 7.
- Flags de lançamento só para `collie-lite`: `-no-audio -no-boot-anim -no-metrics`.
- Imagem: `google_apis` arm64-v8a de maior API; senão `google_apis_playstore*`.
- Java do `avdmanager`: `COLLIE_JAVA_HOME`, `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, depois `/usr/libexec/java_home`.
- Testes só com `--filter`, nunca `swift test` inteiro. Nunca emulador real nos testes unitários. Sem push, sem instalar o app. Commits por tarefa só com os arquivos da tarefa, terminando com `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Validar em worktree isolada (`git worktree add --detach <tmp> HEAD`, `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>`); a compilação a frio leva uns 10 min.

## Review Focus

- `avdmanager create avd` pergunta "custom hardware profile?" no stdin: o comando não pode travar (stdin fechado ou `no`).
- `collie-lite` já existe: `create` não recria (perderia o `userdata`); só reaplica a mesclagem do `config.ini`.
- Nenhuma imagem `google_apis` instalada: erro nomeando o pacote a instalar.
- `config.ini` com `chave = valor` (espaços) e `chave=valor`: a mesclagem troca a chave existente nos dois formatos, sem duplicar.
- `avdmanager` trava ou o Java não existe: timeout com erro claro, sem processo órfão.

---

### Task 1: Funções puras do AVD leve

**Files:**
- Create: `Sources/CollieDevice/LiteAvd.swift`
- Test: `Tests/CollieDeviceTests/LiteAvdTests.swift` (confirmar o nome da pasta de testes de `CollieDevice`; criar se não houver)

**Interfaces:**
- Produces:
  - `enum LiteAvd { static let name = "collie-lite"; static let overrides: [String: String]; static let launchFlags: [String] }`
  - `static func pickImage(_ packages: [String]) -> String?` (pacotes no formato `system-images;android-37.0;google_apis;arm64-v8a`)
  - `static func mergeConfig(_ existing: String, _ overrides: [String: String]) -> String`
  - `static func installedImages(sdkRoot: URL) -> [String]` (lista `system-images/<api>/<tag>/arm64-v8a` que existem em disco)

- [ ] **Step 1: Testes que falham.** `pickImageTakesHighestGoogleApisArm64` (entre `android-35` e `android-37.0` `google_apis`, escolhe o 37; `google_apis` vence `google_apis_playstore`; só playstore presente, escolhe o playstore; nenhum, `nil`; ignora ABI que não seja `arm64-v8a`). `mergeReplacesBothSpacings` (`hw.ramSize = 3072` e `hw.ramSize=2048` viram `hw.ramSize=1536`, uma só ocorrência). `mergeAppendsMissingKeysAndKeepsTheRest`. `overridesCarryTheSpecValues` (compara cada chave da tabela da Global Constraints). `installedImagesReadsTheTree` (árvore de diretório temporária).
- [ ] **Step 2: Rodar e ver falhar.** `swift test ... --filter LiteAvdTests`; esperado: erro de compilação, `LiteAvd` indefinido.
- [ ] **Step 3: Implementar** as quatro funções e as constantes em `LiteAvd.swift`. API ordenando por número de API (extrair o número de `android-37.0`), sem biblioteca nova.
- [ ] **Step 4: Rodar e ver passar.** Mesmo filtro; esperado: todos passam.
- [ ] **Step 5: Commit.** `git add Sources/CollieDevice/LiteAvd.swift Tests/.../LiteAvdTests.swift`; mensagem `feat(device): pure pieces of the lite AVD`.

### Task 2: Localizar `avdmanager` e Java; montar o processo

**Files:**
- Create: `Sources/CollieDaemonKit/Devices/AvdManager.swift`
- Test: `Tests/CollieDaemonKitTests/AvdManagerTests.swift`

**Interfaces:**
- Consumes: `LiteAvd` (Task 1), `BoundedProcess.run(executable:args:in:env:timeout:cap:)`.
- Produces:
  - `struct AvdManager: Sendable { let url: URL; let javaHome: String }`
  - `static func locate(env: [String: String], home: String, javaCandidates: [String]? = nil) -> AvdManager?` (`COLLIE_AVDMANAGER`, `$ANDROID_HOME`/`$ANDROID_SDK_ROOT` + `cmdline-tools/latest/bin/avdmanager`, `<home>/Library/Android/sdk/...`; Java na ordem da Global Constraints; `nil` se faltar um dos dois)
  - `static let missing: ProtocolError` (`.unavailable`, mensagem manda instalar "Android SDK Command-line Tools (latest)" no Android Studio, SDK Tools)
  - `func run(_ args: [String], env: [String: String], timeout: Duration) async throws(ProtocolError) -> ProcessResult` (define `JAVA_HOME`, stdin fechado, saída limitada a 1 MiB)

- [ ] **Step 1: Testes que falham** no estilo de `EmulatorTests.locatePrefersOverrideThenSdk` (executáveis em diretório temporário): `locatePrefersOverrideThenSdk`, `locateReturnsNilWithoutJava`, `javaPrefersCollieOverStudio`.
- [ ] **Step 2: Rodar e ver falhar** (`--filter AvdManagerTests`).
- [ ] **Step 3: Implementar** `AvdManager`; `run` usa `BoundedProcess`. Para o stdin fechado, ver como `BoundedProcess` trata stdin; se não fechar, passar `no\n` por stdin ou `</dev/null` via o próprio executável de forma que a pergunta de perfil de hardware receba o padrão `no`.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(device): locate avdmanager and Java`.

### Task 3: Criar e remover o AVD no serviço

**Files:**
- Modify: `Sources/CollieDaemonKit/Devices/DeviceService+Android.swift` (extensão nova, perto de `avds()`)
- Test: `Tests/CollieDaemonKitTests/LiteAvdServiceTests.swift`

**Interfaces:**
- Consumes: `AvdManager`, `LiteAvd`, `DeviceService` (`root`, `emulator()`, `emulatorEnv`).
- Produces:
  - `func createLiteAvd() async throws(ProtocolError) -> [String: String]` → `{name, path, image, created: "true"|"false"}`
  - `func removeLiteAvd() async throws(ProtocolError)`

- [ ] **Step 1: Testes que falham**, com um `avdmanager` falso (script em diretório temporário que grava os argumentos e cria `ANDROID_AVD_HOME/collie-lite.avd/config.ini`): `createRunsAvdmanagerWithTheChosenImage` (argumentos `create avd -n collie-lite -k <pacote> -d pixel --force`), `createMergesTheOverrides`, `createTwiceDoesNotRecreate` (segunda chamada: `created == "false"`, `avdmanager create` não roda de novo, config reaplicado), `noImageFailsNamingThePackage`, `noAvdmanagerFailsUnavailable`, `removeRunsDelete` (`delete avd -n collie-lite`).
- [ ] **Step 2: Rodar e ver falhar** (`--filter LiteAvdServiceTests`).
- [ ] **Step 3: Implementar.** Existência do AVD: `collie-lite.avd/config.ini` presente em `ANDROID_AVD_HOME` ou `~/.android/avd`. SDK root vem do mesmo cálculo de `emulator()`. Timeout de 60 s no `avdmanager`.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(device): create and remove the collie-lite AVD`.

### Task 4: Comandos `device.lite.create` e `device.lite.remove`

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (dois `dcmd(..., panelFree: true)` na lista de `device`)
- Modify: `Sources/CollieDaemonKit/DeviceCommands.swift` (tratar os dois antes de resolver painel, só admin)
- Test: `Tests/CollieDaemonKitTests/DeviceCommandTests.swift` (casos novos); rodar também `CommandsTests` e `MCPTests`

**Interfaces:**
- Consumes: `createLiteAvd`, `removeLiteAvd` (Task 3).
- Produces: `device.lite.create` → `{name,path,image,created}`; `device.lite.remove` → `{}`. Chamador com principal (não admin): erro de permissão.

- [ ] **Step 1: Testes que falham**: `liteCreateIsAdminOnly`, `liteCreateReturnsTheRow`, `liteRemoveReturnsEmpty`, `helpListsBothCommands`.
- [ ] **Step 2: Rodar e ver falhar.**
- [ ] **Step 3: Implementar.** `timeout: 90`. Resumo do comando diz que escreve em `~/.android/avd` e precisa do `cmdline-tools`.
- [ ] **Step 4: Rodar** `--filter DeviceCommandTests`, `--filter CommandsTests`, `--filter MCPTests`; esperado: passam (MCPTests pode falhar no sandbox por causa do baseline; comparar com o HEAD).
- [ ] **Step 5: Commit** `feat(device): lite AVD commands`.

### Task 5: Flags extras no lançamento

**Files:**
- Modify: `Sources/CollieDaemonKit/Devices/Emulator.swift` (`launch`, linha `let args: [String] = [path, "-avd", avd]`)
- Test: `Tests/CollieDaemonKitTests/EmulatorTests.swift` (caso novo, usando o log do emulador falso já existente)

**Interfaces:**
- Consumes: `LiteAvd.name`, `LiteAvd.launchFlags`.
- Produces: `static func extraArgs(for avd: String) -> [String]` em `Emulator` (`LiteAvd.launchFlags` para `collie-lite`, `[]` para os outros).

- [ ] **Step 1: Testes que falham**: `liteLaunchGetsExtraFlags` (o emulador falso recebe `-avd collie-lite -no-audio -no-boot-anim -no-metrics`), `otherAvdsLaunchUnchanged` (só `-avd <nome>`).
- [ ] **Step 2: Rodar e ver falhar** (`--filter EmulatorTests`).
- [ ] **Step 3: Implementar** `extraArgs` e usá-lo em `launch`.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(device): lean launch flags for collie-lite`.

### Task 6: Medição, modo de GPU e documentação

**Files:**
- Modify: `Sources/CollieDevice/LiteAvd.swift` (`hw.gpu.mode` em `overrides`)
- Modify: `docs/superpowers/specs/2026-11-14-lite-emulator-design.md` (resultado da medição)
- Modify: `README.md` (uma seção curta: como criar e usar `collie-lite`)

Sem teste novo (medição manual); `overridesCarryTheSpecValues` da Task 1 passa a cobrir o valor de GPU escolhido.

- [ ] **Step 1: Criar o AVD real** com o binário instalado a partir deste commit (ou `scripts/dev/run-isolated.sh`, para não mexer no app instalado): `collie device lite create`; esperado: `created: "true"`; `collie device list` mostra `avd:collie-lite`.
- [ ] **Step 2: Medir** para cada modo `hw.gpu.mode` (`auto`, `host`, e `swangle_indirect` se existir): subir por `collie panel open device --serial avd:collie-lite`, esperar o boot, 60 s de espera, depois 12 amostras de 5 s de `ps -o pcpu=,rss= -p <pid>` e `footprint <pid>`, com o painel fechado; repetir com o painel aberto. Encerrar por `adb emu kill`. Baseline a bater (`spike-net-api37`): pegada ~3,0 GB, CPU de repouso ~9%.
- [ ] **Step 3: Fixar** o modo de menor CPU que mantém a tela correta no painel (conferir com `collie device screenshot`), gravar em `overrides` e rodar `--filter LiteAvdTests`.
- [ ] **Step 4: Registrar** a tabela antes/depois no spec e a seção do README.
- [ ] **Step 5: Commit** `docs(device): lite emulator results and usage`.
