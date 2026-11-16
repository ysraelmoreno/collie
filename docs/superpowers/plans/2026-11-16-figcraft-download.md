# Motor de design (figcraft) baixável Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O dmg do Collie sai sem o figcraft; o daemon baixa, confere (sha256 fixado + assinatura Developer ID
Application do time com identificador) e instala o motor em `<root>/figcraft` quando o usuário clica em
Preferências › Desenho e sandbox; painel Design, `collie design *` e a orientação dos agentes mandam baixar em vez de
dar erro.

**Architecture:** Um pin (`Resources/figcraft-engine.json`) no bundle diz versão, URL, tamanhos, sha256 e team ID.
`FigcraftEngine` (função pura, daemon) escolhe o diretório; só o daemon resolve e devolve o `web` no `design.link`.
`FigcraftServer`/`DesignService` resolvem o motor por subida e trocam sob `hold` com `renamex_np(RENAME_SWAP)`;
`FigcraftInstaller` (actor) baixa num staging, confere, extrai, troca. Comandos `design.engine.*` com rota própria
`adminOnly`; um workflow próprio publica o asset (draft → publish).

**Tech Stack:** Swift 6.2 (CollieDaemonKit, CollieProtocol, ColliePlugins, CollieApp, collie CLI, collied),
Security.framework (`SecStaticCode`), CryptoKit, Darwin (`renamex_np`), Swift Testing, bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-16-figcraft-download-design.md`

## Global Constraints

- Testes: só os criados/alterados, com `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>` numa
  worktree `--detach`. **Nunca** a suíte inteira. `MCPTests.mcpListsTools` já falha (`memory_doc-search`): se rodar,
  confirme que continua sendo a única falha.
- **Não**: instalar ou reiniciar o app, rodar `scripts/bundle-app.sh`, `scripts/release.sh` ou
  `scripts/build-figcraft.sh`, dar push, disparar workflow (`gh workflow run`), criar tag ou release (`git tag`,
  `gh release`), fazer download real de rede nos testes.
- Tarefas de CI (Task 7 e 8): **só validam com `bash -n` e `actionlint`** (sem `actionlint` instalado: avise; não
  instale sem perguntar). O teste real é no GitHub e é **passo do dono**.
- **Pendente do dono** (spec, seção própria): P1 (motor desatualizado usável × bloquear se ≠ pin) e P2 (ordem App
  Support → bundle × bundle primeiro). Passos marcados **[depende da decisão P1/P2]** seguem a decisão aprovada atual
  (usável; App Support → bundle) a menos que o dono mude antes; se mudar, siga a variante indicada no passo.
- Commit por task, só dos seus arquivos (`git diff <arquivo>` antes de `git add`; confira hunks alheios), trailer
  `Co-Authored-By: <seu modelo real> <noreply@anthropic.com>`. Não editar `.collie/`, `docs/pages`, nem arquivos não
  rastreados de outros.
- Valores do spec: versão `0.7.0-c<N>`, primeira `0.7.0-c1`; tag `figcraft-v<version>`; asset
  `figcraft-<version>-arm64.tar.gz`; release `--draft --prerelease --latest=false`, publicada por último; diretório
  `<root>/figcraft`, staging `<root>/.figcraft-staging`; espaço livre ≥ `size + unpackedSize + 100 MB`; host
  `github.com` só sob `/ysraelmoreno/collie/releases/download/figcraft-v`; espera pelo backup ≤ 60 s; poll da página
  1 s com job / 3 s sem; selo no laço de 5 s existente; tamanhos com `ByteCountFormatter` `.file` (MB decimais).
- Requisito de assinatura (por binário, `<id>` = `figcraft-server` ou `figcraft-cli`), flags
  `kSecCSStrictValidate | kSecCSCheckAllArchitectures`:
  `identifier "<id>" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "<teamId>"`
- Textos (pt-BR, exatos): admin "Motor de design não instalado. Baixe em Preferências › Desenho e sandbox (collie
  design engine install)"; terminal "Motor de design não instalado: peça ao usuário para baixá-lo em Preferências ›
  Desenho e sandbox do Collie."; "O arquivo baixado não confere (sha256). Nada foi instalado."; "Espaço
  insuficiente"; "Motor alterado, baixe de novo"; "motor de design sendo trocado, tente de novo"; "backup em
  andamento"; botão "Baixar (<tamanho>)"; "Os painéis Design abertos vão reconectar."; confirmação de Remover "Os
  arquivos de design continuam; o painel Design fica indisponível até baixar de novo."
- Nunca tocar `<root>/design/`. Download só por comando do app (rota `adminOnly`, fora do MCP).
- Se o plano não bater com o código, pare e pergunte.

## Review Focus

- Daemon morre no meio da troca: com `RENAME_SWAP` nunca há instante sem motor; na subida o staging (lado
  descartável) é apagado (Task 1 e Task 3 testam).
- Trocar/remover com painel Design aberto e `figcraft-cli mcp` vivos: clientes fechados, servidor parado sob `hold`,
  `ensureRunning` durante o `hold` não cai para o bundle, `commandList` relido, `<root>/design/server` intacto (Task 2).
- Install durante backup: espera ≤ 60 s, depois `busy`; `remove` durante `hold` → `busy` (Task 3).
- Pin ausente/ilegível no bundle (build local antigo): `status` sem `pinned`, `install` falha claro (Task 1, Task 4).
- Terminal chamando `design.engine.install` direto pelo socket (sem MCP): recusado por `adminOnly` (Task 4).

## File Structure

- Create `Resources/figcraft-engine.json` (Task 1; `sha256`/`size`/`unpackedSize`/`inputs` provisórios até a Task 7).
- Create `Sources/CollieDaemonKit/Design/FigcraftEngine.swift`: `FigcraftPin`, `FigcraftEngine`, `EngineState`.
- Modify `Sources/CollieDaemonKit/Design/FigcraftServer.swift`, `Design/DesignService.swift`, `CommandRouter.swift`,
  `Daemon.swift`, `DataBackup.swift`, `CollieOrientation.swift`, `Sources/collied/main.swift`.
- Create `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift`; modify `Android/AndroidDownload.swift` (allowlist).
- Create `Sources/CollieDaemonKit/DesignEngineCommands.swift`; modify `Sources/CollieProtocol/Commands.swift`,
  `Sources/collie/CLI.swift`.
- Create `Sources/CollieApp/DesignEngineModel.swift`, `Sources/CollieApp/DesignEnginePreferences.swift`; modify
  `PreferencesView.swift`, `PreferencePage.swift`.
- Modify `Sources/ColliePlugins/DesignPanel.swift`.
- Create `scripts/figcraft-inputs.sh`, `scripts/package-figcraft.sh`, `scripts/ci/signing-keychain.sh`,
  `.github/workflows/figcraft.yml`; modify `.github/workflows/release.yml`, `scripts/release.sh`,
  `scripts/bundle-app.sh`, `Resources/NOTICE-figcraft`, `docs/release.md`.

Ordem e dependências: 1 → 2 → 3 → 4 → (5, 6 em paralelo). 7 depende só da 1 (formato do pin). 8 depois da 7
(script de keychain compartilhado; o "Conferir motor" só passa no GitHub com o pin real).

---

### Task 1: Pin e resolução do motor — [depende da decisão P1/P2]

**Files:**
- Create: `Resources/figcraft-engine.json`, `Sources/CollieDaemonKit/Design/FigcraftEngine.swift`
- Test: `Tests/CollieDaemonKitTests/FigcraftEngineTests.swift`

**Interfaces:**
- Produces:
  - `struct FigcraftPin: Codable, Equatable, Sendable { version, figcraft, commit, inputs, url: String; size, unpackedSize: Int64; sha256, teamId: String }` + `static func load(_ file: URL) -> FigcraftPin?`
  - `struct FigcraftEngine: Equatable, Sendable { dir: URL; version: String?; source: Source }`, `enum Source: String, Codable { env, appSupport, bundle, vendor }`; `var web: URL { dir/web }`
  - `static func resolve(env: URL?, appSupport: URL, bundle: URL?, vendor: URL?) -> FigcraftEngine?`
  - `static func isValid(_ dir: URL) -> Bool` (executáveis `bin/figcraft-server`, `bin/figcraft-cli`; arquivo `web/index.html`)
  - `static func cleanStaging(root: URL)` (apaga `<root>/.figcraft-staging`)
  - `enum EngineState: Equatable { case absent, installed(FigcraftEngine), updateAvailable(FigcraftEngine, pinned: String) }`; `static func state(_ e: FigcraftEngine?, pin: FigcraftPin?) -> EngineState`

- [ ] **Step 1: Write the failing tests** em `FigcraftEngineTests` (dirs falsos em temp, executáveis `chmod 755`): `envWinsWithoutVersionCheck`; `appSupportBeforeBundle` **[P2: se o dono escolher "bundle vence", o teste vira `bundleBeforeAppSupport`]**; `invalidAppSupportFallsBackToBundle` (sem `web/index.html`); `noneIsNil`; `versionReadFromEngineJson` (`{"version":"0.7.0-c1"}` → `"0.7.0-c1"`; bundle sem `engine.json` → `nil`); `stateUpdateAvailableWhenVersionDiffers` **[P1: se o dono escolher bloquear, `state` ganha `case needsUpdate` e App Support ≠ pin nunca é `installed`]**; `stateInstalledWhenEqual`; `pinLoadsShippedFile` (`Resources/figcraft-engine.json` decodifica, `url` começa com `https://github.com/ysraelmoreno/collie/releases/download/figcraft-v`, `teamId` não vazio); `cleanStagingRemovesIt`.
- [ ] **Step 2: Run** `--filter FigcraftEngineTests`. Expected: FAIL (tipos não existem).
- [ ] **Step 3: Implement.** Pin com `version: "0.7.0-c1"`, `figcraft: "v0.7.0"`, `commit` do `build-figcraft.sh`, `inputs`/`sha256` = 64 zeros, `size`/`unpackedSize` = 0 (a Task 7 e o dono preenchem), `teamId` = OU do Developer ID (`security find-identity -v -p codesigning`; se não houver, `"TEAMID"` e avise).
- [ ] **Step 4: Run** `--filter FigcraftEngineTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(design): figcraft engine pin and resolution`.

### Task 2: Servidor e clientes com motor resolvido, troca sob `hold`, mensagens e orientação — [depende da decisão P1]

**Files:**
- Modify: `Sources/CollieDaemonKit/Design/FigcraftServer.swift:12-48`, `Design/DesignService.swift:58-75,360-370,400-410,724`, `CommandRouter.swift:178-184`, `Daemon.swift:67-68`, `DataBackup.swift:77,95`, `CollieOrientation.swift:20-40,94-104` (+ o chamador de `CollieOrientation.text`), `Sources/collied/main.swift:72-82`
- Test: `Tests/CollieDaemonKitTests/FigcraftServerTests.swift`, `DesignCommandTests.swift`, `CollieOrientationTests.swift`

**Interfaces:**
- Consumes: `FigcraftEngine`, `FigcraftPin.load`, `FigcraftEngine.cleanStaging` (Task 1).
- Produces:
  - `DaemonConfig.figcraftEngine: @Sendable () -> FigcraftEngine?` (substitui `figcraftDir`; `main.swift` monta com `env: COLLIE_FIGCRAFT_DIR`, `appSupport: <root>/figcraft`, `bundle: <Helpers>/../Resources/figcraft`, `vendor:` só `#if DEBUG`) e `DaemonConfig.figcraftPin: FigcraftPin?` (bundle; `COLLIE_FIGCRAFT_PIN` só `#if DEBUG`). `main.swift` chama `cleanStaging(root:)` antes de montar.
  - `FigcraftServer.init(engine: @escaping @Sendable () -> FigcraftEngine?, verify: @escaping @Sendable (FigcraftEngine) -> Bool = { _ in true }, dataDir:runDir:port:env:)`; o motor é resolvido em `start()` e exposto como `var engine: FigcraftEngine? { get }` (o do processo em execução).
  - `hold` vira contagem: `func hold() async`, `func release() async`, `var isHeld: Bool`; com `isHeld`, `ensureRunning` lança `.unavailable` "motor de design sendo trocado, tente de novo" (backup mantém "backup em andamento" pelo motivo passado: `hold(reason: String)`). `DataBackup` passa a usar `hold(reason:)`/`release()`.
  - `FigcraftServer.notInstalled(admin: Bool) -> ProtocolError` (`.unavailable`, os dois textos da Global Constraints; substitui `notBundled`). `verify` falhou → `.unavailable` "Motor alterado, baixe de novo".
  - `DesignService.init(server:root:runDir:idle:timeoutCap:)`: CLI de cada cliente novo = `await server.engine?.dir/bin/figcraft-cli` (nunca outro build). `func resetCaches()` zera `commandList` (e qualquer outro cache por build).
  - `CommandRouter.swapEngine(_ swap: () throws -> Void) async throws(ProtocolError)`: espera `!backupHeld` ≤ 60 s (senão `busy` "backup em andamento") → `figcraft.hold(reason:"swap")` → `design.stop()` → `figcraft.stop()` → `swap()` → `design.resetCaches()` → `figcraft.release()`.
  - `design.link` responde `{editLink, web: <engine.web.path>, version}`.
  - `CollieOrientation.text(..., figcraftAvailable: Bool)`: `false` → `.figcraft`/`.ask` usam a linha de `.artifact` + "FigCraft indisponível (motor não instalado); se o usuário quiser FigCraft, peça para baixá-lo em Preferências."

- [ ] **Step 1: Write the failing tests:**
  - `FigcraftServerTests`: `missingEngineSaysNotInstalledForAdmin` e `…ForTerminal` (texto exato); `holdBlocksStartWithoutFallingBack` (motor A em App Support e B no bundle; `hold`; closure passa a ver só B; `ensureRunning` → "motor de design sendo trocado…", log não mostra B); `swapUnderHoldStartsNewEngine` (fake A → `swapEngine` troca para fake B → próxima chamada mostra B no log); `failedVerifySaysAltered`; `backupAndSwapHoldsAreIndependent` (dois `hold`, um `release` → ainda segurado).
  - `DesignCommandTests`: `newClientUsesRunningServerEngine` (servidor de A rodando; closure passa a apontar para B sem troca; cliente novo usa o CLI de A); `swapClosesClientsResetsCommandListKeepsData` (`design.help` uma vez com fake A; `swapEngine`; `design.help` relê com B; arquivo em `<root>/design/server` existe); `linkCarriesWebDir`.
  - `CollieOrientationTests`: `figcraftPreferredButMissingFallsBackToPage`; `askWithoutEngineFallsBackToPage`.
- [ ] **Step 2: Run** `--filter FigcraftServerTests`, `--filter DesignCommandTests`, `--filter CollieOrientationTests`, `--filter DataBackupTests`. Expected: FAIL nos novos.
- [ ] **Step 3: Implement.** Atualize os testes existentes que passam `binary:` para a closure (mesma semântica). **[P1: se o dono escolher bloquear, `verify` também confere `.collie-installed` (Task 3) contra `pin.sha256` para `source == .appSupport` e falha com "Atualize o motor de design".]**
- [ ] **Step 4: Run** os quatro filtros + `swift build --disable-sandbox --product collied` (código de saída à parte). Expected: PASS, build ok.
- [ ] **Step 5: Commit** `refactor(design): resolve the engine per start, swap under hold, guide agents without it`.

### Task 3: `FigcraftInstaller` — [depende da decisão P1]

**Files:**
- Create: `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift`
- Modify: `Sources/CollieDaemonKit/Android/AndroidDownload.swift:13-26` (allowlist), `CommandRouter.swift` (instancia; `verify` do servidor)
- Test: `Tests/CollieDaemonKitTests/FigcraftInstallerTests.swift`, `Tests/CollieDaemonKitTests/AndroidDownloadTests.swift`

**Interfaces:**
- Consumes: `FigcraftPin`, `FigcraftEngine.isValid` (Task 1); `CommandRouter.swapEngine` (Task 2, passado como closure `swap`); `AndroidFetch`, `AndroidDownload.verify(_:sha256:)`.
- Produces:
  - `actor FigcraftInstaller { init(root: URL, pin: FigcraftPin?, fetch: AndroidFetch = AndroidDownload.fetch, signature: @escaping @Sendable (_ binary: URL, _ identifier: String, _ teamId: String) -> Bool = FigcraftInstaller.signedByTeam, freeSpace: @escaping @Sendable (String) -> Int64? = AndroidInstaller.free, busy: @escaping @Sendable () async -> Bool, swap: @escaping @Sendable (_ op: @Sendable () throws -> Void) async throws(ProtocolError) -> Void) }`
  - `struct Job: Codable, Sendable, Equatable { phase: String /* downloading|verifying|installing|done|failed|cancelled */; bytes: Int64; total: Int64; error: String? }`
  - `func install() -> Job` (com job ativo devolve o mesmo; começa a Task e responde na hora), `func cancel()`, `func remove() async throws(ProtocolError)`, `var job: Job?`
  - `static func signedByTeam(_ binary: URL, _ identifier: String, _ teamId: String) -> Bool` (`SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString` com o requisito da Global Constraints + `SecStaticCodeCheckValidityWithErrors` com as flags)
  - `static func swapInto(root: URL, staged: URL?) throws` (`renamex_np(staged, <root>/figcraft, RENAME_SWAP)` quando os dois existem; `rename` quando só um; `staged == nil` = remover: `<root>/figcraft` → `<root>/.figcraft-staging/old`)
  - `AndroidDownload.allowed` aceita `github.com` sob `/ysraelmoreno/collie/releases/download/figcraft-v`, sem `..`.
  - `CommandRouter` passa `verify: { FigcraftInstaller.signedByTeam(...) }` ao `FigcraftServer` para `source == .appSupport` (os dois binários).

- [ ] **Step 1: Write the failing tests** (fetch falso escreve um `tar.gz` montado no próprio teste com `/usr/bin/tar`; binários = scripts `#!/bin/sh` executáveis; `signature`, `busy` e `swap` injetados; `swap` de teste chama `op` e registra a chamada):
  - `installsWithSwap` (fase `done`, `<root>/figcraft/bin/figcraft-server` existe, `swap` chamado 1×, staging some, `isExcludedFromBackup == true`);
  - `swapReplacesExistingAtomically` (`swapInto` com motor antigo e novo: depois, `<root>/figcraft` é o novo e o antigo está no staging; nunca há chamada a `rename` que deixe `<root>/figcraft` ausente — teste do resultado + `swapInto` sobre dir inexistente usa `rename`);
  - `badShaExtractsNothing` (job `failed`, texto exato, motor anterior intacto, staging some, `fetch` chamado 1×);
  - `rejectsSymlinkInArchive`, `rejectsSetuidInArchive` (tar com link / bit setuid → `failed`, nada trocado);
  - `wrongSignatureFails` (`signature` → `false` para `figcraft-cli` só; nada trocado; `signature` recebeu os identificadores `figcraft-server` e `figcraft-cli` e o `teamId` do pin);
  - `layoutMismatchFails` (`engine.json.version` ≠ pin);
  - `cancelMidDownload` (fetch espera; `cancel()`; fase `cancelled`, staging some);
  - `lowSpaceRefuses` (`freeSpace` = `size + unpackedSize + 100 MB − 1` → "Espaço insuficiente", `fetch` nunca chamado);
  - `concurrentInstallReturnsSameJob`;
  - `removeWhileBusyIsBusy` (`busy` → `true`);
  - `removeKeepsDesignData` (`<root>/design/x` antes e depois; `swap` chamado);
  - `noPinFails` (`pin: nil` → `.unavailable`);
  - `stripsQuarantine` (arquivo com `com.apple.quarantine` no extraído → sem o atributo depois).
  - `AndroidDownloadTests`: `allowsFigcraftReleasePath`, `refusesOtherCollieReleasePaths` (`/ysraelmoreno/collie/releases/download/v0.1.0/…` → `false`), `refusesDotDotInFigcraftPath`.
- [ ] **Step 2: Run** `--filter FigcraftInstallerTests` e `--filter AndroidDownloadTests`. Expected: FAIL.
- [ ] **Step 3: Implement** o spec §3 passos 2–9 na ordem: sha256 antes de extrair; `/usr/bin/tar -xzf` via `BoundedProcess`; varredura (sem symlink, só regular/dir, sem setuid/setgid, `chmod go-w`); layout; assinatura dos dois; `removexattr` de quarentena; `isExcludedFromBackup`; `swap { swapInto(...) }`; apaga staging. Falha → staging removido, nada fora dele tocado. **[P1: se o dono escolher bloquear, grave `<root>/figcraft/.collie-installed` com o `sha256` do asset antes do `swap` e teste `writesInstalledMarker`.]**
- [ ] **Step 4: Run** os dois filtros. Expected: PASS.
- [ ] **Step 5: Commit** `feat(design): download, verify and install the figcraft engine`.

### Task 4: Rota `design.engine.*` (`adminOnly`) e CLI

**Files:**
- Create: `Sources/CollieDaemonKit/DesignEngineCommands.swift`
- Modify: `Sources/CollieProtocol/Commands.swift` (perto de `android.*`, ~473), `Sources/CollieDaemonKit/CommandRouter.swift` (rota ao lado de `android.`, ~359, antes do despacho de plug-ins ~374), `Sources/collie/CLI.swift:54,100-140`
- Test: `Tests/CollieDaemonKitTests/DesignEngineCommandTests.swift`

**Interfaces:**
- Consumes: `FigcraftInstaller` (Task 3), `FigcraftEngine.state`, `FigcraftServer.engine` (Tasks 1–2).
- Produces:
  - `func designEngineCommand(_ r: Request, peer: pid_t) async throws -> JSONValue` começando por `try await adminOnly(r, peer: peer)`; rota `if req.command.hasPrefix("design.engine.")` antes de `PluginRegistry.command`.
  - `design.engine.status` → `{state: "absent"|"installed"|"updateAvailable", installed?: {version, source}, pinned?: {version, size}, job?: Job}`; `design.engine.install` → `{job}`; `design.engine.cancel` → `{}`; `design.engine.remove` → `{}` (`busy` com job/hold; `.notFound` se `source != appSupport`). Todos `exposedToMCP: false`.
  - CLI `collie design engine [status|install|remove]` tratado como `android.` na linha 54 (credencial do app); `install` segue o job como `followInstall`.

- [ ] **Step 1: Write the failing tests:** `terminalIsRefused` (cada um dos quatro comandos vindo de um peer de terminal → erro de `adminOnly`, mesmo código que `AndroidCommandTests` espera); `notListedInMCP` (nenhum `design.engine.*` com `exposedToMCP`); `notRoutedAsPluginCommand` (`PluginRegistry.command("design.engine.status") == nil` ou rota própria alcançada antes); `statusAbsentWithPin`; `statusWithoutPinHasNoPinned`; `removeBundleEngineIsNotFound`; `removeWhileJobIsBusy`. Use o fetch falso da Task 3.
- [ ] **Step 2: Run** `--filter DesignEngineCommandTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `--filter DesignEngineCommandTests` + `swift build --disable-sandbox --product collie`. Expected: PASS, build ok.
- [ ] **Step 5: Commit** `feat(design): admin-only design.engine commands and CLI`.

### Task 5: Preferências › Desenho e sandbox, seção "Motor de design" — [depende da decisão P1]

**Files:**
- Create: `Sources/CollieApp/DesignEngineModel.swift` (decodifica e mapeia), `Sources/CollieApp/DesignEnginePreferences.swift` (view + poll, molde `AndroidPreferences.swift:40-55`)
- Modify: `Sources/CollieApp/PreferencesView.swift:57,82-92,120-148` (seção acima de `designSection`; selo no laço de 5 s), `Sources/CollieApp/PreferencePage.swift` (keywords, `designBadge`)
- Test: `Tests/CollieAppTests/DesignEngineModelTests.swift`, `Tests/CollieAppTests/PreferencePageTests.swift`

**Interfaces:**
- Consumes: resposta de `design.engine.status` (Task 4).
- Produces:
  - `struct DesignEngineStatus: Equatable { static func from(_ v: JSONValue) -> DesignEngineStatus? }`
  - `enum DesignEngineRow: Equatable { case absent(download: String), downloading(done: String, total: String), verifying, installed(version: String, bundled: Bool), update(installed: String, available: String, download: String), failed(String) }` e `static func row(_ s: DesignEngineStatus) -> DesignEngineRow` (tamanhos por `ByteCountFormatter` `.file`, locale injetável para teste)
  - `static func pollInterval(_ s: DesignEngineStatus?) -> Duration` (1 s com job, 3 s sem)
  - `PreferencePage.designBadge(_ s: DesignEngineStatus?) -> String?` (`↓` downloading/verifying/installing; `!` failed ou updateAvailable)
  - keywords de `.desenho` ganham `"motor baixar instalar remover atualizar"`

- [ ] **Step 1: Write the failing tests:** `rowAbsentShowsDownloadSize` (size 51 400 000, locale `pt_BR` → `download == "51,4 MB"`); `rowDownloadingProgress`; `rowBundledHasNoRemove`; `rowUpdate` **[P1: se bloquear, vira `rowNeedsUpdate` com "Atualize o motor de design"]**; `rowFailedCarriesMessage`; `pollIsOneSecondWithJobThreeWithout`; `PreferencePageTests`: `motorFindsDesenho` (`matching("motor") == [.desenho]`), `designBadgeStates`.
- [ ] **Step 2: Run** `--filter DesignEngineModelTests` e `--filter PreferencePageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** a view com o esboço do spec §7 e os textos exatos; Remover com `confirmationDialog`.
- [ ] **Step 4: Run** os dois filtros + `swift build --disable-sandbox --product CollieApp`. Expected: PASS, build ok.
- [ ] **Step 5: Commit** `feat(app): design engine download in Preferences`.

### Task 6: Painel Design sem motor — [depende da decisão P2 só nos testes de origem]

**Files:**
- Modify: `Sources/ColliePlugins/DesignPanel.swift:157-185,291-318` (e o `DesignSchemeHandler`)
- Test: `Tests/ColliePluginsTests/DesignPanelTests.swift`

**Interfaces:**
- Consumes: `design.link` → `{editLink, web, version}` (Task 2); erro `notInstalled` (Task 2).
- Produces: `DesignSchemeHandler` sempre registrado no `init`, com `var root: URL?` (nil → 404); `connect()` põe `root = URL(fileURLWithPath: web)` da resposta antes de `web.load`; remove `webDirectory` e a resolução no app (inclusive o fallback DEBUG para `vendor/`, que passa a ser do daemon). Erro `.unavailable` com o texto `notInstalled` → label "Motor de design não instalado" e botão **Abrir Preferências** (abre Preferências na página `.desenho` pelo mesmo caminho que o app já usa; se o host não expõe isso ao plug-in, pare e pergunte) no lugar de **Reconectar**.

- [ ] **Step 1: Write the failing tests:** `handlerRegisteredWithoutEngine` (painel criado sem motor; depois `connect()` com `design.link` falso devolvendo `web` de um dir de teste → página carrega `index.html` desse dir); `rootComesFromLink` (dois `connect()` com `web` diferentes → serve o segundo); `notInstalledShowsInstallState` (`design.link` falso lança o erro → label e botão exatos); `noScriptHintLeft` (texto "Rode scripts/build-figcraft.sh" não aparece).
- [ ] **Step 2: Run** `--filter DesignPanelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `--filter DesignPanelTests` + `swift build --disable-sandbox --product CollieApp`. Expected: PASS, build ok.
- [ ] **Step 5: Commit** `feat(design): panel serves the daemon's engine and offers the download`.

### Task 7: Insumos, empacotar e publicar o motor (CI) — só valida com `bash -n` e `actionlint`; o teste real é no GitHub e é passo do dono

**Files:**
- Create: `scripts/figcraft-inputs.sh`, `scripts/package-figcraft.sh`, `scripts/ci/signing-keychain.sh` (o bloco "Signing keychain" do `release.yml:63-87` movido para cá, mesmas variáveis), `.github/workflows/figcraft.yml`, `Tests/CollieDaemonKitTests/FigcraftPinInputsTests.swift`
- Modify: `Resources/figcraft-engine.json` (`inputs` real), `Resources/NOTICE-figcraft` (patches 0001–0005 + "baixado sob pedido para `<root>/figcraft/`"), `docs/release.md` (seção "Motor de design")

**Interfaces:**
- Consumes: pin (Task 1), `vendor/figcraft/` (saída do `build-figcraft.sh`, só no CI).
- Produces:
  - `scripts/figcraft-inputs.sh` → imprime o `inputs` (spec §1: `LC_ALL=C`, lista ordenada `scripts/build-figcraft.sh scripts/package-figcraft.sh scripts/figcraft-inputs.sh .github/workflows/figcraft.yml patches/figcraft/*.patch`, linhas `<sha256>  <caminho>`, sha256 do todo).
  - `scripts/package-figcraft.sh <sign-identity>` → assina `bin/*` com `--options runtime --timestamp --identifier <nome>`, notariza (zip de `bin/`; variáveis `COLLIE_NOTARY_*` e `COLLIE_SKIP_NOTARIZE` como `release.sh`), gera `build/figcraft-<version>-arm64.tar.gz` com `COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata` (`figcraft/{bin,web,licenses,NOTICE-figcraft,engine.json}`, `engine.json` = `{version, commit}`) e `.sha256`; imprime `sha256=`, `size=`, `unpackedSize=`.
  - `figcraft.yml`: `on: push` em `main` com `paths` = arquivos do `inputs` + `Resources/figcraft-engine.json`, e `workflow_dispatch`; `runs-on: macos-26`; `timeout-minutes: 300`; `permissions: contents: write`; passos do spec §9 (1 conferir `inputs`; 2 release publicada → baixar e conferir sha256/size do pin, pin com zeros → imprimir e sair 0, diferente → falhar; draft órfão → `gh release delete`; 3 cache só `vendor/figcraft-tools` e `~/.cargo/registry` com `restore-keys`; 4 rustup + `build-figcraft.sh` + keychain + `package-figcraft.sh`; 5 `gh release create --draft --prerelease --latest=false`, upload, conferir o download do asset, `gh release edit --draft=false`; nunca `--clobber`; 6 imprimir valores); limpar keychain em `if: always()`.

- [ ] **Step 1: Write the failing test** `FigcraftPinInputsTests.pinInputsMatchScript` (roda `/bin/bash scripts/figcraft-inputs.sh` a partir da raiz do repo e compara com `FigcraftPin.load(Resources/figcraft-engine.json).inputs`).
- [ ] **Step 2: Run** `--filter FigcraftPinInputsTests`. Expected: FAIL (script não existe).
- [ ] **Step 3:** Escreva os scripts, o workflow e os textos; rode `scripts/figcraft-inputs.sh` (só lê arquivos) e grave o resultado em `inputs` no pin. Não rode `package-figcraft.sh` nem `build-figcraft.sh`.
- [ ] **Step 4: Run** `--filter FigcraftPinInputsTests`, `bash -n scripts/figcraft-inputs.sh scripts/package-figcraft.sh scripts/ci/signing-keychain.sh` e `actionlint .github/workflows/figcraft.yml`. Expected: PASS, código 0.
- [ ] **Step 5: Commit** `ci(figcraft): separate signed, notarized engine release`.
- [ ] **Passo do dono:** merge na `main` dispara o workflow; com a release publicada, preencher `sha256`/`size`/`unpackedSize` no pin num commit (a próxima rodada confere e sai verde).

### Task 8: Release do app sem o figcraft — só valida com `bash -n` e `actionlint`; o teste real é no GitHub e é passo do dono

**Files:**
- Modify: `.github/workflows/release.yml:25-56,63-87` (remove cache/build do figcraft; usa `scripts/ci/signing-keychain.sh`; novo passo "Conferir motor"; `timeout-minutes: 270`, `COLLIE_NOTARY_TIMEOUT` fica 14400), `scripts/release.sh` (`COLLIE_BUNDLE_FIGCRAFT=0`; falha se `Contents/Resources/figcraft` existir), `scripts/bundle-app.sh:35-42` (copia `Resources/figcraft-engine.json` sempre; motor só se `vendor/figcraft` existe e `COLLIE_BUNDLE_FIGCRAFT` ≠ `0`; aviso vira nota "motor fica para download"), `docs/release.md`

**Interfaces:**
- Consumes: pin (Task 1), `scripts/ci/signing-keychain.sh` (Task 7).
- Produces: passo "Conferir motor": `curl -fsSL --retry 3` da `url` do pin para `$RUNNER_TEMP`, `shasum -a 256 -c` contra o `sha256`, extrai e roda `codesign --verify --strict -R='<requisito da Global Constraints com o teamId do pin>'` nos dois binários; falha "motor fixado não publicado, hash ou assinatura diferente". Nota de release ganha: "O motor de design não vem mais no dmg: baixe em Preferências › Desenho e sandbox."

- [ ] **Step 1:** Edite os quatro arquivos.
- [ ] **Step 2: Run** `bash -n scripts/release.sh scripts/bundle-app.sh` e `actionlint .github/workflows/release.yml`. Expected: código 0. Não rode `bundle-app.sh` nem `release.sh`.
- [ ] **Step 3: Commit** `ci(release): ship the app without figcraft, check the pinned engine`.
- [ ] **Passo do dono:** `workflow_dispatch` com uma tag de teste depois da Task 7 publicada; conferir que o dmg não tem `Contents/Resources/figcraft` e medir o tamanho; com o app de release instalado: Baixar, `xattr -l` e `codesign -dv -R='<requisito>'` em `<root>/figcraft/bin/*`, abrir painel Design, Remover, Baixar de novo (é a única prova do checador real de Security.framework).
