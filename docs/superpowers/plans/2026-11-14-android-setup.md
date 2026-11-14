# Instalação do Android (daemon) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O daemon instala o que falta do Android SDK (JDK, Command-line Tools, Emulator, Platform-tools, imagem) em duas fases, com licenças aceitas pelo usuário, e todos os localizadores passam a achar o SDK reaproveitado ou o do Collie.

**Architecture:** Funções puras em `CollieDevice` (resolver SDK, Java, parse do `sdkmanager`); um instalador no daemon (`Sources/CollieDaemonKit/Android/`) com downloader injetável e `sdkmanager` via `BoundedProcess`; quatro comandos `android.*` só admin. O app e o CLI consultam o progresso por `android.status` (sem eventos push; minha chamada: o app consulta a cada 1 s com a tela visível).

**Tech Stack:** Swift, swift-testing, `URLSession`, `BoundedProcess`, Android `cmdline-tools`.

**Spec:** `docs/superpowers/specs/2026-11-14-android-setup-design.md` (ler também a seção "Esclarecimentos"). A tela de Preferências (SwiftUI, opção B) é um plano à parte, depois deste.

## Global Constraints

- Ordem de busca do SDK: `COLLIE_ANDROID_SDK`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, `~/Library/Application Support/Collie/android-sdk`; vale o primeiro que **parece SDK** (contém `platform-tools`, `emulator`, `cmdline-tools` ou `system-images`); se nenhum, vale o do Collie e o install o cria.
- Java: `COLLIE_JAVA_HOME`; JDK do Android Studio (`/Applications/Android Studio.app/Contents/jbr/Contents/Home`); `/usr/libexec/java_home` (versão 17 ou maior); JDK próprio em `~/Library/Application Support/Collie/jdk` (Temurin 21, aarch64, macOS), baixado só se o `sdkmanager` falhar por versão de classe ou se não houver nenhum.
- Hosts permitidos nos downloads **do Collie**: `dl.google.com`, `api.adoptium.net`, `github.com` (path `/adoptium/`) e `objects.githubusercontent.com`; só `https`, porta padrão, sem credenciais; SHA-256 conferido antes de descompactar. O que o `sdkmanager` baixa na fase 2 é do Google e o Collie não o controla.
- Duas fases: **Preparar** (JDK se preciso + `cmdline-tools`) no clique em Instalar; **Instalar** (`platform-tools`, `emulator`, imagem) só com as licenças aceitas. Um trabalho por vez (`busy`). Recusa se houver outro `sdkmanager` ou o Android Studio rodando.
- Staging em `<sdk>/.collie-staging/`; mover só depois de conferido; cancelar apaga só o staging, nunca algo que já existia. Espaço livre exigido: 2× a soma dos downloads, no volume do SDK.
- Imagem: maior API estável com `google_apis;arm64-v8a` segundo `sdkmanager --list`; "pronta" aceita qualquer `google_apis*` arm64 já instalada. Só Apple Silicon (erro claro em Intel).
- Comandos `android.status|licenses|install|cancel`: só admin, `exposedToMCP: false`. Nenhum `--accept-all`.
- Testes só com `--filter`, nunca `swift test` inteiro; nunca rede nem SDK real nos testes; `sdkmanager` e downloader falsos. Validar em worktree isolada (`git worktree add --detach <tmp> HEAD`, `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>`). Sem push, sem instalar o app. Commits por tarefa só com os arquivos da tarefa, terminando com `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- `ANDROID_HOME` apontando para pasta vazia ou velha: é pulado, não escolhido.
- SDK do Studio com `cmdline-tools/<versão>` e sem `latest`: conta como pronto, e o install não cria `latest`.
- Disco cheio no meio da fase 2: erro `failed` com o item, staging limpo, nada pela metade no SDK.
- Cancelar durante a fase 1 num SDK do Studio: o `cmdline-tools` que já existia continua intacto.
- Segundo `android.install` com um trabalho em curso: `busy`, sem processo duplicado; o daemon reiniciando não deixa `busy` preso.
- Checksum errado: o arquivo é descartado e nada é descompactado.
- Redirecionamento para fora da lista de hosts: recusado.

---

### Task 1: Funções puras do SDK

**Files:**
- Create: `Sources/CollieDevice/AndroidSdk.swift`
- Test: `Tests/CollieDeviceTests/AndroidSdkTests.swift`

**Interfaces:**
- Produces:
  - `enum AndroidSdk`
  - `static func looksLikeSdk(_ dir: String, exists: (String) -> Bool) -> Bool`
  - `static func resolve(env: [String: String], home: String, colliePath: String, exists: (String) -> Bool) -> (path: String, source: String)` (`source`: `env`, `android-home`, `android-sdk-root`, `studio`, `collie`)
  - `static func sdkmanager(in sdk: String, exists: (String) -> Bool) -> String?` (prefere `cmdline-tools/latest/bin/sdkmanager`, senão a versão numerada de maior número)
  - `static func parseImages(_ listOutput: String) -> [String]` (pacotes `system-images;android-N;google_apis;arm64-v8a` de `sdkmanager --list`)
  - `static func pickLatestStable(_ packages: [String]) -> String?` (maior API sem sufixo de prévia; nenhum: `nil`)
  - `static func parseProgress(_ line: String) -> (percent: Int, label: String)?`
  - `static func parseLicenses(_ output: String) -> [(id: String, title: String, text: String)]`

- [ ] **Step 1: Testes que falham.** `looksLikeSdkNeedsOneMarker`; `resolvePrefersEnvThenHomeThenCollie`; `resolveSkipsAnEmptyAndroidHome`; `resolveFallsBackToCollieWhenNothingLooksLikeSdk`; `sdkmanagerPrefersLatestThenHighestNumbered`; `parseImagesKeepsOnlyGoogleApisArm64`; `pickLatestStableSkipsPreviews`; `parseProgressReadsPercent` (linha estilo `[=====   ] 45% Downloading emulator...`); `parseLicensesSplitsOnTheSeparatorAndKeepsIds`. As amostras de saída do `sdkmanager` vêm de uma execução real de `sdkmanager --list` e `--licenses` no SDK do usuário (capturar numa pasta temporária; não commitar saída com caminho pessoal).
- [ ] **Step 2: Rodar e ver falhar.** `--filter AndroidSdkTests`; esperado: erro de compilação, `AndroidSdk` indefinido.
- [ ] **Step 3: Implementar** as funções acima em `AndroidSdk.swift`. Sem biblioteca nova; `exists` injetado para os testes sem disco.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(android): pure SDK resolution and sdkmanager parsing`.

### Task 2: Localizadores usam o resolvedor

**Files:**
- Modify: `Sources/CollieDaemonKit/Devices/Emulator.swift` (`locate`), `Adb.swift` (`locate`), `AvdManager.swift` (`locate`)
- Test: `Tests/CollieDaemonKitTests/EmulatorTests.swift`, `AvdManagerTests.swift` (casos novos)

**Interfaces:**
- Consumes: `AndroidSdk.resolve`, `AndroidSdk.sdkmanager`.
- Produces: os três `locate(env:home:)` mantêm a assinatura; o SDK vem de `AndroidSdk.resolve` (com `colliePath = <home>/Library/Application Support/Collie/android-sdk`), e o Java ganha o JDK próprio no fim da ordem. `AvdManager.locate` aceita `cmdline-tools/<versão>`.

- [ ] **Step 1: Testes que falham:** `locateFindsTheCollieSdkWhenNoStudioSdk` (em cada um dos três), `locateIgnoresAnEmptyAndroidHome`, `avdmanagerAcceptsANumberedCmdlineToolsDir`, `javaFallsBackToTheCollieJdk`.
- [ ] **Step 2: Rodar e ver falhar** (`--filter EmulatorTests`, `--filter AvdManagerTests`).
- [ ] **Step 3: Implementar.** `COLLIE_EMULATOR`, `COLLIE_AVDMANAGER` e `COLLIE_JAVA_HOME` continuam tendo prioridade sobre tudo. Os testes existentes não podem mudar de significado.
- [ ] **Step 4: Rodar e ver passar** (as duas suítes inteiras, mais `--filter LiteAvdServiceTests` porque o `createLiteAvd` usa o SDK root).
- [ ] **Step 5: Commit** `feat(android): locators find the reused or Collie SDK`.

### Task 3: Downloader seguro e fase 1 (Preparar)

**Files:**
- Create: `Sources/CollieDaemonKit/Android/AndroidDownload.swift`, `Sources/CollieDaemonKit/Android/AndroidInstaller.swift`
- Test: `Tests/CollieDaemonKitTests/AndroidDownloadTests.swift`, `Tests/CollieDaemonKitTests/AndroidPrepareTests.swift`

**Interfaces:**
- Consumes: `AndroidSdk` (Task 1).
- Produces:
  - `typealias AndroidFetch = @Sendable (_ url: URL, _ to: URL, _ progress: @Sendable (Int64, Int64) -> Void) async throws -> Void` (injetável)
  - `enum AndroidDownload { static func allowed(_ u: URL) -> Bool; static func verify(_ file: URL, sha256: String) throws(ProtocolError) }`
  - `actor AndroidInstaller { init(root: URL, env: [String: String], home: String, fetch: AndroidFetch, runner: …); func prepare() async throws(ProtocolError) }` (fase 1: staging, baixar o zip do `cmdline-tools` pelo catálogo `repository2-*.xml` de `dl.google.com`, conferir SHA-256, descompactar no staging, mover para `cmdline-tools/latest` só se não houver `cmdline-tools` utilizável; JDK próprio só se faltar Java utilizável)

- [ ] **Step 1: Testes que falham:** `allowedHostsOnlyHttps` (aceita os quatro hosts, recusa http, porta, credenciais, host parecido como `dl.google.com.evil.com`); `verifyRejectsABadChecksumAndDeletesTheFile`; `prepareInstallsCmdlineToolsFromTheFakeFetch`; `prepareLeavesAnExistingCmdlineToolsAlone`; `prepareCleansTheStagingOnFailure`; `prepareRefusesIntelHosts`; `prepareIsSkippedWhenEverythingIsThere`.
- [ ] **Step 2: Rodar e ver falhar.**
- [ ] **Step 3: Implementar.** O fetch real usa sessão efêmera, recusa redirecionamento fora da lista e escreve em arquivo (padrão do `GoogleFonts.fetch` em `FontCommands.swift`). Catálogo e URL do JDK: o construtor resolve a URL e o checksum a partir do catálogo do Google e do JSON da API do Adoptium; os testes usam respostas gravadas à mão, sem rede. Descompactar com `/usr/bin/ditto -x -k` (zip) e `tar` (JDK), por `BoundedProcess`.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(android): safe downloader and the prepare phase`.

### Task 4: Fase 2 (licenças e instalação) e estado do trabalho

**Files:**
- Modify: `Sources/CollieDaemonKit/Android/AndroidInstaller.swift`
- Test: `Tests/CollieDaemonKitTests/AndroidInstallTests.swift`

**Interfaces:**
- Consumes: `AndroidSdk.sdkmanager/parseImages/pickLatestStable/parseProgress/parseLicenses`, `AndroidInstaller.prepare`.
- Produces:
  - `func status() async -> AndroidStatus` (`sdk {path,source}`, `items [{id, state ok|missing|installing, detail}]`, `needs: ready|needsPrepare|needsLicense`, `job {phase, item, percent, bytes, total, error}?`, `lite: Bool`)
  - `func licenses() async throws(ProtocolError) -> [License]` (`notReady` antes do `cmdline-tools`; `accepted` por id)
  - `func install(accept ids: [String]) async throws(ProtocolError)` (recusa sem os ids de todas as licenças pendentes; instala `platform-tools`, `emulator` e a imagem por `sdkmanager --sdk_root=<sdk>`, com `JAVA_HOME`; progresso em `status().job`)
  - `func cancel() async` (mata o grupo de processos e apaga só o staging)
  - checagens: `busy` (outro `sdkmanager`/Studio rodando, ou trabalho em curso), espaço livre 2× a soma, `accepted` lido de `<sdk>/licenses/`.

- [ ] **Step 1: Testes que falham**, com `sdkmanager` falso (script que imprime `--list`, `--licenses` e progresso, e grava o que instalaria): `statusReportsMissingItems`; `licensesBeforeCmdlineToolsIsNotReady`; `installRefusesWithoutAcceptedLicenses`; `installRunsTheThreePackagesInOrder`; `installPicksTheNewestStableImage`; `secondInstallWhileRunningIsBusy`; `cancelKillsTheProcessAndKeepsExistingFiles`; `lowDiskFailsBeforeDownloading`; `studioRunningIsBusy`; `alreadyAcceptedLicensesSkipTheStep`.
- [ ] **Step 2: Rodar e ver falhar.**
- [ ] **Step 3: Implementar.** O aceite grava o mesmo arquivo que o `sdkmanager --licenses` grava em `<sdk>/licenses/` (o construtor confere o formato numa execução real, em pasta temporária via `COLLIE_ANDROID_SDK`). Estado do trabalho só em memória.
- [ ] **Step 4: Rodar e ver passar.**
- [ ] **Step 5: Commit** `feat(android): licenses and install phase`.

### Task 5: Comandos `android.*`

**Files:**
- Modify: `Sources/CollieProtocol/Commands.swift` (quatro `CommandSpec`, perto de `font.*`), `Sources/CollieDaemonKit/CommandRouter.swift` (prefixo `android.`; criar o `AndroidInstaller` junto do `DeviceService`)
- Create: `Sources/CollieDaemonKit/AndroidCommands.swift`
- Test: `Tests/CollieDaemonKitTests/AndroidCommandTests.swift`; rodar também `CommandsTests` e `MCPTests`

**Interfaces:**
- Consumes: `AndroidInstaller` (Task 4).
- Produces: `android.status`, `android.licenses`, `android.install` (`--accept` lista de ids; começa a fase 1 e, com ids aceitos e licenças prontas, a fase 2; devolve `{job}`), `android.cancel`. CLI: `collie android status|install|cancel`; `install` imprime uma linha por mudança do `status().job` até acabar.

- [ ] **Step 1: Testes que falham:** `commandsAreAdminOnly` (terminal recebe erro de permissão), `statusReturnsTheContract`, `installWithoutAcceptOnlyPrepares`, `installBusyReturnsBusy`, `helpListsFourCommands`, `commandsAreHiddenFromMCP`.
- [ ] **Step 2: Rodar e ver falhar.**
- [ ] **Step 3: Implementar**, no estilo de `FontCommands.swift` (despacho por prefixo, `principal(r, peer:)` nil = admin). `timeoutSeconds: 10` para `status`, `licenses` e `cancel`; `install` responde logo com `{job}` e continua em tarefa própria.
- [ ] **Step 4: Rodar** `--filter AndroidCommandTests`, `--filter CommandsTests`, `--filter MCPTests` (o `mcpListsTools` já falha no HEAD por `memory_doc-search`; comparar com o HEAD).
- [ ] **Step 5: Commit** `feat(android): android.* commands`.

### Task 6: Prova de ponta a ponta (só com aval do usuário)

Não executar sem o usuário confirmar: baixa algumas centenas de MB e a imagem de mais de 1 GB, e escreve numa pasta temporária.

- [ ] **Step 1:** Subir o daemon isolado (`scripts/dev/run-isolated.sh start`) com `COLLIE_ANDROID_SDK=<pasta temporária>` e `COLLIE_JAVA_HOME` vazio.
- [ ] **Step 2:** `collie android status` (nada instalado) → `collie android install` (fase 1) → `collie android licenses` → `collie android install --accept <ids>` (fase 2) → `collie device lite create`. Esperado: `status` termina em `ready`, `device.list` mostra `avd:collie-lite`.
- [ ] **Step 3:** Confirmar o formato do aceite e o progresso reais; corrigir os parsers da Task 1 se divergirem; registrar o resultado no spec.
- [ ] **Step 4:** Parar o daemon, apagar a pasta temporária, commit `docs(android): end-to-end result`.
