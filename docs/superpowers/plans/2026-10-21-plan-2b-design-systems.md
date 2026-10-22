# Plano 2B — Design Systems — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Biblioteca de design systems (variáveis com modos, estilos, componentes) com um ativo por workspace e outro opcional por andar; trocar o ativo reestiliza na hora todas as telas do escopo (com volta atrás), atualizar um design system propaga para as telas, há histórico de versões, e toda troca/atualização vira uma decisão na Memória.

**Architecture:** Cada design system é um arquivo de design do 2A cuja **biblioteca de time** é publicada no `figcraft-server` local (`library.publishToServer` dentro da sessão ao vivo). As telas habilitam a biblioteca pelo link de visualização (`library.add {path}`), e os agentes usam tokens/estilos/componentes por wrappers do Orq (o daemon injeta a biblioteca; o agente nunca vê link). Trocar o ativo = `library.swap {from, to}` em cada tela do escopo (um passo de desfazer por arquivo; o figcraft casa por nome). Atualizar = publicar nova versão + `library.acceptUpdates` nas telas. Histórico = instantâneo `.figcraft` + entrada por versão/troca; "voltar" republica um instantâneo ou troca de volta. Tudo roda em clientes headless do daemon (a UI web não tem suporte próprio a biblioteca, mas renderiza as cópias e recebe as mudanças pela sessão).

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI (painel); figcraft v0.7.0 do 2A (comandos `library.*`, `variable.*`, `file.save`). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.2 (Design Systems), §8 (Memória), §5 (cordas). Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`. Base: `main` em `c8318aa` (2A mergeado: `DesignService`, `design.*` com lista permitida, `FigcraftServer`, painel Design). Docs do motor: `vendor/figcraft-src/docs/mcp.md` §Libraries/§Team libraries, `vendor/figcraft-src/docs/server.md` §Team libraries.

## Global Constraints

- Mudanças de design system **aplicam na hora, com desfazer** (decisão do usuário, spec §7.2); **histórico de versões** para voltar atrás.
- **Workspace tem um design system ativo; andar herda ou define outro** (spec §7.2).
- Toda troca/atualização gera uma **decisão na Memória com o motivo** (spec §7.2): tipo `decision`, assunto fixo por escopo para que a nova substitua a anterior (`design system ativo` / `design system ativo (andar <nome>)`; atualização: `design system <nome>`).
- Os links (edição **e** visualização) e a chave do servidor continuam segredos do daemon/app: agentes nunca os recebem; resultados e erros passam pelo scrubber do 2A.
- `library.*` continua **fora da lista permitida** dos agentes (`design.run`/`design.batch`); só os wrappers `design.system.*` chegam à biblioteca, sempre com a biblioteca escolhida pelo daemon e só bibliotecas do servidor local.
- **Corda é a única permissão** (decisão do usuário). Escrita de escopo largo: trocar/voltar o ativo do **workspace** = app (admin) ou Maestro; do **andar** = app ou o Maestro que criou o andar; `design.system.publish` exige alcance (corda/doca) a um painel Design que mostre o arquivo do design system.
- Nada sai da máquina: só `ws://127.0.0.1:<porta do servidor local>`.
- Uma troca/atualização é por arquivo **tudo-ou-nada** (um passo do figcraft); entre arquivos, falha num arquivo não desfaz os outros — o resultado lista por arquivo `ok | error` e o histórico registra o que de fato mudou.
- Nada de I/O bloqueante no pool cooperativo; protocolo `v: 1`; testes com o build real em `vendor/figcraft` (presente nesta máquina) e fakes onde der.

## Review Focus

1. **Tela com nomes que o design system novo não tem** (variável/estilo/componente sem par por nome) → a troca aplica o que casa e devolve `unmatched` por arquivo; nada quebra; o usuário vê a lista. Teste: Task 2 `swapReportsUnmatched` (real).
2. **Arquivo de tela aberto no painel enquanto a troca roda** → a mudança aparece ao vivo na UI (pela sessão), sem recarregar; a UI web não precisa de suporte a biblioteca. Teste: Task 2 `swapReachesOtherSessionClient` (real: um segundo cliente da sessão vê o valor novo).
3. **Andar sem override herdando do workspace, e o workspace troca** → telas do andar trocam também; andar com override não muda. Teste: Task 2 `floorInheritsWorkspaceUnlessOverridden`.
4. **Agente sem permissão tenta trocar o ativo do workspace** (terminal comum, ou Maestro de outro andar) → `notMaestro`/`notConnected`, nada muda, nenhuma decisão gravada. Teste: Task 2 `scopeWritePermissions`.
5. **Publicar sem mudanças / servidor fora / design system apagado** → erro claro (`no changes to publish`, `design engine restarting…`, `notFound`), histórico intacto. Teste: Task 1 `publishWithoutChangesIsRefused`, Task 2 `useMissingSystemNotFound`.

---

## File Structure

```
Sources/OrqCore/Workspace.swift                       (+ Workspace.designSystem: UUID?, Floor.designSystem: UUID?)
Sources/OrqDaemonKit/Design/DesignSystems.swift        registro + histórico (systems.json, history/<id>.json, snapshots)
Sources/OrqDaemonKit/Design/DesignSystemService.swift  actor: criar, publicar, ativar, propagar, voltar, wrappers
Sources/OrqDaemonKit/Design/DesignService.swift        (+ floor por arquivo; cliente "orq-ds" interno; helpers p/ rodar library.* internamente)
Sources/OrqDaemonKit/DesignCommands.swift              (+ design.system.*)
Sources/OrqDaemonKit/MemoryCommands.swift              (+ helper saveDecision reutilizado)
Sources/OrqProtocol/Plugins.swift                      (+ comandos design.system.*, plug-in designsystems)
Sources/OrqPlugins/DesignSystemsPanel.swift            painel de doca (lista, ativo por escopo, histórico, criar, publicar, voltar)
Sources/OrqApp/OrqApp.swift                            (registro do painel)
Tests/OrqDaemonKitTests/{DesignSystemStoreTests,DesignSystemTests}.swift, Tests/OrqPluginsTests/DesignSystemsPanelTests.swift
README.md, docs/superpowers/plans/2026-10-20-phase2-roadmap.md
```

---

### Task 1: Registro, criação e publicação (com contrato do motor provado)

**Files:** Create `Sources/OrqDaemonKit/Design/{DesignSystems,DesignSystemService}.swift`, `Tests/OrqDaemonKitTests/{DesignSystemStoreTests,DesignSystemTests}.swift`; Modify `Sources/OrqDaemonKit/Design/DesignService.swift`, `Sources/OrqDaemonKit/{DesignCommands,CommandRouter,Daemon}.swift`, `Sources/OrqProtocol/Plugins.swift`

**Interfaces:**
- Consumes (2A): `DesignService` (registro de arquivos `files.json`, `editLink` guardado e regravado com `rehosted`, clientes por chamador, scrubber/`secrets`, `MCPStdioClient.command`), `FigcraftServer.ensureRunning`.
- Produces: `struct DesignSystem: Codable, Sendable { var id: UUID; var name: String; var fileId: UUID; var viewLink: String; var version: Int; var createdAt: Date }` em `<root>/design/systems.json` (0600, escrita atômica como `files.json`); `struct DesignSystemEvent: Codable, Sendable { var at: Date; var kind: String /* created|published|reverted|activated */; var version: Int?; var scope: String? /* "workspace" | "floor:<nome>" */; var by: String /* terminal name | "app" */; var reason: String; var snapshot: String? /* nome do .figcraft */; var files: [FileOutcome] }`, `struct FileOutcome: Codable, Sendable { var file: String; var ok: Bool; var detail: String }` em `<root>/design/systems/<id>/history.json` (últimos 200) e instantâneos `<root>/design/systems/<id>/v<N>.figcraft`.
- Produces: `actor DesignSystemService` (dono do daemon, ao lado de `DesignService`), com `create(name:from:reason:by:)`, `publish(name:reason:by:)`, `list()`, `history(name:)`.
- Comandos novos (plug-in `design` existente; todos `exposedToMCP` exceto os de admin):
  - `design.system.list` → `[{name, version, active: ["workspace", "floor:<f>"…]}]` (sem painel; qualquer terminal)
  - `design.system.create <name> [--from <outro>] --reason <texto>` → cria o arquivo de design (registro do 2A, nome = nome do DS), semeado ou copiado; publica a v1 → `{name, version: 1}`
  - `design.system.publish <name> --reason <texto>` → nova versão; exige alcance a um painel Design desse arquivo (exceto admin) → `{name, version}`
  - `design.system.history <name>` → eventos (sem links)
- Semente (sem `--from`): coleção `Tokens` com modos `Light`/`Dark` e variáveis de cor `bg`, `surface`, `text`, `muted`, `accent`, números `space/s|m|l|xl`, `radius/card`, `type/body|h3|h2|h1` (valores do portfólio do spike: `docs/superpowers/spikes/2026-10-20-figcraft/scripts` — `portfolio.py`), mais um estilo de texto `Heading` (tamanho ligado a `type/h2`) e um componente `Button` (frame com auto layout, fundo `accent`, raio `radius/card`, texto), num único `batch`.
- `--from`: o cliente interno entra no arquivo de origem e o publica com o endereço+chave do servidor (`library.publishToServer {server: wsURL}` cria um arquivo novo no servidor e devolve `file/edit/view`) — se o motor não aceitar isso, alternativa: `file.save` do origem → abrir o instantâneo num cliente interno e publicar; registrar a escolha.
- Publicar: no cliente interno "orq-ds" (já na sessão do arquivo, `collab.join` com o link regravado): `library.publishToServer {}` (omitido `server` porque está em sessão com edição); depois `file.save` para `v<N>.figcraft` em `<root>/design/systems/<id>/`; `version` = a do servidor no resultado. Sem mudanças → o motor recusa → `invalidArgs` "no changes to publish".
- Memória: `saveDecision(subject:title:body:cwd:by:)` extraído do caminho de `memory.save` (mesma validação, mesma escolha de repo pelo `cwd` do chamador; app sem cwd → global). `create`/`publish` gravam `design system <nome>` com o motivo.
- Evento de plug-in `designsystem.changed {name, version, kind}` (registrado no anel dos painéis Design e Design Systems; emitido em toda mudança).

- [ ] **Step 1: Contrato do motor (teste de integração real, `.enabled(if:)` com `vendor/figcraft`)** `teamLibraryContract`: servidor real em 127.0.0.1 + dois clientes headless: (a) arquivo A publicado na sessão e `library.publishToServer {}` → versão 1; (b) arquivo B: `library.add {path: <view link de A>}` → `library.list` mostra a biblioteca e seus assets; `library.bindVariable` de `bg` num retângulo → cor de A; (c) A muda `bg` e publica → B `library.updates` lista e `library.acceptUpdates` aplica a cor nova; (d) arquivo C (outro DS com `bg` diferente) publicado; B `library.add` C e `library.swap {from: A, to: C}` → cor de C e `unmatched` vazio; (e) um segundo cliente na sessão de B vê a cor nova sem recarregar. Registrar no relatório os formatos reais (nomes/ids de biblioteca, campos de resultado).
- [ ] **Step 2: Testes que falham:** `DesignSystemStoreTests` (`registryRoundTrip`, `historyKeepsLast200`, `namesValidatedLikeDesignFiles`, `registryIs0600`); `DesignSystemTests` (com o motor real): `createSeedsTokensAndPublishesV1` (`variable.list` no arquivo mostra os 12 tokens com Light/Dark; `style.list` tem `Heading`; `component.list` tem `Button`), `createFromCopiesTokens`, `publishBumpsVersionAndSnapshots`, `publishWithoutChangesIsRefused`, `publishNeedsReachToItsPanel` (terminal sem corda → `notConnected`; admin passa), `decisionRecordedWithReason` (memória do repo do chamador tem a decisão; segunda publicação substitui pelo mesmo assunto), `noLinkInAnyResult` (nenhum resultado/erro/histórico contém `figcraft://`, `token=`, `key=`).
- [ ] **Step 3:** FAIL. **Step 4:** implementar. **Step 5:** `swift test --filter "DesignSystem|DesignCommand"` → PASS.
- [ ] **Step 6:** Commit `feat(design): design system library, create and publish`.

### Task 2: Ativo por workspace/andar, troca, propagação e voltar atrás

**Files:** Modify `Sources/OrqCore/Workspace.swift`, `Sources/OrqDaemonKit/Design/{DesignSystemService,DesignService}.swift`, `Sources/OrqDaemonKit/{DesignCommands,PanelCommands,FloorCommands}.swift`, `Sources/OrqProtocol/{Plugins,Commands}.swift`; Test `Tests/OrqDaemonKitTests/DesignSystemTests.swift`, `Tests/OrqCoreTests/WorkspaceStoreTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `Workspace.designSystem: UUID?` e `Floor.designSystem: UUID?` (decode com `decodeIfPresent`, schema segue 3). Arquivo de design ganha `floorId: UUID?` no registro do 2A (`design.new` grava o andar do chamador; admin aceita `--floor`; arquivos antigos = térreo). O DS efetivo de um arquivo = `floor.designSystem ?? workspace.designSystem`. Arquivos que são o próprio design system ficam fora de qualquer escopo.
- Comandos:
  - `design.system.use <name> [--floor <f>] --reason <texto>` → define o ativo do escopo e aplica em cada arquivo de tela do escopo (para andar sem override: os arquivos do andar; para o workspace: térreo + andares sem override): se o arquivo ainda não tem biblioteca → `library.add {path: viewLink}`; se tinha a anterior → `library.add` da nova + `library.swap {from: anterior, to: nova}`. Resultado `{scope, system, files: [FileOutcome + unmatched]}`. Sem `--floor` + `--none` → limpa o ativo (não desfaz bindings).
  - `design.system.revert <name> --to <version> --reason <texto>` → publica o instantâneo `v<version>.figcraft` como nova versão do mesmo design system (cliente interno abre o instantâneo e faz `library.publishToServer` com o link de edição do arquivo do DS) e propaga.
  - `design.system.undo [--floor <f>] --reason <texto>` → volta o ativo do escopo para o anterior registrado no histórico (troca inversa).
  - Propagação após `publish`/`revert`: em cada arquivo que usa o DS → `library.acceptUpdates {ids: [<id da biblioteca>]}`.
- Permissões: `use`/`undo` sem `--floor` = admin ou Maestro; com `--floor` = admin ou o Maestro que criou o andar; outros → `notMaestro`. `revert` = como `publish`.
- Toda troca/volta grava decisão na Memória (assunto `design system ativo` ou `design system ativo (andar <f>)`, corpo com motivo, nome, versão e arquivos afetados) e um `DesignSystemEvent` `activated`/`reverted`; emite `designsystem.changed`.
- Criar arquivo de tela num escopo com DS ativo (`design.new` / `panel.open design --file novo`) → habilita a biblioteca já na criação.
- `floor.delete` limpa o override do andar removido.

- [ ] **Step 1: Testes que falham** (motor real): `useAppliesToScopeFiles` (dois arquivos no térreo usando A → `use C` → os dois mostram a cor de C), `swapReportsUnmatched` (C sem `muted` → `unmatched` contém `muted`), `swapReachesOtherSessionClient`, `floorInheritsWorkspaceUnlessOverridden`, `publishPropagatesToUsers` (A muda e publica → arquivo B mostra a cor nova sem ação), `revertRepublishesSnapshot` (v1 → v2 → revert para 1 → cor da v1 nos arquivos, versão do servidor 3), `undoSwapsBack`, `scopeWritePermissions` (terminal comum e Maestro de outro andar recusados; Maestro criador do andar e admin aceitos; nenhuma decisão gravada quando recusado), `useMissingSystemNotFound`, `newFileInScopeGetsLibrary`, `floorDeleteClearsOverride`, `oneFileFailureDoesNotUndoOthers` (um arquivo com cliente quebrado → `ok:false` nele, os outros trocados, histórico lista ambos), `workspaceFieldsRoundTrip` (decode sem os campos novos = nil).
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "DesignSystem|DesignCommand|Floor|WorkspaceStore"` → PASS.
- [ ] **Step 5:** Commit `feat(design): active design system per workspace and floor`.

### Task 3: Wrappers para agentes usarem o design system

**Files:** Modify `Sources/OrqDaemonKit/Design/DesignSystemService.swift`, `Sources/OrqDaemonKit/DesignCommands.swift`, `Sources/OrqProtocol/Plugins.swift`; Test `Tests/OrqDaemonKitTests/DesignSystemTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; resolução de painel/arquivo do 2A.
- Comandos (presos a painel Design — corda/doca; arquivo = o do painel; biblioteca = o DS efetivo do arquivo, escolhida pelo daemon; sem DS efetivo → `invalidArgs` "no active design system for this file"):
  - `design.system.tokens` → coleções/variáveis/modos/estilos/componentes publicados (`library.list {assets: true}` filtrado para a biblioteca efetiva; sem links/ids de servidor)
  - `design.system.bind --variable <nome> --field <campo> --ids <id,…>` → `library.bindVariable`
  - `design.system.style --style <nome> --ids <id,…> [--target fill|stroke|text|effect]` → `library.applyStyle`
  - `design.system.place --component <nome> [--x n --y n]` → `library.place`
  - `design.system.mode --mode <nome> [--ids …]` → `library.setVariableMode` (ex.: Light/Dark)
- Os wrappers montam os params do `library.*` a partir de campos validados (nomes ≤ 200 chars, ids da forma do figcraft, números finitos); nada vindo do agente vira `library`/`server`/`path`. Erros passam pelo scrubber.
- `design.help` passa a listar também os `design.system.*` com uma linha de ajuda cada.

- [ ] **Step 1: Testes que falham** (motor real): `agentBindsTokenFromActiveSystem` (retângulo criado via `design.run` + `design.system.bind --variable bg --field fill` → cor de A; após `use C` → cor de C), `agentAppliesStyleAndPlacesComponent` (`Heading` e `Button` da semente do Task 1), `modeSwitchesLightDark`, `wrappersNeedCord` (terminal sem corda → `notConnected`), `noActiveSystemIsClearError`, `agentCannotPickLibraryOrServer` (params extras `library`/`server`/`path` ignorados ou recusados; `design.run library.bindVariable` continua recusado pela lista do 2A).
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "DesignSystem|DesignCommand"` → PASS.
- [ ] **Step 5:** Commit `feat(design): agent wrappers for the active design system`.

### Task 4: Painel Design Systems no app + docs

**Files:** Create `Sources/OrqPlugins/DesignSystemsPanel.swift`, `Tests/OrqPluginsTests/DesignSystemsPanelTests.swift`; Modify `Sources/OrqProtocol/Plugins.swift` (plug-in `designsystems`, doca, sem comandos de agente), `Sources/OrqApp/OrqApp.swift`, `README.md`, roteiro da Fase 2

**Interfaces:**
- Consumes: `design.system.list|history|create|publish|use|undo|revert` (admin via `PanelHostContext.call`, timeout de design 60 s — `DaemonClient.adminTimeout` já cobre `design.*`).
- Produces: plug-in `designsystems` (título `Design Systems`, placements doca direita/esquerda/baixo, padrão doca direita), `DesignSystemsPanel: PluginPanelView` (SwiftUI, padrão do `MemoryPanel`).
- UI (Português): lista de design systems com versão e onde está ativo; seletor de escopo (Workspace / cada andar); botão **Usar neste escopo** (pede motivo); **Desfazer troca**; **Novo design system…** (nome, "a partir de", motivo); **Publicar versão** (motivo) para o selecionado; **Histórico** com eventos (quando, quem, motivo, versão, arquivos ok/erro, `unmatched`) e **Voltar para esta versão** em eventos de publicação; resultado por arquivo mostrado após cada ação (lista de `unmatched` visível). Atualiza ao receber `designsystem.changed` ou ao abrir.
- Painel Design (2A) não muda; a UI do figcraft mostra a biblioteca (somente leitura) e os modos.

- [ ] **Step 1: Testes que falham** (`DesignSystemsPanelTests`, com `call` falso): `listsSystemsWithActiveScopes`, `useSendsScopeAndReason` (motivo vazio bloqueia o botão), `historyShowsRevertForPublishes`, `showsUnmatchedAfterUse`, `refreshesOnChangedEvent`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift build`; suíte inteira com `perl -e 'alarm 900; exec @ARGV' swift test` → PASS; `scripts/bundle-app.sh` ok.
- [ ] **Step 5:** README: seção "Design systems" (o que é, como criar/usar/publicar/voltar, comandos `orq design system …`, escopo workspace/andar, quem pode trocar, limitações). Roteiro: 2B aponta este plano. Commit `feat(app): Design Systems panel`.

---

## Limitações conhecidas (aceitas neste plano)

- A troca casa por nome (variáveis por coleção+nome+tipo, estilos por nome+tipo, componentes/variantes por nome); o que não casa fica no design system anterior e aparece em `unmatched`.
- A UI web do figcraft não opera bibliotecas (sem suporte próprio): trocar/publicar/voltar é pelo painel Design Systems ou pelos comandos; a UI mostra o resultado ao vivo.
- "Voltar" de publicação cria uma versão nova (o servidor só guarda a última); o histórico completo fica nos instantâneos do Orq.
- Troca entre arquivos não é transacional: falha em um arquivo não desfaz os outros (reportado por arquivo).
