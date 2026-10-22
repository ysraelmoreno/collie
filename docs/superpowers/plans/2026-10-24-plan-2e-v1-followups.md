# Plano 2E — Pendências da v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fechar as seis pendências deixadas pelos planos 2A–2D, pedidas pelo usuário em 2026-10-24: agentes criam links (`text.link`); painéis do app recebem eventos de plug-in e se atualizam sozinhos; artifacts de página são por página; a importação de HTML liga cores ao design system ativo; o painel Design entra na sessão sem o clique "Entrar"; e o painel Design usa WebGPU quando o WebKit tiver, com WebGL2 de reserva.

**Architecture:** Mudanças pequenas e locais sobre o que existe: a lista permitida do 2A ganha `text.link` com validação de URL; o `ui.events` que o app já assina passa a entregar `pluginEvent` à `PanelViewStore`, que repassa ao painel; a chave do artifact de página inclui a página; o importador do 2D roda um passo extra de `variable`/biblioteca depois do lote; um patch `0004` no figcraft-web entra direto quando o link vem no fragmento; o painel Design sonda `navigator.gpu` antes de escolher a URL.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, WebKit; figcraft v0.7.0 + patches 0001–0003 (+ 0004 aqui); Rust só no patch. Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §6.1 (eventos entregues a agentes **e a outros plug-ins**), §7.1, §7.2 ("HTML exportado sai com o CSS do sistema ativo"; telas referenciam variáveis do sistema), §7.3. Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md` (linha 2E nova). Base: `main` depois do merge do 2D.

## Global Constraints

- **Corda é a única permissão**; nada muda nas regras de alcance de 2A–2D.
- **Nada sai da máquina** sem pedido do usuário: links criados por agentes são só dados no documento; o patch do figcraft não liga servidor público (`FIGCRAFT_DEFAULT_SERVER=` vazio continua).
- Links aceitos só com esquemas seguros: `http`, `https`, `mailto`, `tel`, `#…`, `/…`, relativos sem `:` antes do primeiro `/` (mesma regra de `ExportSemantics.safeHref`).
- Segredos do 2A: o link de edição só entra no fragmento da URL do painel Design (como hoje); nada de link/chave em evento, log ou resultado.
- Clean-room: patch novo é diff mínimo no figcraft (MIT/Apache), em `patches/figcraft/0004-*.patch`; rebuild com `scripts/build-figcraft.sh` (aprovado nos planos anteriores).
- Nada de I/O bloqueante no pool cooperativo; WebKit só no `MainActor`; textos de UI em português; testes com fakes + WebKit real + build real do figcraft (`realBuilt`, suíte `.serialized`).

## Review Focus

1. **Agente põe `javascript:` ou `data:` num link** (`text.link`, `text.style {hyperlink}`, `node.set {hyperlink}`) → recusado com `.invalidArgs`, documento intacto. Teste: Task 1 `unsafeLinksRefusedEverywhere`.
2. **Rajada de eventos** (dezenas de `artifact.exported` seguidos) → o painel atualiza no máximo a cada 500 ms, sem fila crescendo. Teste: Task 2 `eventsCoalesce`.
3. **Cor da tela igual a duas variáveis do sistema** (ex.: `ink` e `ink-bright` com o mesmo hex) → liga à primeira por nome (ordem alfabética), determinístico; cor sem par fica literal. Teste: Task 4 `bindingIsDeterministic`.
4. **Página que perde o link de entrada** (servidor reiniciou, link reescrito) → o painel entra direto com o link novo, sem diálogo; link ruim mostra o erro do figcraft como antes. Teste: Task 5 (checklist + teste do patch).
5. **WKWebView sem WebGPU** (macOS 15 sem a flag) → sonda devolve falso rápido (≤ 2 s) e o painel usa `?webgl` como hoje; nunca tela preta. Teste: Task 6 `probeFallsBackToWebGL`.

---

## File Structure

```
Sources/OrqDaemonKit/Design/DesignService.swift      (lista permitida + validação de links)
Sources/OrqClient/DaemonClient.swift                 (entrega pluginEvent)
Sources/OrqPlugins/PluginPanelView.swift             (receive(event:payload:) + PanelViewStore.deliver)
Sources/OrqPlugins/{ArtifactsPanel,DesignSystemsPanel}.swift   (atualizar ao receber evento)
Sources/OrqApp/OrqApp.swift                          (liga o encaminhamento)
Sources/OrqDaemonKit/{DesignCommands,ArtifactImport,ArtifactCommands}.swift  (quem recebe cada evento; falha também emite)
Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift   (chave por página)
Sources/OrqDaemonKit/Design/HTMLImport.swift         (registra usos de cor por passo)
Sources/OrqDaemonKit/ArtifactImport.swift            (liga cores às variáveis do sistema ativo)
patches/figcraft/0004-web-auto-join.patch
Sources/OrqPlugins/DesignPanel.swift                 (sonda WebGPU; URL sem ?webgl quando houver)
Tests/… (por task), README.md, roadmap
```

---

### Task 1: Agentes criam links, com esquema validado

**Files:** Modify `Sources/OrqDaemonKit/Design/DesignService.swift`; Test `Tests/OrqDaemonKitTests/DesignCommandTests.swift`

**Interfaces:**
- Produces: `text.link` sai da lista de recusados (comentário ~linha 768); `checkParams` recusa (`.invalidArgs` "link must be http(s), mailto, tel, #anchor or a relative path") quando `text.link {url}`, `text.style {hyperlink}` ou `node.set {hyperlink}` (também dentro de `design.batch`, que já passa por `checkParams` por passo) traz um valor que `ExportSemantics.safeHref` recusa; `hyperlink: null`/vazio (remover link) é aceito.
- [ ] **Step 1: Testes:** `agentCanLink` (fake: `design.run text.link --params '{"url":"https://example.com","ids":[1]}'` → chega ao motor); `unsafeLinksRefusedEverywhere` (`javascript:alert(1)`, `data:text/html,x`, `JAVASCRIPT:x`, ` javascript:x` em `text.link`, `text.style {hyperlink}`, `node.set {hyperlink}` e dentro de um `design.batch` → `.invalidArgs`, nenhum chamado ao motor no log do fake); `linkRemovalAllowed` (`hyperlink: null`). Atualizar o teste do 2C que esperava `text.link` recusado.
- [ ] **Step 2–4:** FAIL → implementar → PASS. README: tirar "agentes não podem usar `text.link`"; o teste do motor real do 2C (`realEngineHTMLArtifact`) volta a ter o passo `text.link` e a asserção `<a href="https://example.com">`. **Step 5:** Commit `feat(design): agents can add safe links`.

### Task 2: Eventos de plug-in chegam aos painéis do app

**Files:** Modify `Sources/OrqClient/DaemonClient.swift`, `Sources/OrqPlugins/{PluginPanelView,ArtifactsPanel,DesignSystemsPanel}.swift`, `Sources/OrqApp/OrqApp.swift`, `Sources/OrqDaemonKit/{DesignCommands,ArtifactImport}.swift`; Test `Tests/OrqClientTests/…`, `Tests/OrqPluginsTests/{PanelViewStoreTests,ArtifactsPanelTests,DesignSystemsPanelTests}.swift`, `Tests/OrqDaemonKitTests/ArtifactImportTests.swift`

**Interfaces:**
- Produces: `DaemonClient.pluginEventHandler: (@MainActor (UUID, String, JSONValue) -> Void)?` chamado para cada `.pluginEvent(panel:name:payload)` do `ui.events` (hoje ignorado em `DaemonClient.swift:174`); `PluginPanelView.receive(event: String, payload: JSONValue)` com implementação padrão vazia; `PanelViewStore.deliver(panel: UUID, event: String, payload: JSONValue)` (só painéis com view viva; sem view, descarta).
- Painéis: `ArtifactsModel` e `DesignSystemsModel` atualizam (`refresh()`) ao receber `artifact.*` / `designsystem.changed`, **agrupando** — no máximo um refresh a cada 500 ms (o último evento dentro da janela dispara um refresh ao fim dela).
- Daemon: `designsystem.changed` vai também para os painéis `designsystems` (hoje só `design`); falha de importação em segundo plano emite `artifact.imported` com `{id, error}` (texto scrubbed) aos painéis `artifacts`.
- [ ] **Step 1: Testes:** `clientForwardsPluginEvents` (frame `.pluginEvent` → handler com os mesmos valores); `storeDeliversToLiveView` (view viva recebe; painel sem view não cria view); `eventsCoalesce` (20 eventos em 100 ms → 1 refresh imediato + no máximo 1 ao fim da janela; call falso conta `artifact.list`); `designSystemsPanelRefreshesOnEvent`; `failedImportEmits` (fake sem app host → evento `artifact.imported` com `error`).
- [ ] **Step 2–4:** FAIL → implementar → PASS. README: tirar "o painel não atualiza sozinho". **Step 5:** Commit `feat(plugins): deliver plugin events to app panels`.

### Task 3: Artifact de página por página

**Files:** Modify `Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift`, `Sources/OrqDaemonKit/ArtifactCommands.swift`; Test `Tests/OrqDaemonKitTests/ArtifactTests.swift`

**Interfaces:**
- Produces: a chave de reuso de `newVersion` passa a ser `(fileId, node ?? page)`; `newVersion` recebe `page: String?` (o do snapshot do chamador, como o 2C já registra). Registros antigos com `node == nil` e `page == nil` casam com qualquer página **só uma vez**: a primeira exportação de página depois do upgrade adota o registro e grava o `page` (sem duplicar o artifact existente).
- [ ] **Step 1: Testes:** `pagesAreSeparateArtifacts` (export sem `--node` na página A e na B → dois artifacts; reexport de cada um usa a sua página); `legacyPageRecordAdopted` (registro antigo sem `page` + export da página A → mesma id, `page` = A; export da B → id nova).
- [ ] **Step 2–4:** FAIL → implementar → PASS. README: tirar a limitação. **Step 5:** Commit `fix(artifacts): one artifact per exported page`.

### Task 4: Importação liga cores ao design system ativo

**Files:** Modify `Sources/OrqDaemonKit/Design/HTMLImport.swift`, `Sources/OrqDaemonKit/ArtifactImport.swift`, `Sources/OrqDaemonKit/Design/DesignSystemService.swift` (se precisar expor o bind interno); Test `Tests/OrqDaemonKitTests/{HTMLImportTests,ArtifactImportTests}.swift`

**Interfaces:**
- Produces: `HTMLImport.steps` devolve também `colorUses: [(step: Int, field: String /* fill|stroke|textFill */, hex: String /* #RRGGBB ou #RRGGBBAA, maiúsculas */)]` (campo novo no retorno; chamadores atualizados).
- Produces: depois do `batch` e antes do export, se o arquivo novo tem design system ativo: lê as variáveis de cor do sistema (o mesmo caminho que `design.system.tokens` usa: `library.list {assets: true}` no cliente do daemon — nomes e valores do modo atual), monta `hex → nome` (empate: nome em ordem alfabética), e liga cada uso com valor **idêntico** (sem diferenciar maiúsculas, alfa incluído; `#RRGGBB` == `#RRGGBBFF`) pelo mesmo bind de biblioteca que `design.system.bind` usa (`library.bindVariable` com o campo do uso), em **um** `batch` extra com label `Ligar cores ao design system`. Cor sem par fica literal. Aviso `bound <n> colors to <sistema>`. Falha do passo extra → aviso, a importação segue.
- [ ] **Step 1: Testes:** `colorUsesRecorded` (landing: o fundo e o texto do h1 aparecem em `colorUses` com o passo certo); `bindingIsDeterministic` (mapa com dois nomes para o mesmo hex → o alfabético); `importBindsMatchingColors` (fake com sistema ativo cujo `bg` = cor do body do fixture → log do fake tem `library.bindVariable` para esse passo, um único batch extra); `bindFailureIsWarning`.
- [ ] **Step 2–4:** FAIL → implementar → PASS. Teste do motor real: `realEngineImportsLanding` com um design system criado (`design.system.create`) cujo `bg` = cor do body → `design.inspect` da raiz mostra a variável ligada. README: tirar a limitação. **Step 5:** Commit `feat(import): bind imported colors to the active design system`.

### Task 5: Painel Design entra direto (sem "Entrar")

**Files:** Create `patches/figcraft/0004-web-auto-join.patch`; Modify `Sources/OrqPlugins/DesignPanel.swift` (só se o fragmento mudar), README, checklist; Test `Tests/OrqPluginsTests/DesignPanelTests.swift`

**Interfaces:**
- Produces: patch em `apps/figcraft-web/src/web.rs`: quando `#join=<link>` vem **e** o fragmento também traz `&orq=1`, chama `fig.run("collab.join", json!({"code": link}))` direto (o mesmo comando do botão do diálogo, `crates/ui-egui/src/live.rs:685`) em vez de `open_invite`; sem `orq=1`, o comportamento do upstream fica (diálogo de confirmação). `DesignPanel` passa a montar `…#join=<link>&orq=1`. O link vem só do daemon (`design.link`, admin) — nunca de página ou agente.
- [ ] **Step 1:** Patch + `scripts/build-figcraft.sh` + `scripts/check-figcraft.sh` → `ok`. Teste do patch: `figcraft-web` tem testes de `query.rs` — acrescentar um teste Rust de `orq_auto(fragment) -> bool` no próprio patch (`cargo test -p figcraft-web` dentro do `vendor/figcraft-src`, sem `xtask`).
- [ ] **Step 2: Teste Swift:** `designPanelURLRequestsAutoJoin` (a URL montada termina com `&orq=1`, link escapado como hoje). Teste WebKit real (gated `realBuilt`): o painel com um servidor real entra na sessão sem clique (o daemon vê o segundo par em `collab.peers` em ≤ 15 s).
- [ ] **Step 3:** Commit `feat(design): design panel joins its session without the dialog`.

### Task 6: WebGPU quando houver, WebGL2 de reserva

**Files:** Modify `Sources/OrqPlugins/DesignPanel.swift`; Test `Tests/OrqPluginsTests/DesignPanelTests.swift`

**Interfaces:**
- Produces: `@MainActor enum GPUProbe { static func webGPUAvailable() async -> Bool }` — uma vez por execução do app (memorizado): WKWebView fora da tela carregando `about:blank`, avalia `navigator.gpu ? (await navigator.gpu.requestAdapter()) !== null : false` com prazo de 2 s (prazo → `false`). `DesignPanel` usa `index.html` **sem** `?webgl` quando `true`, com `?webgl` quando `false`. Variável de ambiente `ORQ_DESIGN_GPU=webgl|webgpu` força um dos dois (diagnóstico). Se a página com WebGPU falhar ao iniciar (o figcraft-web escreve "FigCraft failed to start" no elemento de carregamento — detectar por script de usuário que observa esse texto e posta ao app), recarrega com `?webgl` e memoriza `false`.
- [ ] **Step 1: Testes:** `probeReturnsQuickly` (WebKit real: resposta em ≤ 2,5 s, qualquer valor); `probeFallsBackToWebGL` (probe forçada a `false` → URL com `?webgl`); `envOverride` (as duas formas); `startFailureReloadsWithWebGL` (página de teste que escreve o texto de falha → nova carga com `?webgl`).
- [ ] **Step 2:** Medir nesta máquina e anotar no relatório e no README: `webGPUAvailable()` resultado, e o backend que o figcraft registra (`figcraft-web: wgpu backend …` no console do WKWebView) com e sem `?webgl`.
- [ ] **Step 3:** Commit `feat(design): use WebGPU in the design panel when available`.

### Task 7: Ida e volta + docs

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`; Create (scratchpad) `plan2e-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem).
- [ ] **Step 2:** Rodar de novo `ImportCaseTests` com o caso real do usuário (scratchpad, fora do repo) e conferir que as cores do caso ligam (com um design system criado no teste a partir dos tokens; só no scratchpad).
- [ ] **Step 3:** README: limitações atualizadas (tirar as seis). Roteiro: linha 2E "em execução". Checklist humana no scratchpad (links por agente; painel atualiza sozinho; export de duas páginas; import com sistema ativo; painel Design sem "Entrar"; backend do WebGPU).
- [ ] **Step 4:** Commit `docs: plan 2E follow-ups`.
