# Motor de design (figcraft) baixável Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O dmg do Collie sai sem o figcraft; o daemon baixa, confere (sha256 fixado + assinatura do time) e instala o
motor em `<root>/figcraft` quando o usuário clica em Preferências › Desenho, e o painel Design e `collie design *`
mandam baixar em vez de dar erro.

**Architecture:** Um pin (`Resources/figcraft-engine.json`) dentro do bundle selado diz versão, URL, tamanho, sha256 e
team ID. `FigcraftEngine` (função pura) escolhe o diretório (env → App Support → bundle → vendor em DEBUG);
`FigcraftServer`/`DesignService` resolvem o motor por closure a cada subida; `FigcraftInstaller` (actor, no molde do
`AndroidInstaller`) baixa num staging, confere, extrai, troca por rename e recarrega. Comandos `design.engine.*` só do
app; um workflow próprio publica o asset.

**Tech Stack:** Swift 6.2 (CollieCore, CollieDaemonKit, CollieProtocol, ColliePlugins, CollieApp, collie CLI),
Security.framework (`SecStaticCode`), CryptoKit, Swift Testing, bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-16-figcraft-download-design.md`

## Global Constraints

- Testes: só os criados/alterados, com `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>` numa
  worktree `--detach`. **Nunca** a suíte inteira. `MCPTests.mcpListsTools` já falha (`memory_doc-search`): se rodar,
  confirme que continua sendo a única falha.
- **Não**: instalar ou reiniciar o app, rodar `scripts/bundle-app.sh`, `scripts/release.sh` ou
  `scripts/build-figcraft.sh`, dar push, disparar workflow (`gh workflow run`), criar tag ou release (`git tag`,
  `gh release`), fazer download real de rede nos testes.
- Tarefas de CI (Task 7 e 8, partes de script/workflow): **só validam com `bash -n` e `actionlint`** (se `actionlint`
  não estiver instalado, avise; não instale sem perguntar). O teste real é no GitHub e é passo do dono.
- Commit por task, só dos seus arquivos (`git diff <arquivo>` antes de `git add`), trailer
  `Co-Authored-By: <seu modelo real> <noreply@anthropic.com>`. Não editar `.collie/`, `docs/pages`, nem arquivos não
  rastreados de outros.
- Valores do spec: versão `0.7.0-c<N>`, primeira `0.7.0-c1`; tag `figcraft-v<version>`; asset
  `figcraft-<version>-arm64.tar.gz`; release `--prerelease --latest=false`; diretório `<root>/figcraft`, staging
  `<root>/.figcraft-staging`, anterior `<root>/.figcraft-old`; espaço livre ≥ 3 × `size`; host `github.com` só sob
  `/ysraelmoreno/collie/releases/download/figcraft-v`; requisito
  `anchor apple generic and certificate leaf[subject.OU] = "<teamId>"`; poll de status 0,5 s; espera por `hold` ≤ 60 s.
- Textos (pt-BR, exatos): "Motor de design não instalado. Baixe em Preferências › Desenho (collie design engine
  install)"; "O arquivo baixado não confere (sha256). Nada foi instalado."; "Espaço insuficiente"; "Motor alterado,
  baixe de novo"; botão "Baixar motor de design (<MB> MB)" / "Baixar (<MB> MB)"; "Os painéis Design abertos vão
  reconectar."; confirmação de Remover "Os arquivos de design continuam; o painel Design fica indisponível até baixar
  de novo."
- Nunca tocar `<root>/design/` ao instalar, atualizar ou remover. Download só por comando do app (sem MCP).
- Se o plano não bater com o código, pare e pergunte.

## Review Focus

- Daemon morre entre os dois renames (`figcraft` → `.figcraft-old`, staging → `figcraft`): na subida, motor restaurado
  e staging limpo (teste em Task 1 e Task 3).
- Remover/atualizar com painel Design aberto e `figcraft-cli mcp` vivos: clientes fechados, servidor parado, próxima
  chamada sobe o novo; arquivos em `<root>/design/server` intactos (Task 2, Task 3).
- Install durante backup (`hold(true)`): espera, e `busy` passados 60 s; nunca troca com o servidor segurado (Task 3).
- Pin no bundle ausente ou ilegível (build local antigo): `design.engine.status` responde `absent` sem `pinned` e
  `install` falha com mensagem clara, não crasha (Task 1, Task 4).
- App e daemon divergindo no diretório escolhido: os dois usam `FigcraftEngine.resolve` com as mesmas entradas
  (Task 1 testa a regra; Task 6 usa a mesma função).

## File Structure

- Create `Resources/figcraft-engine.json`: o pin (Task 1; `sha256`/`size` provisórios até a Task 7 publicar).
- Create `Sources/CollieCore/FigcraftEngine.swift`: `FigcraftPin`, `FigcraftEngine.resolve`, `recover`.
- Modify `Sources/CollieDaemonKit/Design/FigcraftServer.swift`, `Design/DesignService.swift`, `CommandRouter.swift`,
  `Daemon.swift`, `Sources/collied/main.swift`: motor por closure, `reloadEngine`, mensagem nova.
- Create `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift`; modify `Android/AndroidDownload.swift` (allowlist).
- Modify `Sources/CollieDaemonKit/DesignCommands.swift`, `Sources/CollieProtocol/Commands.swift`,
  `Sources/collie/CLI.swift`: `design.engine.*`.
- Create `Sources/CollieApp/DesignEngineModel.swift`; modify `PreferencesView.swift`, `PreferencePage.swift`.
- Modify `Sources/ColliePlugins/DesignPanel.swift`.
- Create `scripts/package-figcraft.sh`, `scripts/ci/signing-keychain.sh`, `.github/workflows/figcraft.yml`; modify
  `.github/workflows/release.yml`, `scripts/release.sh`, `scripts/bundle-app.sh`, `Resources/NOTICE-figcraft`,
  `docs/release.md`.

Ordem e dependências: 1 → 2 → 3 → 4 → (5, 6 em paralelo) ; 7 independente de 2–6 (só precisa do formato do pin da 1);
8 depois de 7 (o passo "Conferir motor" precisa do pin com hash real para passar no GitHub, mas o arquivo se escreve
antes).

---

### Task 1: Pin e resolução do motor

**Files:**
- Create: `Resources/figcraft-engine.json`, `Sources/CollieCore/FigcraftEngine.swift`
- Test: `Tests/CollieCoreTests/FigcraftEngineTests.swift`

**Interfaces:**
- Produces:
  - `public struct FigcraftPin: Codable, Equatable, Sendable { version, figcraft, commit, inputs, url: String; size: Int64; sha256, teamId: String }` + `static func load(_ file: URL) -> FigcraftPin?`
  - `public struct FigcraftEngine: Equatable, Sendable { dir: URL; version: String?; source: Source }`, `enum Source: String, Codable { env, appSupport, bundle, vendor }`
  - `public static func resolve(env: URL?, appSupport: URL, bundle: URL?, vendor: URL?) -> FigcraftEngine?`
  - `public static func isValid(_ dir: URL) -> Bool` (executáveis `bin/figcraft-server`, `bin/figcraft-cli`, arquivo `web/index.html`)
  - `public static func recover(root: URL)` (staging órfão apagado; `.figcraft-old` restaurado se `figcraft` ausente, apagado se presente)
  - `public enum EngineState: Equatable { case absent, installed(FigcraftEngine), updateAvailable(FigcraftEngine, pinned: String) }` e `static func state(_ e: FigcraftEngine?, pin: FigcraftPin?) -> EngineState`

- [ ] **Step 1: Write the failing tests** em `FigcraftEngineTests` (dirs falsos em temp, executáveis com `chmod 755`): `envWinsWithoutVersionCheck`; `appSupportBeforeBundle`; `invalidAppSupportFallsBackToBundle` (sem `web/index.html`); `noneIsNil`; `versionReadFromEngineJson` (`{"version":"0.7.0-c1"}` → `"0.7.0-c1"`; bundle sem `engine.json` → `nil`); `stateUpdateAvailableWhenVersionDiffers` (`installed 0.7.0-c1`, pin `0.8.0-c1` → `.updateAvailable`); `stateInstalledWhenEqual`; `pinLoadsShippedFile` (`Resources/figcraft-engine.json` decodifica, `url` começa com `https://github.com/ysraelmoreno/collie/releases/download/figcraft-v`); `recoverRestoresOld`; `recoverDropsOldWhenCurrentPresent`; `recoverRemovesStaging`.
- [ ] **Step 2: Run** `--filter FigcraftEngineTests`. Expected: FAIL (tipos não existem).
- [ ] **Step 3: Implement.** Pin com `version: "0.7.0-c1"`, `figcraft: "v0.7.0"`, `commit` do `build-figcraft.sh`, `inputs` = `cat scripts/build-figcraft.sh patches/figcraft/*.patch | shasum -a 256` (mesma ordem que o workflow usará), `sha256` = 64 zeros e `size: 0` provisórios (a Task 7 troca), `teamId` = o OU do certificado Developer ID (pegue com `security find-identity -v -p codesigning`; se não houver, `"TEAMID"` e avise). `vendor` só é passado em DEBUG pelos chamadores.
- [ ] **Step 4: Run** `--filter FigcraftEngineTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): figcraft engine pin and resolution`.

### Task 2: Servidor e clientes com motor resolvido + `reloadEngine`

**Files:**
- Modify: `Sources/CollieDaemonKit/Design/FigcraftServer.swift:12-48`, `Design/DesignService.swift:67-75`, `CommandRouter.swift:178-184`, `Daemon.swift:67-68`, `Sources/collied/main.swift:72-82`
- Test: `Tests/CollieDaemonKitTests/FigcraftServerTests.swift`, `Tests/CollieDaemonKitTests/DesignCommandTests.swift`

**Interfaces:**
- Consumes: `FigcraftEngine.resolve`, `FigcraftPin.load`, `FigcraftEngine.recover` (Task 1).
- Produces:
  - `DaemonConfig.figcraftEngine: @Sendable () -> FigcraftEngine?` (substitui `figcraftDir`; `main.swift` monta com `env: COLLIE_FIGCRAFT_DIR`, `appSupport: <root>/figcraft`, `bundle: <Helpers>/../Resources/figcraft`, `vendor: nil`) e `DaemonConfig.figcraftPin: FigcraftPin?` (de `COLLIE_FIGCRAFT_PIN` ou `<Helpers>/../Resources/figcraft-engine.json`)
  - `FigcraftServer.init(engine: @escaping @Sendable () -> URL?, dataDir:runDir:port:env:)`; binário = `engine()/bin/figcraft-server` lido em `ensureRunning`/`start`
  - `FigcraftServer.notInstalled: ProtocolError` (`.unavailable`, texto da Global Constraints; substitui `notBundled`)
  - `DesignService.init(server:engine:root:runDir:idle:timeoutCap:)`; CLI = `engine()/bin/figcraft-cli` por cliente novo
  - `CommandRouter.reloadEngine() async` = `design.stop()` e depois `figcraft.stop()`
  - Requisito de assinatura a cada subida (spec §4): `FigcraftServer` recebe `verify: @Sendable (URL) -> Bool` (padrão: sempre `true` quando `source != .appSupport`; para App Support chama o checador da Task 3, injetado pelo `CommandRouter`); falhou → `ProtocolError(.unavailable, "Motor alterado, baixe de novo")`.

- [ ] **Step 1: Write the failing tests:** em `FigcraftServerTests`, `missingEngineSaysNotInstalled` (closure → `nil`; erro com a mensagem exata), `engineSwapsAfterStop` (closure aponta para o fake A, sobe, troca para um fake B que grava outro marcador no log, `stop()`, `ensureRunning` → log mostra B), `failedVerifySaysAltered`. Em `DesignCommandTests`, `reloadEngineClosesClientsAndKeepsDesignData` (cliente aberto, arquivo em `<root>/design/server`; `reloadEngine()`; cliente fechado, arquivo existe).
- [ ] **Step 2: Run** `--filter FigcraftServerTests` e `--filter DesignCommandTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `main.swift` chama `FigcraftEngine.recover(root:)` antes de montar o config. Atualize os testes existentes que passam `binary:` para a closure (mesma semântica).
- [ ] **Step 4: Run** os dois filtros + `swift build --disable-sandbox --product collied` (código de saída à parte). Expected: PASS, build ok.
- [ ] **Step 5: Commit** `refactor(design): resolve the figcraft engine per start, add reloadEngine`.

### Task 3: `FigcraftInstaller`

**Files:**
- Create: `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift`
- Modify: `Sources/CollieDaemonKit/Android/AndroidDownload.swift:13-26` (allowlist)
- Test: `Tests/CollieDaemonKitTests/FigcraftInstallerTests.swift`, `Tests/CollieDaemonKitTests/AndroidDownloadTests.swift`

**Interfaces:**
- Consumes: `FigcraftPin`, `FigcraftEngine.isValid`, `AndroidFetch`, `AndroidDownload.verify(_:sha256:)`, `CommandRouter.reloadEngine` (passado como closure), `FigcraftServer.hold` (estado lido por closure `held: () async -> Bool`).
- Produces:
  - `actor FigcraftInstaller { init(root: URL, pin: FigcraftPin?, fetch: AndroidFetch = AndroidDownload.fetch, signature: @escaping @Sendable (URL, String) -> Bool = FigcraftInstaller.signedByTeam, freeSpace: @escaping @Sendable (String) -> Int64? = AndroidInstaller.free, held: @escaping @Sendable () async -> Bool, reload: @escaping @Sendable () async -> Void) }`
  - `struct Job: Codable, Sendable, Equatable { phase: String /* downloading|verifying|installing|done|failed|cancelled */; bytes: Int64; total: Int64; error: String? }`
  - `func install() throws(ProtocolError) -> Job` (começa a Task e responde na hora), `func cancel()`, `func remove() async throws(ProtocolError)`, `var job: Job?`
  - `static func signedByTeam(_ binary: URL, _ teamId: String) -> Bool` (`SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString` + `SecStaticCodeCheckValidityWithErrors` com `kSecCSStrictValidate`)
  - `AndroidDownload.allowed` aceita `github.com` sob `/ysraelmoreno/collie/releases/download/figcraft-v` (além de `/adoptium/`), sem `..`.

- [ ] **Step 1: Write the failing tests** (fetch falso escreve um `tar.gz` montado no próprio teste com `/usr/bin/tar`, binários = scripts `#!/bin/sh` executáveis; `signature` injetado): `installsAndReloads` (fase `done`, `<root>/figcraft/bin/figcraft-server` existe, `reload` chamado 1×, staging some); `badShaExtractsNothing` (job `failed`, erro exato da Global Constraints, `<root>/figcraft` anterior intacto, staging some, `fetch` chamado 1× — sem retry); `wrongTeamFails` (`signature` → `false`; nada trocado); `layoutMismatchFails` (`engine.json.version` ≠ pin); `cancelMidDownload` (fetch espera; `cancel()`; fase `cancelled`, staging some); `lowSpaceRefuses` (`freeSpace` < 3 × size → "Espaço insuficiente", `fetch` nunca chamado); `waitsForHoldThenBusy` (`held` sempre `true`; relógio curto injetado ou espera de teste → `busy`); `removeKeepsDesignData` (`<root>/design/x` existe antes e depois; `reload` chamado antes de apagar); `noPinFails` (`pin: nil` → `.unavailable`); `stripsQuarantine` (arquivo com `xattr -w com.apple.quarantine` no tar extraído → sem o atributo após instalar). Em `AndroidDownloadTests`: `allowsFigcraftReleasePath`, `refusesOtherCollieReleasePaths` (`/ysraelmoreno/collie/releases/download/v0.1.0/…` → `false`).
- [ ] **Step 2: Run** `--filter FigcraftInstallerTests` e `--filter AndroidDownloadTests`. Expected: FAIL.
- [ ] **Step 3: Implement** a sequência do spec §3 (passos 2–9) na ordem, sha256 antes de extrair, `/usr/bin/tar -xzf` via `BoundedProcess`, `removexattr`/`xattr -dr com.apple.quarantine`, os dois renames; na falha, staging removido e nada fora dele tocado. No `CommandRouter`, passe
  `{ FigcraftInstaller.signedByTeam($0, pin.teamId) }` como `verify` do `FigcraftServer` (Task 2) para motores de App Support.
- [ ] **Step 4: Run** os dois filtros. Expected: PASS.
- [ ] **Step 5: Commit** `feat(design): download, verify and install the figcraft engine`.

### Task 4: Comandos `design.engine.*` e CLI

**Files:**
- Modify: `Sources/CollieProtocol/Commands.swift` (perto de `android.*`, linha ~473), `Sources/CollieDaemonKit/DesignCommands.swift`, `Sources/CollieDaemonKit/CommandRouter.swift` (instancia `FigcraftInstaller`; rota), `Sources/collie/CLI.swift:54,100`
- Test: `Tests/CollieDaemonKitTests/DesignEngineCommandTests.swift`

**Interfaces:**
- Consumes: `FigcraftInstaller` (Task 3), `FigcraftEngine.state` (Task 1).
- Produces (todos `exposedToMCP: false`, só admin/app; terminal → `.forbidden`):
  - `design.engine.status` → `{state: "absent"|"installed"|"updateAvailable", installed?: {version, source}, pinned?: {version, size}, job?: Job}`
  - `design.engine.install` → `{job}`; `design.engine.cancel` → `{}`; `design.engine.remove` → `{}` (`busy` com job ativo; `.notFound` quando `source != appSupport`)
  - CLI `collie design engine [status|install|remove]`; `install` segue o job como `followInstall` do Android (uma linha por mudança).

- [ ] **Step 1: Write the failing tests:** `statusAbsentWithPin`, `statusWithoutPinHasNoPinned`, `installFromTerminalIsForbidden`, `notListedInMCP` (nenhum `design.engine.*` em `CommandSpec.all.filter(\.exposedToMCP)`), `removeBundleEngineIsNotFound`, `removeWhileJobIsBusy`. Use o fetch falso da Task 3.
- [ ] **Step 2: Run** `--filter DesignEngineCommandTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `design.engine.` é tratado antes do despacho genérico de `design.` em `DesignCommands.swift`; CLI trata `design.engine.` como `android.` na linha 54 (credencial do app).
- [ ] **Step 4: Run** `--filter DesignEngineCommandTests` + `swift build --disable-sandbox --product collie`. Expected: PASS, build ok.
- [ ] **Step 5: Commit** `feat(design): design.engine status/install/cancel/remove`.

### Task 5: Preferências › Desenho, seção "Motor de design"

**Files:**
- Create: `Sources/CollieApp/DesignEngineModel.swift`
- Modify: `Sources/CollieApp/PreferencesView.swift:57-148` (seção acima de `designSection`; selo), `Sources/CollieApp/PreferencePage.swift` (keywords, `designBadge`)
- Test: `Tests/CollieAppTests/DesignEngineModelTests.swift`, `Tests/CollieAppTests/PreferencePageTests.swift`

**Interfaces:**
- Consumes: resposta de `design.engine.status` (Task 4).
- Produces:
  - `struct DesignEngineStatus: Equatable { static func from(_ v: JSONValue) -> DesignEngineStatus? }` (molde `AndroidSetupStatus`)
  - `enum DesignEngineRow: Equatable { case absent(downloadMB: Int), downloading(doneMB: Int, totalMB: Int), verifying, installed(version: String, bundled: Bool), update(installed: String, available: String, downloadMB: Int), failed(String) }` e `static func row(_ s: DesignEngineStatus) -> DesignEngineRow`
  - `PreferencePage.designBadge(_ s: DesignEngineStatus?) -> String?` (`↓` baixando/verificando/instalando; `!` falha ou atualização)
  - keywords de `.desenho` ganham `"motor baixar instalar remover atualizar"`

- [ ] **Step 1: Write the failing tests:** `rowAbsentShowsDownloadSize` (size 51 400 000 → `downloadMB: 49`, MiB arredondado para cima); `rowDownloadingProgress`; `rowBundledHasNoRemove` (`installed(bundled: true)`); `rowUpdate`; `rowFailedCarriesMessage`; em `PreferencePageTests`: `motorFindsDesenho` (`matching("motor") == [.desenho]`), `designBadgeStates`.
- [ ] **Step 2: Run** `--filter DesignEngineModelTests` e `--filter PreferencePageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** o modelo e a view com o esboço do spec §7 (textos exatos da Global Constraints); poll de 0,5 s só enquanto há job; Remover com `confirmationDialog`. Não use `alert` de sistema bloqueante além desse.
- [ ] **Step 4: Run** os dois filtros + `swift build --disable-sandbox --product CollieApp`. Expected: PASS, build ok.
- [ ] **Step 5: Commit** `feat(app): design engine download in Preferences`.

### Task 6: Painel Design sem motor

**Files:**
- Modify: `Sources/ColliePlugins/DesignPanel.swift:157-170,291-318`
- Test: `Tests/ColliePluginsTests/DesignPanelTests.swift`

**Interfaces:**
- Consumes: `FigcraftEngine.resolve` (Task 1), com `appSupport: Paths.defaultRoot/figcraft` (ou raiz do host), `bundle: Bundle.main.resourceURL/figcraft`, `vendor` só em DEBUG; abrir Preferências na página `.desenho` pelo mesmo caminho que o app já usa para abrir Preferências (procure o chamador existente; se não houver API do host para isso, pare e pergunte).
- Produces: `static func webDirectory() -> URL?` (função, chamada a cada `connect()`); estado "Motor de design não instalado" com botão **Abrir Preferências** no lugar de **Reconectar**; erro `.unavailable` do daemon com o texto de `notInstalled` mostra o mesmo estado.

- [ ] **Step 1: Write the failing tests:** `noEngineShowsInstallState` (`webRoot: nil` → label "Motor de design não instalado", botão "Abrir Preferências"); `engineAppearsAfterInstall` (`webDirectory()` nil, cria dir válido, chama de novo → dir); `daemonNotInstalledErrorShowsInstallState`.
- [ ] **Step 2: Run** `--filter DesignPanelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Remova o texto "Rode scripts/build-figcraft.sh".
- [ ] **Step 4: Run** `--filter DesignPanelTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(design): panel offers the engine download when missing`.

### Task 7: Empacotar e publicar o motor (CI) — só valida com `bash -n` e `actionlint`; o teste real é no GitHub e é passo do dono

**Files:**
- Create: `scripts/package-figcraft.sh`, `scripts/ci/signing-keychain.sh` (o bloco "Signing keychain" do `release.yml` movido para cá, mesmas variáveis), `.github/workflows/figcraft.yml`
- Modify: `Resources/NOTICE-figcraft` (texto "baixado sob pedido para `<root>/figcraft/`"), `docs/release.md` (seção "Motor de design")

**Interfaces:**
- Consumes: `Resources/figcraft-engine.json` (Task 1), `vendor/figcraft/` (saída do `build-figcraft.sh`).
- Produces: `scripts/package-figcraft.sh <sign-identity>` → assina `bin/*` com `--options runtime --timestamp`, notariza (zip de `bin/`, `notarytool submit` com as mesmas variáveis `COLLIE_NOTARY_*` do `release.sh`), gera `build/figcraft-<version>-arm64.tar.gz` com `figcraft/{bin,web,licenses,NOTICE-figcraft,engine.json}` (`engine.json` = `{version, commit, teamId}`) e `.sha256`; imprime `sha256=` e `size=`. `COLLIE_SKIP_NOTARIZE=1` como no `release.sh`.
- Workflow: `on: push` em `main` com `paths: [scripts/build-figcraft.sh, patches/figcraft/**, Resources/figcraft-engine.json]` + `workflow_dispatch`; `runs-on: macos-26`; `timeout-minutes: 300`; `permissions: contents: write`; passos: ler `version`; `gh release view figcraft-v<version>` existe → sair 0; conferir `inputs` (falha "suba -c<N> e o inputs no pin"); cache de `vendor/figcraft-src/target` e `vendor/figcraft-tools` por `inputs`; rustup como no `release.yml`; `build-figcraft.sh`; `scripts/ci/signing-keychain.sh`; `package-figcraft.sh`; `gh release create figcraft-v<version> --prerelease --latest=false` com o `.tar.gz` e o `.sha256`; nunca `--clobber`; limpar keychain em `if: always()`.

- [ ] **Step 1:** Escreva os três arquivos e as mudanças de texto.
- [ ] **Step 2: Run** `bash -n scripts/package-figcraft.sh scripts/ci/signing-keychain.sh` e `actionlint .github/workflows/figcraft.yml`. Expected: sem saída, código 0. Não rode os scripts.
- [ ] **Step 3: Commit** `ci(figcraft): separate signed, notarized engine release`.
- [ ] **Passo do dono (fora do executor):** merge na `main` dispara o workflow; com a release publicada, atualizar `sha256`/`size` do pin num commit.

### Task 8: Release do app sem o figcraft — só valida com `bash -n` e `actionlint`; o teste real é no GitHub e é passo do dono

**Files:**
- Modify: `.github/workflows/release.yml:25-56,59-87` (remove cache/build do figcraft; usa `scripts/ci/signing-keychain.sh`; novo passo "Conferir motor"; `timeout-minutes: 120`), `scripts/release.sh` (`COLLIE_BUNDLE_FIGCRAFT=0`; falha se `Contents/Resources/figcraft` existir), `scripts/bundle-app.sh:35-42` (copia `Resources/figcraft-engine.json` sempre; motor só se `vendor/figcraft` existe e `COLLIE_BUNDLE_FIGCRAFT` ≠ `0`; aviso vira nota "motor fica para download"), `docs/release.md`

**Interfaces:**
- Consumes: pin (Task 1), `scripts/ci/signing-keychain.sh` (Task 7).
- Produces: passo "Conferir motor": `curl -fsSL --retry 3` da `url` do pin para `$RUNNER_TEMP`, `shasum -a 256 -c` contra o `sha256` do pin; falha "motor fixado não publicado ou hash diferente". Nota de release ganha a linha: "O motor de design não vem mais no dmg: baixe em Preferências › Desenho."

- [ ] **Step 1:** Edite os quatro arquivos.
- [ ] **Step 2: Run** `bash -n scripts/release.sh scripts/bundle-app.sh` e `actionlint .github/workflows/release.yml`. Expected: código 0. Não rode `bundle-app.sh` nem `release.sh`.
- [ ] **Step 3: Commit** `ci(release): ship the app without figcraft, check the pinned engine`.
- [ ] **Passo do dono:** `workflow_dispatch` com uma tag de teste depois da Task 7 publicada; conferir que o dmg não tem `Contents/Resources/figcraft` e tem ~50 MB; depois, com app de release instalado, Baixar/Remover/Baixar e `xattr -l` + `codesign -dv` nos binários de `<root>/figcraft` (confirma spec §4).
