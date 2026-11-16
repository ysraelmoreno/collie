# Substituir respostas no painel Rede (map local) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regras de map local (resposta fabricada, atraso, queda) no painel Rede, criadas por CLI/agente (com cartão) e pela UI, com o fluxo mapeado visível.

**Architecture:** O daemon grava um arquivo de regras (atômico); o addon do `mitmdump` o relê por `mtime` e, no hook `request`, atende ou corta a requisição, marcando `mappedBy` nas linhas do fluxo. Comandos `rule-*` no plug-in `network`; regras de agente passam por cartão.

**Tech Stack:** Swift (CollieNetwork, CollieDaemonKit, ColliePlugins, CollieApp), addon Python do mitmproxy, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-15-network-mapping-design.md`

## Global Constraints

- Testes: só os criados/alterados, com `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>` numa worktree `--detach`. Nunca a suíte inteira. `MCPTests.mcpListsTools` já falha (`memory_doc-search`): confirme que continua sendo a única falha.
- Não instalar nem reiniciar o app, não rodar `bundle-app`, não dar push. Commit por task, só dos seus arquivos (`git diff <arquivo>` antes de `git add`), trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- E2E só em daemon isolado (`scripts/dev/run-isolated.sh`), pasta temporária, porta livre. Não tocar o tráfego do Mac nem mexer em emulador real.
- Limites: ≤ 100 regras; corpo ≤ 5 MiB decodificado; arquivo ≤ 20 MiB; glob 1 a 200 caracteres; `delayMs` 0 a 60000; status 100 a 599.
- `content-encoding` e `content-length` recusados nos cabeçalhos da regra.
- Nomes de comando com hífen (`rule-add`, …). Não editar `docs/pages`, `.collie`, nem arquivos não rastreados de outros.
- Se o plano não bater com o código, pare e pergunte.

## Review Focus

- Regra com glob inválido ou vazio: recusada com erro claro; nunca derruba o `mitmdump`.
- Arquivo de regras corrompido ou a meio de escrita: o addon mantém as regras anteriores (escrita atômica).
- Duas regras casam: vence a primeira ligada na ordem da lista.
- Corpo binário e corpo ≥ 5 MiB: binário sai intacto; o grande é recusado no `rule-add`.
- `--body-file` fora do cercado ou inexistente: recusado; o addon nunca lê caminho.
- Método em caixa diferente (`get` vs `GET`) e query com ordem diferente casam do mesmo jeito.
- Agente cria regra e o cartão é negado ou expira: a regra nunca fica ligada.
- Fluxo atendido por regra sempre marcado `mappedBy`, inclusive após o addon recarregar.

## File Structure

- Create `Sources/CollieNetwork/MapRule.swift`: modelo, validação, JSON.
- Create `Sources/CollieDaemonKit/Network/RuleStore.swift`: lista de regras, persistência, arquivo do addon.
- Modify `Sources/CollieNetwork/AddonScript.swift`, `AddonProtocol.swift`, `Flow.swift`, `FlowStore.swift`: addon e `mappedBy`.
- Modify `Sources/CollieDaemonKit/Network/NetworkService.swift`, `MitmProcess.swift`, `NetworkCommands.swift`; `Sources/ColliePlugins/NetworkPanel.swift`: comandos e opção `collie_rules`.
- Modify `Sources/CollieApp/…` do painel Rede (`NetworkPanelView.swift`): lista de regras, marca e "Mapear".
- Tests em `Tests/CollieNetworkTests/`, `Tests/CollieDaemonKitTests/NetworkMitmTests.swift`, `NetworkServiceTests.swift`, `Tests/CollieAppTests/`.

### Task 1: Modelo da regra e validação

**Files:**
- Create: `Sources/CollieNetwork/MapRule.swift`
- Test: `Tests/CollieNetworkTests/MapRuleTests.swift`

**Interfaces:**
- Produces:
  - `public struct MapRule: Codable, Equatable, Sendable { id: String; name: String?; enabled: Bool; match: Match; action: Action; delayMs: Int }`
  - `Match { method: String?; host: String?; path: String?; query: [String: String] }`
  - `enum Action: Codable { case local(status: Int, headers: [Header], bodyB64: String?); case drop }`
  - `static func validate(_ rules: [MapRule]) throws(MapRuleError)` aplicando os limites das Global Constraints
  - `static func makeID() -> String` (6 caracteres `a-z0-9`)
  - `static func guessedContentType(_ body: Data) -> String`

- [ ] **Step 1: Write the failing tests** em `MapRuleTests`: `jsonRoundTrip`, `rejectsContentEncodingAndLength` (`MapRuleError.forbiddenHeader`), `rejectsOutOfRangeStatus` (99 e 600), `rejectsDelayAbove60000`, `rejectsBodyOver5MiB`, `rejectsMoreThan100Rules`, `rejectsEmptyOrOverlongGlob` (0 e 201 caracteres), `contentTypeGuess` (JSON válido → `application/json`, texto → `text/plain`, bytes → `application/octet-stream`).
- [ ] **Step 2: Run** `--filter MapRuleTests`; Expected: FAIL (tipo não existe).
- [ ] **Step 3: Implement** `MapRule`, `MapRuleError` e `validate`; método guardado em maiúsculas.
- [ ] **Step 4: Run** `--filter MapRuleTests`; Expected: PASS.
- [ ] **Step 5: Commit** `feat(network): MapRule model and validation`.

### Task 2: Addon aplica regras e marca `mappedBy`

**Files:**
- Modify: `Sources/CollieNetwork/AddonScript.swift`, `AddonProtocol.swift`, `Flow.swift`, `FlowStore.swift`
- Modify: `Sources/CollieDaemonKit/Network/MitmProcess.swift` (opção `--set collie_rules=<path>`)
- Test: `Tests/CollieDaemonKitTests/NetworkMitmTests.swift` (leia como ele sobe o `mitmdump` real e como pula se ele não existir), `Tests/CollieNetworkTests/FlowStoreTests.swift`, `Tests/CollieNetworkTests/AddonProtocolTests.swift` (crie se não houver)

**Interfaces:**
- Consumes: `MapRule` (JSON do arquivo: `{"v":1,"rules":[…]}` só com as ligadas).
- Produces:
  - `FlowEvent.Request.mappedBy: String?`, `FlowEvent.Response.mappedBy: String?`, `Flow.mappedBy: String?`, `FlowSummary.mapped: Bool`.
  - `MitmProcess.args(port:confdir:addon:rules:)` ganha `rules: URL?` e passa `--set collie_rules=<path>` quando há.

- [ ] **Step 1: Write the failing tests:**
  - `AddonProtocolTests.decodesMappedBy` (linha com `"mappedBy":"abc"` decodifica; sem o campo, `nil`).
  - `FlowStoreTests.mappedFlowKeepsRuleId` (`Flow.mappedBy` e `summary.mapped == true`).
  - `NetworkMitmTests`: `localRuleAnswersWithoutReachingServer` (servidor local de teste conta acessos; regra `host=127.0.0.1 path=/x* local 418 body "oi"`; `curl` pelo proxy recebe 418 "oi", servidor com 0 acessos, linha `response` com `mappedBy`), `dropRuleCutsConnection`, `delayRuleWaits` (≥ delay), `firstEnabledRuleWins`, `badRulesFileKeepsPreviousRules` (sobrescreve com lixo, regra anterior segue valendo), `ruleReloadsOnMtimeChange` (sem reiniciar o `mitmdump`), `methodAndQueryMatching` (`get` minúsculo e query em outra ordem casam), `unmatchedFlowHasNoMappedBy`.
- [ ] **Step 2: Run** `--filter AddonProtocolTests`, `--filter FlowStoreTests`, `--filter NetworkMitmTests`; Expected: FAIL.
- [ ] **Step 3: Implement** o decode de `mappedBy`; o addon em Python: opção `collie_rules`, releitura por `os.stat().st_mtime_ns`, `async def request`, `fnmatch` para host e caminho, `http.Response.make` para `local`, `flow.kill()` para `drop`, `asyncio.sleep` para `delayMs`, `mappedBy` nas linhas `request` e `response` (e `error` se houver). JSON inválido na releitura: mantém as regras anteriores.
- [ ] **Step 4: Run** os três filtros; Expected: PASS (ou os de `mitmdump` pulados só se o binário não existir, dizendo-o).
- [ ] **Step 5: Commit** `feat(network): addon applies map rules and marks mapped flows`.

### Task 3: Armazém de regras e comandos `rule-*`

**Files:**
- Create: `Sources/CollieDaemonKit/Network/RuleStore.swift`
- Modify: `Sources/CollieDaemonKit/Network/NetworkService.swift`, `NetworkCommands.swift`, `Sources/ColliePlugins/NetworkPanel.swift`, `Sources/CollieDaemonKit/Network/MitmProcess.swift` (passar `rules`)
- Test: `Tests/CollieDaemonKitTests/RuleStoreTests.swift`, `Tests/CollieDaemonKitTests/NetworkServiceTests.swift`, `Tests/CollieProtocolTests/CommandsTests.swift` (somente o teste de esquema que enumera tools, se quebrar)

**Interfaces:**
- Consumes: `MapRule`, `MapRule.validate`.
- Produces:
  - `actor RuleStore { init(file: URL, active: URL); func all() -> [MapRule]; func add(_ r: MapRule) throws -> MapRule; func remove(_ id: String) throws; func setEnabled(_ id: String, _ on: Bool) throws; func clear() }`
  - Cada mudança regrava `active` (só as ligadas, atômico, 0600) e `file` (todas). `init` lê `file` e liga nada (`enabled = false` para todas).
  - `NetworkService` expõe `rules` e passa `active` a `startProxy`.
  - Comandos: `network.rule-add|rule-list|rule-remove|rule-enable|rule-disable|rule-clear` com as flags do spec §4.
  - `--from <id>`: copia status, cabeçalhos (sem `content-encoding`, `content-length`, `transfer-encoding`) e o corpo **decodificado** (`BodyDecoder`) do fluxo capturado; as flags sobrescrevem.
  - `--body-file`: lido pelo daemon; admin só limitado em tamanho; terminal só dentro do cercado (e o que o sandbox já permite ler a ele).

- [ ] **Step 1: Write the failing tests:**
  - `RuleStoreTests`: `startsAllDisabled`, `activeFileHasOnlyEnabledRulesInOrder`, `activeFileIsWrittenAtomically` (nunca JSON parcial, lendo em laço durante 200 gravações), `persistsAcrossInstances`, `removeAndClear`.
  - `NetworkServiceTests`: `ruleAddFromFlowCopiesDecodedResponse`, `ruleAddFlagsOverrideFrom`, `bodyFileOutsideCercadoRefused`, `bodyFileOver5MiBRefused`, `ruleListShowsEnabledState`, `ruleCommandsNeedReachableNetworkPanel`.
- [ ] **Step 2: Run** `--filter RuleStoreTests`, `--filter NetworkServiceTests`; Expected: FAIL.
- [ ] **Step 3: Implement** o `RuleStore`, a fiação em `NetworkService`/`MitmProcess` e os comandos no `NetworkPanel`/`networkCommand`. Se `CommandsTests` que enumera tools quebrar, atualize só a lista esperada.
- [ ] **Step 4: Run** os filtros acima e `--filter CommandsTests`; Expected: PASS (e `mcpListsTools` segue a única falha).
- [ ] **Step 5: Commit** `feat(network): rule store and rule-* commands`.

### Task 4: Cartão de aprovação para regras de agente

**Files:**
- Modify: `Sources/CollieDaemonKit/Network/NetworkCommands.swift`; o ponto do cartão de `confirm` de apps (`PaddockApps.confirmAppCall`) só se for preciso extrair um helper comum (mudança mínima)
- Test: `Tests/CollieDaemonKitTests/NetworkRuleApprovalTests.swift`

**Interfaces:**
- Consumes: `RuleStore`, o mecanismo de cartão do `confirmAppCall`.
- Produces: chamador agente em `rule-add` e `rule-enable` levanta o cartão; só `Permitir` liga a regra; chamador admin e `rule-remove|disable|clear|list` não levantam cartão.

- [ ] **Step 1: Write the failing tests:** `agentRuleAddRaisesCardAndStaysDisabledUntilAllowed`, `denyKeepsRuleDisabled`, `timeoutIsDeny`, `adminRuleAddNeedsNoCard`, `agentRemoveAndDisableNeedNoCard`, `cardTextNamesMethodHostPathStatusSizeDelay`.
- [ ] **Step 2: Run** `--filter NetworkRuleApprovalTests`; Expected: FAIL.
- [ ] **Step 3: Implement.** Se o cartão de `confirm` não puder ser reaproveitado sem refatoração grande, pare e pergunte.
- [ ] **Step 4: Run** `--filter NetworkRuleApprovalTests` e `--filter PaddockAppServiceTests` (garante que o cartão de apps não quebrou); Expected: PASS.
- [ ] **Step 5: Commit** `feat(network): agent rules need a user card`.

### Task 5: Painel — marca, lista de regras e "Mapear esta resposta"

**Files:**
- Modify: `Sources/CollieApp/…/NetworkPanelView.swift` e o modelo do painel (`NetworkPanel.swift` em `ColliePlugins` se o estado ficar lá)
- Test: `Tests/CollieAppTests/NetworkPanelTests.swift` (existente; leia o estilo)

**Interfaces:**
- Visual aprovado pelo dono: `docs/pages/rede-map-local/index.html` (painel, regras, formulário, cartão) e `docs/pages/rede-map-local-canvas/index.html` (painel dentro do canvas). Siga essas prévias, nos tokens do Collie.
- Consumes: `FlowSummary.mapped`, `network.rule-*`, `network.get`.
- Produces: marca "mapeado" (com o nome da regra) na linha e no detalhe; lista de regras (liga/desliga, remove); formulário "Mapear esta resposta" preenchido do fluxo, que chama `network.rule-add --from <id>` com as edições.

- [ ] **Step 1: Write the failing tests** (lógica pura do modelo, no estilo do `NetworkPanelTests`): `mappedFlowShowsBadgeWithRuleName`, `ruleListReflectsEnableToggle`, `mapFormPrefilledFromCapturedResponse`, `emptyMatchShowsWarning`.
- [ ] **Step 2: Run** `--filter NetworkPanelTests`; Expected: FAIL.
- [ ] **Step 3: Implement** o modelo e a view. A aparência segue o painel atual.
- [ ] **Step 4: Run** `--filter NetworkPanelTests`; confirme `swift build --disable-sandbox --product CollieApp` (confira o código de saída à parte). Expected: PASS e build ok.
- [ ] **Step 5: Commit** `feat(app): network panel shows mapped flows and map rules`.

### Task 6: E2E, docs e nota no spec

**Files:**
- Create: `docs/superpowers/apps/network-mapping.md` (uso da CLI, exemplos com `acme-app-android`: PDP com `discount_pdp.json`, erro 500, timeout)
- Modify: `docs/superpowers/specs/2026-11-15-network-mapping-design.md` (nota "Implementado" no fim, só o que desviou)

- [ ] **Step 1:** Em daemon isolado (`scripts/dev/run-isolated.sh`, raiz temporária, porta livre), com um servidor HTTP local de teste e `curl --proxy` no `mitmdump` da sessão (sem emulador): `rule-add --host 127.0.0.1 --path '/pdp*' --status 200 --body-file <json>`, `curl` recebe o JSON mapeado e o servidor não é acessado; `rule-disable` e o `curl` volta ao servidor; `--drop` e `--delay 1500`.
- [ ] **Step 2:** Registre no doc o que passou e o que ficou sem prova (emulador real e app de verdade são do dono, depois de instalar o bundle).
- [ ] **Step 3: Commit** `docs(network): map rules usage and verification`.
