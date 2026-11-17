# Atualizador automático do Collie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O Collie descobre uma versão nova pelo `update.json` da release, o daemon baixa e confere o dmg, e o app
troca o `.app` por rename (com conferência pós-troca) e reabre. Reiniciar o serviço é opcional, fica separado e
sempre com confirmação na frente do usuário.

**Architecture:** `UpdateManifest` e `CodeSignature` (CollieCore) são compartilhados por daemon e app.
`UpdateChecker` (actor, daemon) checa, baixa com limite de bytes, confere sha256 e o dmg notarizado do time, e deixa
o dmg em `<root>/.update-staging`. Os comandos `app.update.*` são `adminOnly`. `AppUpdateSwap` (CollieClient)
monta o dmg, copia o app para uma irmã `mkdtemp`, confere, troca com `renamex_np`, confere de novo, guarda o
anterior e relança. O perfil do sandbox nega escrita na irmã. A página "Atualizações" e a folha de instalação ficam
no app.

**Tech Stack:** Swift 6.2 (CollieCore, CollieDaemonKit, CollieProtocol, CollieClient, CollieApp, collie CLI,
collie-ctty), Security.framework (`SecStaticCode`), Darwin (`renamex_np`, `mkdtemp`, `posix_spawn`), Swift Testing,
bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-17-update-downloader-design.md`

## Global Constraints

- Testes: só os criados ou alterados, com `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>`
  numa worktree `git worktree add --detach <tmp> HEAD` (removida no fim). **Nunca** a suíte inteira.
  `MCPTests.mcpListsTools` já falhava antes: se rodar, confirme que continua sendo a única falha.
- **O executor NÃO deve**: instalar, abrir ou reiniciar o app; rodar `scripts/bundle-app.sh`, `scripts/release.sh`
  ou `scripts/dev/reload.sh`; chamar `launchctl` ou `DaemonLauncher.restart/ensureRunning` contra o label real
  `dev.collie.daemon`; tocar no daemon real do dono nem em `~/Library/LaunchAgents`; escrever em `/Applications`;
  dar push; disparar workflow (`gh workflow run`); criar tag ou release (`git tag`, `gh release create/upload`);
  fazer download de rede nos testes; montar dmg real nos testes (o `hdiutil` é injetado).
- Tarefas de CI (Task 10): **só validam com `bash -n` e `actionlint`** (sem `actionlint` instalado: avise e não
  instale sem perguntar). O teste real é no GitHub e é **passo do dono**.
- O que **só dá para validar à mão** fica no "Roteiro manual do dono" (fim do plano) e não é marcado como
  verificado por nenhuma task: TCC/`hdiutil`, Seatbelt no diretório-pai, App Management, troca real em
  `/Applications`, relançamento pelo LaunchServices, requisito `notarized` offline num dmg grampeado.
- Commit por task, só dos seus arquivos (`git diff <arquivo>` antes de `git add`; confira hunks alheios em
  arquivos compartilhados como `Commands.swift`, `CommandRouter.swift`, `CollieApp.swift`). Trailer
  `Co-Authored-By: <seu modelo real> <noreply@anthropic.com>`. Não editar `.collie/`.
- Valores do spec:
  - Manifesto: `https://github.com/ysraelmoreno/collie/releases/latest/download/update.json`, `format: 1`, até
    64 KB; dmg em `https://github.com/ysraelmoreno/collie/releases/download/<tag>/<dmg>`; `tag` casa
    `^v\d+\.\d+\.\d+$` e é `v<version>`; `dmg` = `Collie-<version>.dmg`; `page` =
    `https://github.com/ysraelmoreno/collie/releases/tag/<tag>`; `0 < size ≤ 500_000_000`.
  - Team `AG8JQAH6YB` (constante no app); identificador `dev.collie.app`; Helpers `collied`, `collie`,
    `collie-ctty`.
  - Requisito do `.app` e de cada Helper (`<id>`): o mesmo texto do `FigcraftInstaller.signedByTeam` com
    `identifier "<id>"`, flags `kSecCSStrictValidate | kSecCSCheckAllArchitectures` (+ `kSecCSCheckNestedCode` no
    `.app`). Requisito do dmg: `anchor apple generic and certificate leaf[subject.OU] = "AG8JQAH6YB" and notarized`.
  - `User-Agent: Collie/<versão>`; sessão `.ephemeral`, `urlCache = nil`, `.reloadIgnoringLocalCacheData`.
  - Checagem 60 s após o daemon subir e a cada 12 h; staging `<root>/.update-staging` (0700); irmã
    `mkdtemp("<pasta-mãe>/.Collie-update-XXXXXX")`; espaço `size × 3 + 100 MB` em `<root>` e `size × 3` na
    pasta-mãe do app.
  - Hosts: `github.com` sob `/ysraelmoreno/collie/releases/latest/download/` e
    `/ysraelmoreno/collie/releases/download/v`, sem `..`.
  - Override: `COLLIE_UPDATE_MANIFEST`, só `file://`, em qualquer build, lido pelo daemon.
- Textos (pt-BR, exatos): "Collie <v> disponível · <tamanho>"; "Ver novidades no GitHub"; "Instalar…";
  "Pular esta versão"; "Procurar agora"; "Procurar atualizações automaticamente"; "Baixar em segundo plano";
  "Atualizar só o app — os terminais continuam rodando."; "Atualizar e reiniciar o serviço — fecha os <n>
  terminais."; "Instalar e reabrir"; "Instalar ao sair"; "Esperar e instalar"; "esperando <nomes>…"; "O Collie vai
  fechar e reabrir"; "Mova o Collie para /Applications para atualizar por aqui"; "Baixar o dmg"; "Build local:
  atualize pelos scripts"; "reinicie o serviço para usar isto"; "reinicie o serviço para procurar atualizações";
  "a release mudou durante o download"; "O desenho fica indisponível até baixar o motor <v> (<tamanho>) depois de
  reiniciar o serviço"; "Atualizado para <v>"; "Baixar motor agora"; "Voltar para <v>"; "fonte de teste: <url>";
  "Espaço insuficiente". Tamanhos com `ByteCountFormatter` `.file`.
- Se o plano não bater com o código, pare e pergunte.

## Review Focus

- Agente num terminal escreve na irmã entre a conferência e a troca, ou planta o caminho antes: `mkdtemp` recusa,
  a conferência pós-troca destroca (Task 6, `postSwapCheckFailsSwapsBack`, `siblingNeverReused`) e o perfil nega
  (Task 5).
- Release trocada (`--clobber`) no meio: manifesto novo e dmg 404 não bloqueiam a versão
  (Task 3, `notFoundIsNotRefused`), e sha divergente bloqueia só aquele sha (`shaMismatchRefusesOnlyThatSha`).
- Resposta gigante ou infinita no manifesto ou no dmg: cancela no limite (Task 2, `limitCancels`).
- Daemon antigo com app e CLI novos: comando desconhecido vira "reinicie o serviço para usar isto", nunca trava
  (Task 7).
- App novo que não sobe depois da troca: o anterior continua guardado até a segunda abertura saudável
  (Task 6, `previousKeptUntilSecondHealthyLaunch`).

## File Structure

- Create `Sources/CollieCore/UpdateManifest.swift`: `UpdateManifest`, `AppVersion`.
- Create `Sources/CollieCore/CodeSignature.swift`: `CodeSignature` (requisitos e checagem). Modify
  `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift` (`signedByTeam` delega).
- Modify `Sources/CollieDaemonKit/Android/AndroidDownload.swift` (`fetch` com limite/cabeçalhos/configuração,
  `allowed`).
- Create `Sources/CollieDaemonKit/Update/UpdateChecker.swift`, `Sources/CollieDaemonKit/Update/Maintenance.swift`,
  `Sources/CollieDaemonKit/UpdateCommands.swift`; modify `CommandRouter.swift`, `Daemon.swift`, `DataBackup.swift`,
  `Sources/collied/main.swift`, `Sources/CollieProtocol/Commands.swift`.
- Modify `Sources/CollieDaemonKit/Sandbox/SandboxProfile.swift`.
- Create `Sources/CollieClient/AppUpdateSwap.swift`.
- Create `Sources/CollieProtocol/RestartHint.swift`; modify `Sources/collie/MCPServer.swift`,
  `Sources/CollieDaemonKit/AgentLaunch.swift`, `Sources/CollieApp/` (onde o app mostra erro de admin).
- Create `Sources/CollieApp/UpdateModel.swift`, `Sources/CollieApp/UpdatePreferences.swift`,
  `Sources/CollieApp/UpdateInstallSheet.swift`; modify `PreferencePage.swift`, `PreferencesView.swift`,
  `CollieApp.swift`.
- Modify `.github/workflows/release.yml`; create `scripts/ci/update-manifest.sh`,
  `scripts/ci/test-update-manifest.sh`; modify `docs/release.md`.

## Ordem e dependências

- Independentes, em qualquer ordem: **Task 1, 2, 4, 5, 7, 10**.
- Task 3 depende de 1, 2, 4. Task 6 depende de 1 e 4. Task 8 depende de 3. Task 9 depende de 6, 7, 8.
- Ordem recomendada: 1 → 4 → 2 → 5 → 3 → 8 → 6 → 7 → 9 → 10.

---

### Task 1: Manifesto e versões

**Files:**
- Create: `Sources/CollieCore/UpdateManifest.swift`
- Test: `Tests/CollieCoreTests/UpdateManifestTests.swift`

**Interfaces:**
- Produces:
  - `public struct AppVersion: Comparable, Sendable, CustomStringConvertible { public init?(_ s: String) }` (só
    `X.Y.Z` com inteiros; aceita `v` na frente).
  - `public struct UpdateManifest: Codable, Sendable, Equatable { format: Int; version, tag, dmg: String; size:
    Int64; sha256, minimumSystemVersion, teamId, figcraftEngine, page: String; requiresServiceRestart: Bool? }`
  - `public static func decode(_ data: Data) throws -> UpdateManifest` (recusa > 65 536 bytes, campo faltando,
    `format != 1`, incoerências da Global Constraints, sha256 sem 64 hex minúsculos).
  - `public var dmgURL: URL` (montada a partir de `tag` e `dmg`).
  - `public func offer(installed: String, system: OperatingSystemVersion, skipped: String?) -> Bool` (`version >
    installed`, `minimumSystemVersion ≤ system`, `version != skipped`).

- [ ] **Step 1: Write the failing tests**: `decodesValid`; `refusesOversize` (65 537 bytes); `refusesMissingField`;
  `refusesBadTag` (`0.2.0`, `v0.2`, `v0.2.0-beta`, `figcraft-v0.7.0-c1`); `refusesTagVersionMismatch`
  (`tag v0.2.1`, `version 0.2.0`); `refusesDmgNameMismatch`; `refusesForeignPage`; `refusesSizeOutOfRange` (0 e
  500 000 001); `dmgURLIsDerived` (`== https://github.com/ysraelmoreno/collie/releases/download/v0.2.0/Collie-0.2.0.dmg`);
  `versionOrder` (`0.10.0 > 0.9.9`, `1.0.0 > 0.99.99`, `AppVersion("0.1") == nil`); `offerRefusesDowngradeAndEqual`;
  `offerRespectsSkipped`; `offerRespectsMinimumSystem`; `ignoresUnknownExtraField` (campo novo não quebra).
- [ ] **Step 2: Run** `--filter UpdateManifestTests`. Expected: FAIL (tipos não existem).
- [ ] **Step 3: Implement** em `Sources/CollieCore/UpdateManifest.swift`.
- [ ] **Step 4: Run** `--filter UpdateManifestTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(update): manifest model and version ordering`.

### Task 2: `fetch` com limite, cabeçalhos e hosts

**Files:**
- Modify: `Sources/CollieDaemonKit/Android/AndroidDownload.swift:13-28,146-184`
- Test: `Tests/CollieDaemonKitTests/AndroidDownloadTests.swift`

**Interfaces:**
- Produces:
  - `static func fetch(_ url: URL, to: URL, limit: Int64?, headers: [String: String], configuration:
    URLSessionConfiguration = .ephemeral, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws`
    (passou de `limit` em `totalBytesWritten` ou no `Content-Length`: cancela e lança `ProtocolError(.unavailable,
    "download maior que o esperado")`; com `headers` não vazio, `urlCache = nil` e
    `.reloadIgnoringLocalCacheData`).
  - O `static let fetch: AndroidFetch` existente vira `{ try await fetch($0, to: $1, limit: nil, headers: [:],
    progress: $2) }` (comportamento atual igual).
  - `allowed` aceita os dois prefixos novos.

- [ ] **Step 1: Write the failing tests** (um `URLProtocol` de teste registrado em `configuration.protocolClasses`,
  sem rede): `limitCancels` (corpo de 70 000 bytes, `limit: 65_536` → erro, arquivo de destino não existe);
  `limitByContentLength` (cabeçalho `Content-Length: 70000` → erro antes do corpo); `sendsUserAgent` (o protocolo
  vê `User-Agent == "Collie/0.2.0"`); `noCacheWithHeaders` (`configuration.urlCache == nil` na sessão usada);
  `allowsCollieLatestDownload`, `allowsCollieVersionedDownload` (`…/releases/download/v0.2.0/Collie-0.2.0.dmg`);
  `stillAllowsFigcraft`; `refusesOtherCollieReleasePaths` (atualizar o teste que hoje espera `false` para
  `/releases/download/v0.1.0/…`: agora `true`; `false` para `/releases/download/x0.1.0/…` e com `..`).
- [ ] **Step 2: Run** `--filter AndroidDownloadTests`. Expected: FAIL.
- [ ] **Step 3: Implement**; o redirect continua checado por `allowed`.
- [ ] **Step 4: Run** `--filter AndroidDownloadTests` e `--filter FigcraftInstallerTests` (usa o mesmo `fetch`).
  Expected: PASS.
- [ ] **Step 5: Commit** `feat(download): byte limit, headers and Collie release paths`.

### Task 3: `UpdateChecker` no daemon e sinal `maintenance`

**Files:**
- Create: `Sources/CollieDaemonKit/Update/UpdateChecker.swift`, `Sources/CollieDaemonKit/Update/Maintenance.swift`
- Modify: `Sources/CollieDaemonKit/DataBackup.swift` (backup e import entram em `maintenance`),
  `Sources/CollieDaemonKit/CommandRouter.swift` (instancia; o `busy` do `FigcraftInstaller` passa a incluir
  `maintenance`), `Sources/CollieDaemonKit/Daemon.swift` (`DaemonConfig.updateManifestOverride: URL?`,
  `updateFetch`), `Sources/collied/main.swift` (lê `COLLIE_UPDATE_MANIFEST`, aceita só `file://`, loga
  "collied: update manifest override <url>")
- Test: `Tests/CollieDaemonKitTests/UpdateCheckerTests.swift`, `Tests/CollieDaemonKitTests/MaintenanceTests.swift`

**Interfaces:**
- Consumes: `UpdateManifest`, `AppVersion` (Task 1); `AndroidDownload.fetch(_:to:limit:headers:...)` (Task 2);
  `CodeSignature.dmgNotarized(_:teamId:)` (Task 4); `AndroidDownload.verify(_:sha256:)`; `AndroidInstaller.free`.
- Produces:
  - `actor Maintenance { func enter(_ what: String) throws(ProtocolError); func leave(_ what: String); var active:
    String? }` (`enter` com outro ativo → `.conflict` "<ativo> em andamento").
  - `typealias UpdateFetch = @Sendable (_ url: URL, _ to: URL, _ limit: Int64?, _ progress: @escaping @Sendable
    (Int64, Int64) -> Void) async throws -> Void`
  - `actor UpdateChecker { init(root: URL, installedVersion: String, manifestURL: URL, fetch: UpdateFetch,
    dmgCheck: @escaping @Sendable (URL) -> Bool, freeSpace: @escaping @Sendable (String) -> Int64?, maintenance:
    Maintenance, now: @escaping @Sendable () -> Date = Date.init) }`
  - `struct Status: Codable, Sendable, Equatable { state: String /* none|available|ready|failed|disabled */;
    available: UpdateManifest?; job: Job?; lastCheck: Date?; error: String?; override: String? }`, `Job` igual ao
    do `FigcraftInstaller`.
  - `func check() async -> Status`, `func download() async throws(ProtocolError) -> Status`, `func cancel()`,
    `func skip(_ version: String)`, `func status() -> Status`, `var stagedDMG: URL?` (`<root>/.update-staging/Collie-<v>.dmg`).
  - Lista de recusados em `<root>/.update-staging/refused.json` (só sha256).
  - `UpdateChecker.loop(every: 12 h, first: 60 s)` iniciado em `Daemon.start` quando a checagem automática está
    ligada (flag lida de `<root>/preferences.json`, chave `updates.auto`, padrão `true`; `updates.download`,
    padrão `true`).

- [ ] **Step 1: Write the failing tests** (fetch falso que serve arquivos por URL; `dmgCheck` injetado):
  - `noneWhenNotNewer`; `availableWhenNewer`; `manifest404IsNone` (sem `error`);
  - `downloadsAndVerifies` (fases `downloading → verifying`, estado `ready`, `stagedDMG` existe, staging 0700);
  - `shaMismatchRefusesOnlyThatSha` (estado `failed`, erro "a release mudou durante o download", sha no
    `refused.json`, nova checagem com o mesmo manifesto não chama o fetch do dmg; manifesto com sha novo baixa);
  - `notFoundIsNotRefused` (dmg 404 → `failed`, `refused.json` vazio, próxima checagem tenta de novo);
  - `networkErrorAndCancelAreNotRefused`;
  - `dmgCheckFailureRefuses` (`dmgCheck` → `false`: sha entra na lista, dmg apagado);
  - `limitPassedToFetch` (manifesto com `65_536`; dmg com `size` do manifesto);
  - `lowSpaceRefuses` (`size × 3 + 100 MB − 1` → "Espaço insuficiente", dmg nunca baixado);
  - `maintenanceConflict` (`maintenance.enter("backup")` → `download()` lança `.conflict`; durante `verifying`,
    `enter("import")` lança `.conflict`);
  - `skipHidesVersion`; `overrideReported` (`manifestURL` `file://` → `status().override == url`);
  - `MaintenanceTests`: `enterLeave`, `secondEnterConflicts`, `backupEntersMaintenance` (o `DataBackup` chama
    `enter("backup")`/`leave`).
- [ ] **Step 2: Run** `--filter UpdateCheckerTests` e `--filter MaintenanceTests`. Expected: FAIL.
- [ ] **Step 3: Implement** em `Update/`; o override fora de `file://` é ignorado com log.
- [ ] **Step 4: Run** os dois filtros, `--filter FigcraftInstallerTests` e `--filter DataBackupTests`. Expected:
  PASS.
- [ ] **Step 5: Commit** `feat(update): daemon checker, staged dmg and maintenance signal`.

### Task 4: `CodeSignature` compartilhado

**Files:**
- Create: `Sources/CollieCore/CodeSignature.swift`
- Modify: `Sources/CollieDaemonKit/Design/FigcraftInstaller.swift` (`signedByTeam` passa a chamar
  `CodeSignature.signedByTeam`), `Package.swift` só se `CollieCore` precisar de `linkerSettings` para
  `Security` (normalmente não)
- Test: `Tests/CollieCoreTests/CodeSignatureTests.swift`

**Interfaces:**
- Produces:
  - `public enum CodeSignature { static let team = "AG8JQAH6YB"; static func requirement(identifier: String,
    teamId: String) -> String; static func dmgRequirement(teamId: String) -> String; static func
    signedByTeam(_ path: URL, identifier: String, teamId: String, nested: Bool = false) -> Bool; static func
    dmgNotarized(_ dmg: URL, teamId: String) -> Bool; static func appAndHelpers(_ app: URL, teamId: String) ->
    Bool }` (`appAndHelpers`: o `.app` com aninhados + `Contents/Helpers/{collied,collie,collie-ctty}` com seus
    identificadores).

- [ ] **Step 1: Write the failing tests**: `requirementText` (igual, caractere a caractere, ao requisito de hoje
  do `FigcraftInstaller` para `figcraft-server`); `dmgRequirementText` (texto da Global Constraints);
  `unsignedIsRefused` (script `#!/bin/sh` em temp → `false`); `appleSignedIsNotTeam` (`/bin/ls` → `false`);
  `missingHelperRefuses` (`appAndHelpers` em pasta sem `Contents/Helpers` → `false`); `garbageDmgRefused`
  (arquivo qualquer `.dmg` → `false`).
- [ ] **Step 2: Run** `--filter CodeSignatureTests`. Expected: FAIL.
- [ ] **Step 3: Implement** com `SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString` +
  `SecStaticCodeCheckValidityWithErrors`.
- [ ] **Step 4: Run** `--filter CodeSignatureTests` e `--filter FigcraftInstallerTests`. Expected: PASS.
- [ ] **Step 5: Commit** `refactor(core): shared code signature checks`.

### Task 5: Deny da irmã no sandbox

**Files:**
- Modify: `Sources/CollieDaemonKit/Sandbox/SandboxProfile.swift:110-125` e o ramo `strict` equivalente
- Test: `Tests/CollieDaemonKitTests/SandboxProfileTests.swift`

**Interfaces:**
- Produces: com `appBundle` presente, regra `deny file-write*` (com a tag) `regex ^<pasta-mãe real do app>/\.Collie-update-`
  nos dois modos.

- [ ] **Step 1: Write the failing tests**: `openDeniesUpdateSibling` e `strictDeniesUpdateSibling` (o texto do
  perfil contém a regex escapada para `/Applications`); `siblingRuleFollowsRealParent` (app em
  `~/Applications/Collie.app` → regex de `~/Applications` real); `noAppBundleNoSiblingRule`.
- [ ] **Step 2: Run** `--filter SandboxProfileTests`. Expected: FAIL.
- [ ] **Step 3: Implement** com os helpers `rx`/`re` existentes.
- [ ] **Step 4: Run** `--filter SandboxProfileTests` e `--filter SandboxOpenTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sandbox): deny writes to the update sibling`.

### Task 6: `AppUpdateSwap` (montar, copiar, conferir, trocar, guardar, relançar)

**Files:**
- Create: `Sources/CollieClient/AppUpdateSwap.swift`
- Test: `Tests/CollieClientTests/AppUpdateSwapTests.swift`

**Interfaces:**
- Consumes: `UpdateManifest`, `AppVersion` (Task 1); `CodeSignature.appAndHelpers` (Task 4).
- Produces:
  - `public struct AppUpdateSwap { public init(app: URL, mount: @escaping (_ dmg: URL) throws -> (point: URL,
    detach: () -> Void), verify: @escaping (URL) -> Bool = { CodeSignature.appAndHelpers($0, teamId:
    CodeSignature.team) }, freeSpace: @escaping (String) -> Int64?, defaults: UserDefaults) }`
  - `public enum Refusal: Error, Equatable { case translocated, readOnly, notWritable, tccFolder, localBuild,
    lowSpace, badVersion(String), badSignature, swapFailed(String) }`
  - `public func destinationRefusal(tccWarning: Bool) -> Refusal?` (`/AppTranslocation/` no caminho; volume só
    leitura; `access(pasta-mãe, W_OK) != 0`; `tccWarning`; `verify(app) == false` → `.localBuild`).
  - `public func prepare(dmg: URL, manifest: UpdateManifest, system: OperatingSystemVersion) throws(Refusal) ->
    URL` (espaço; `mount`; `mkdtemp` da irmã; `ditto`; `detach`; `Info.plist` versão = `manifest.version` e
    `LSMinimumSystemVersion`; symlinks só relativos dentro do bundle; sem setuid/setgid; `verify`;
    `com.apple.quarantine` fora; devolve `<irmã>/Collie.app`).
  - `public func swap(prepared: URL) throws(Refusal)` (`renamex_np(prepared, app, RENAME_SWAP)`; `verify(app)`
    falhou → `renamex_np` de volta e `.badSignature`; grava `update.previous` = caminho, `update.previousVersion`,
    `update.healthyLaunches = 0`).
  - `public func launched(healthy: Bool)` (com `healthy`, soma 1; na 2ª apaga a irmã do anterior e limpa as
    chaves); `public func rollback() throws(Refusal)` (troca com o anterior, mesma conferência);
    `public static func relauncher(pid: Int32, app: URL) -> [String]` (argumentos do `/bin/sh -c` exato do spec);
    `public static func cleanupOrphans(parent: URL, keep: URL?)` (apaga `.Collie-update-*` que não são o anterior).

- [ ] **Step 1: Write the failing tests** (dois `.app` falsos em temp: pastas com `Contents/Info.plist` e
  `Contents/MacOS/Collie`; `mount` falso devolve uma pasta com o `.app` novo; `verify` injetado):
  `swapsAtomically` (depois: `app/Contents/Info.plist` tem a versão nova; o antigo está na irmã);
  `siblingNeverReused` (cria antes `.Collie-update-*` com conteúdo plantado: `prepare` usa outra pasta e o
  conteúdo plantado não aparece no preparado); `postSwapCheckFailsSwapsBack` (`verify` → `true` no prepare e
  `false` depois da troca: o app volta ao antigo, erro `.badSignature`); `badVersionRefused`
  (`Info.plist` 0.1.9 com manifesto 0.2.0); `minimumSystemRefused`; `absoluteSymlinkRefused`; `setuidRefused`;
  `quarantineStripped`; `translocatedRefused`, `notWritableRefused` (pasta-mãe 0555), `localBuildRefused`
  (`verify(app)` → `false`); `lowSpaceRefused`; `detachAlwaysCalled` (também em falha);
  `previousKeptUntilSecondHealthyLaunch` (1ª `launched(healthy: true)` mantém, 2ª apaga; `healthy: false` não
  conta); `rollbackRestoresPrevious`; `relauncherArgs` (igual a `["-c", "while kill -0 <pid>; do sleep 0.2; done;
  /usr/bin/open '<app>'"]` com aspas seguras); `cleanupKeepsPrevious`.
- [ ] **Step 2: Run** `--filter AppUpdateSwapTests`. Expected: FAIL.
- [ ] **Step 3: Implement**; o `mount` real (`/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen
  -mountrandom <tmp> -plist`) fica num `static func hdiutilMount` **não** chamado pelos testes.
- [ ] **Step 4: Run** `--filter AppUpdateSwapTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(update): verified app swap, previous bundle and relaunch`.

### Task 7: Contrato de compatibilidade (app, CLI, hooks, ctty)

**Files:**
- Create: `Sources/CollieProtocol/RestartHint.swift`
- Modify: `Sources/collie/MCPServer.swift` (resposta de ferramenta com `unknown command`),
  `Sources/collie/CLI.swift` (mesma mensagem no CLI), `Sources/CollieDaemonKit/AgentLaunch.swift`
  (`static let hookSubcommands: [String]` usado nos comandos de hook), o ponto do app que mostra erro de
  `adminCall` (`Sources/CollieClient/DaemonClient.swift` ou o chamador em `CollieApp`)
- Test: `Tests/CollieProtocolTests/RestartHintTests.swift`, `Tests/CollieDaemonKitTests/AgentLaunchTests.swift`,
  `Tests/CollieTerminalTests/PTYProcessTests.swift` (teste novo `cttyAcceptsSandboxLine`, ao lado dos testes que já usam o `collie-ctty`)

**Interfaces:**
- Produces: `public enum RestartHint { static let text = "reinicie o serviço para usar isto"; static func
  wrap(_ e: ProtocolError) -> ProtocolError }` (`unknown command` / comando inexistente → mesma `code`, mensagem
  `"<cmd>: reinicie o serviço para usar isto"`; outros erros intactos).

- [ ] **Step 1: Write the failing tests**: `wrapsUnknownCommand`, `keepsOtherErrors`; `hookSubcommandsFrozen`
  (`AgentLaunch.hookSubcommands` igual à lista atual, escrita literal no teste: remover ou renomear exige editar
  o teste, de propósito); `hooksUseFrozenNames` (todo `" hook <x>"` gerado por `AgentLaunch` tem `x` na lista);
  `cttyAcceptsSandboxLine` (o `collie-ctty` aceita `--sandbox <perfil> <cmd> <args>` como hoje).
- [ ] **Step 2: Run** `--filter RestartHintTests`, `--filter AgentLaunchTests`, `--filter cttyAcceptsSandboxLine`.
  Expected: FAIL.
- [ ] **Step 3: Implement**; o MCP continua listando as ferramentas sem consultar o daemon.
- [ ] **Step 4: Run** os três filtros e `--filter MCPTests` (confira que `mcpListsTools` segue como única falha
  antiga). Expected: PASS.
- [ ] **Step 5: Commit** `feat(compat): restart hint for commands an older daemon lacks`.

### Task 8: Comandos `app.update.*` (`adminOnly`)

**Files:**
- Create: `Sources/CollieDaemonKit/UpdateCommands.swift`
- Modify: `Sources/CollieProtocol/Commands.swift` (`app.update.status|check|download|cancel|skip`,
  `exposedToMCP: false`), `Sources/CollieDaemonKit/CommandRouter.swift` (rota própria antes do despacho de
  plug-ins, como `android.*`)
- Test: `Tests/CollieDaemonKitTests/UpdateCommandTests.swift`, `Tests/CollieProtocolTests/CommandsTests.swift`,
  `Tests/CollieIntegrationTests/MCPTests.swift`

**Interfaces:**
- Consumes: `UpdateChecker` (Task 3).
- Produces: `app.update.status` → `UpdateChecker.Status` em JSON; `check`, `download`, `cancel` → `Status`;
  `skip {version}` → `Status`.

- [ ] **Step 1: Write the failing tests**: `terminalPeerRefused` (todos os 5 com peer de terminal → recusado por
  `adminOnly`); `statusRoundTrip`; `skipNeedsVersion`; atualizar `CommandsTests` e `MCPTests` que enumeram
  comandos/ferramentas em ordem (armadilha conhecida: comando novo quebra esses testes).
- [ ] **Step 2: Run** `--filter UpdateCommandTests`, `--filter CommandsTests`, `--filter MCPTests`. Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** os três filtros. Expected: PASS (salvo `mcpListsTools` antigo).
- [ ] **Step 5: Commit** `feat(update): app.update admin commands`.

### Task 9: Página "Atualizações", folha de instalação e motor

**Files:**
- Create: `Sources/CollieApp/UpdateModel.swift`, `Sources/CollieApp/UpdatePreferences.swift`,
  `Sources/CollieApp/UpdateInstallSheet.swift`
- Modify: `Sources/CollieApp/PreferencePage.swift` (`case atualizacoes`, título "Atualizações", grupo
  "Interface", ícone `↻`), `Sources/CollieApp/PreferencesView.swift` (página e selo no laço de 5 s),
  `Sources/CollieApp/CollieApp.swift` (`launched(healthy:)` ao conectar, `cleanupOrphans`, "Atualizado para <v>",
  "Instalar ao sair" no `willTerminateNotification` existente, notificação uma vez por versão via `Notifier`)
- Test: `Tests/CollieAppTests/UpdateModelTests.swift`, `Tests/CollieAppTests/PreferencePageTests.swift`

**Interfaces:**
- Consumes: `app.update.*` (Task 8), `AppUpdateSwap` (Task 6), `RestartHint` (Task 7), `design.engine.status` e
  `design.engine.install` existentes, `DaemonLauncher.restart` existente (chamado **só** pela opção reiniciar).
- Produces: `struct UpdateModel { static func decode(_ v: JSONValue) -> UpdateChecker.Status?; func card(...) ->
  Card?; func sheet(terminals: Int, busy: [String], engineChanges: (from: String?, to: String, size: Int64)?) ->
  SheetText }` (textos da Global Constraints).

- [ ] **Step 1: Write the failing tests** (só o modelo, sem UI): `cardShowsVersionAndSize`; `skippedHidesCard`;
  `sheetNoTerminals` ("O Collie vai fechar e reabrir", sem opções); `sheetWithTerminals` (as duas opções com
  `n`); `sheetBusyShowsWait` ("Esperar e instalar", "esperando collie-dx, apps-dev…"); `sheetEngineChange` (o
  texto do desenho indisponível com versão e tamanho); `unknownCommandShowsRestartForChecks` ("reinicie o serviço
  para procurar atualizações"); `overrideShown` ("fonte de teste: <url>"); `refusalTexts` (cada `Refusal` →
  texto da Global Constraints); `PreferencePageTests`: `atualizacoesInInterfaceGroup`.
- [ ] **Step 2: Run** `--filter UpdateModelTests` e `--filter PreferencePageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** modelo e views (molde: `AndroidPreferences`/`DesignEnginePreferences`; poll 1 s com
  job, 3 s sem). A ordem da instalação na view segue o spec §4.2 passos 1–8.
- [ ] **Step 4: Run** os dois filtros. Expected: PASS. A UI em si fica para o roteiro manual.
- [ ] **Step 5: Commit** `feat(app): Updates page and install sheet`.

### Task 10: CI do manifesto — só valida com `bash -n` e `actionlint`; o teste real é no GitHub e é passo do dono

**Files:**
- Create: `scripts/ci/update-manifest.sh` (escreve `update.json` a partir de dmg, app gerado e pin),
  `scripts/ci/test-update-manifest.sh` (offline, molde `test-update-pin.sh`)
- Modify: `.github/workflows/release.yml` (apagar drafts órfãos da tag antes de criar, molde
  `figcraft.yml:78-83`; `--latest=false` se a tag não é a maior `vX.Y.Z` publicada; passo Manifesto; asset
  `build/update.json`; checagem pós-publicação em `…/releases/download/<tag>/update.json`), `docs/release.md`
  (o manifesto, o override `COLLIE_UPDATE_MANIFEST`, como voltar para a versão anterior pela pasta
  `.Collie-update-*`)

- [ ] **Step 1: Write the failing test** `scripts/ci/test-update-manifest.sh`: com um dmg falso e um
  `Info.plist` falso, o JSON gerado tem os campos e valores esperados, `teamId` vindo de uma saída de
  `codesign -dv` simulada (`TeamIdentifier=AG8JQAH6YB`), `figcraftEngine` do pin, e passa no decodificador da Task 1
  (mesmos campos, mesmo texto de `page`).
- [ ] **Step 2: Run** `bash scripts/ci/test-update-manifest.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** o script e as mudanças do workflow.
- [ ] **Step 4: Run** `bash scripts/ci/test-update-manifest.sh`, `bash -n scripts/ci/update-manifest.sh`,
  `actionlint .github/workflows/release.yml`. Expected: PASS / sem saída.
- [ ] **Step 5: Commit** `ci(release): publish update.json and clean orphan drafts`.
- **Passo do dono**: revisar e mergear; a primeira tag com isto é o teste real.

---

## Roteiro manual do dono (não é tarefa de executor)

Sempre numa **conta de usuário macOS separada** (outro `gui/<uid>`, outro `~/Library`, outro LaunchAgent), nunca na
conta do dono.

1. Gerar dois dmgs: `COLLIE_SKIP_NOTARIZE=1 COLLIE_VERSION=0.90.0 scripts/release.sh` e o mesmo com `0.90.1`.
2. Na conta de teste: instalar a 0.90.0 em `~/Applications`; escrever um `update.json` para a 0.90.1 (sha256 e
   tamanho reais) e apontar `launchctl setenv COLLIE_UPDATE_MANIFEST file:///…`; reiniciar o serviço **da conta de
   teste**.
3. Esperado: a página mostra "fonte de teste", baixa, e **recusa** a 0.90.1 (sem notarização), com o sha256 na
   lista de recusados.
4. Conferir à mão:
   - `hdiutil attach` pelo app: há pedido de TCC (Volumes removíveis)?
     `log stream --predicate 'subsystem == "com.apple.TCC"'`;
   - num terminal do Collie (modo `open`): `mkdir ~/Applications/.Collie-update-x` e
     `mkdir /Applications/.Collie-update-x` são negados? (B1: o Seatbelt checa o pai?);
   - `codesign -R='notarized'`/`SecStaticCode` no dmg grampeado da última release real com a rede desligada;
   - App Management: trocar `~/Applications/Collie.app` e `/Applications/Collie.app` (conta admin);
   - relançamento pelo LaunchServices depois de `renamex_np`;
   - "Atualizar só o app" com um agente rodando: hooks e MCP novos contra o daemon antigo;
   - "Voltar para <v>".
5. Caminho feliz completo: duas releases de patch reais (a primeira com o atualizador e a seguinte), na conta de
   teste.
