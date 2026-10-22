# Plano 3D — Partituras — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Partituras são modelos reutilizáveis de equipe: terminais com papéis, cordas, painéis e, se pedir, um andar. Elas vêm de fábrica, são salvas a partir do canvas (ou pelo Maestro), exportadas e importadas por arquivo, e aplicadas **tudo ou nada**: se qualquer parte falhar, o Orq desfaz o que esta aplicação criou e diz o motivo.

**Architecture:** O formato (`Partitura`, JSON versionado) e a validação são puros em `OrqCore`. O daemon guarda a biblioteca (`PartituraStore`, um arquivo por partitura + as de fábrica em código) e aplica com um `PartituraApplier` que faz uma checagem prévia completa antes de criar qualquer coisa. Depois ele cria na ordem andar → terminais → espera "pronto" → cordas → painéis → prompts, registrando cada passo num diário. Se algo falha, desfaz esse diário de trás para frente. Para isso ele reusa as peças do `recruit`/`panel.open`/`floor.create` da v1, sem dar poder novo a ninguém. O app só cuida da tela: lista, prévia, nome, posição no canvas. Ele recebe as posições relativas no evento `partitura.applied`.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI/AppKit (sheet + menus do canvas). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-24-phase3-design.md` §6 (Partituras), §2 (anti-meta: partitura aplicada pela metade), §3 (segredos, nada apagado sem o usuário), §8. v1 `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §5 (cordas, Maestro, andares). Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`. Base: `main` (só depende da v1; pode rodar em paralelo a 3A–3C).

## Global Constraints

- **Corda é a única permissão; a partitura não dá poder novo:** aplicada por um Maestro, tudo nasce ligado por corda a ele (como `recruit`), andares seguem as regras de `floor.create` da v1, painéis as de `panel.open`. App (admin) pode tudo.
- **Tudo ou nada:** só existe resultado completo ou nenhum. O desfazer remove **só** o que esta aplicação criou e ainda não tem trabalho do usuário (terminais criados por ela, andar e branch criados por ela **sem commits além da base**). Fora isso nada é apagado (spec §6.3).
- **Nunca no arquivo:** histórico de terminal, tokens, links do figcraft, variáveis de ambiente, caminhos absolutos, `cwd`, serial de dispositivo. O repositório é o do lugar onde se aplica.
- **Arquivo importado é não confiável:** limite de 256 KiB, `format == 1`, até 20 terminais e 20 painéis, nomes/ids/presets/plug-ins válidos, campos desconhecidos ignorados; antes de confirmar, o app mostra tudo que será criado, **cada comando** (`preset: custom`) e **cada prompt** inicial.
- Clean-room: formato e textos próprios; extensão `.orqpartitura`; nada do Maestri.
- Protocolo `v: 1`, só comandos/eventos novos; nada de I/O bloqueante no pool cooperativo; textos de UI em português.

## Review Focus

1. **Um agente não fica pronto** (o segundo de quatro trava no início) → depois do prazo, tudo o que a aplicação criou some (terminais, cordas, painéis, andar), nada pré-existente é tocado, erro "‹terminal› não ficou pronto em 60 s". Teste: Task 3 `rollbackOnAgentTimeout`.
2. **Nome já em uso / andar já existe / repositório não é git** → recusado na checagem prévia, **antes** de criar qualquer coisa. Teste: Task 3 `preflightCreatesNothing`.
3. **Andar ganhou commit durante a aplicação** (um agente commitou antes da falha) → o desfazer mantém andar e branch e avisa ("andar ‹nome› mantido: tem commits"). Teste: Task 3 `rollbackKeepsFloorWithCommits`.
4. **Salvar painel com estado secreto** (Design com id de arquivo, `serial` de dispositivo, chave desconhecida) → só entram as chaves permitidas (Navegador `url`; Design `file` como **nome**; `storage`); painel de dispositivo não entra (aviso). Teste: Task 2 `saveKeepsOnlyAllowedState`.
5. **Arquivo hostil** (300 KiB, `format: 2`, corda para chave inexistente, `cwd`/`env` no JSON, preset desconhecido, 50 terminais) → recusado com motivo, biblioteca intacta; `cwd`/`env` simplesmente ignorados. Teste: Task 1 `validationRejects`, Task 2 `importRejectsAndKeepsLibrary`.

---

## File Structure

```
Sources/OrqCore/Partitura.swift                    formato, validação, slug de nomes, partituras de fábrica
Sources/OrqDaemonKit/Partituras/PartituraStore.swift    biblioteca em <root>/partituras/
Sources/OrqDaemonKit/Partituras/PartituraApplier.swift  checagem prévia + aplicar com diário + desfazer
Sources/OrqDaemonKit/PartituraCommands.swift       partitura.* (app e Maestro)
Sources/OrqDaemonKit/{CommandRouter,AskCoordinator,MemoryCommands}.swift
Sources/OrqProtocol/Commands.swift                 (+ partitura.*)
Sources/OrqApp/PartiturasSheet.swift               lista, prévia, aplicar, salvar, importar/exportar
Sources/OrqApp/{CanvasViewport,OrqApp}.swift       menus do canvas, posição ao receber partitura.applied
Tests/OrqDaemonKitTests/{PartituraFormatTests,PartituraStoreTests,PartituraApplyTests}.swift
Sources/OrqPlugins/PartiturasModel.swift          modelo testável da sheet
Tests/OrqPluginsTests/PartiturasModelTests.swift, Tests/OrqCanvasTests/ (placeFrames)
README.md
```

---

### Task 1: Formato, validação e partituras de fábrica

**Files:** Create `Sources/OrqCore/Partitura.swift`, `Tests/OrqDaemonKitTests/PartituraFormatTests.swift`

**Interfaces:**
- Produces (OrqCore, `Codable, Sendable, Equatable`):
  - `struct PartituraTerminal { var key: String /* [a-z0-9-], 1–24, único */; var preset: Preset; var command: String? /* só custom, ≤ 1 000 */; var role: String? /* prompt inicial, ≤ 4 000 */; var isMaestro: Bool; var frame: PartituraFrame? }`
  - `struct PartituraPanel { var key: String; var pluginId: String; var placement: PanelPlacement; var state: [String: JSONValue] /* só chaves permitidas */; var frame: PartituraFrame? }`
  - `struct PartituraFrame { var x, y, w, h: Double }` (relativo ao canto superior esquerdo da partitura).
  - `struct Partitura { var format: Int = 1; var id: String /* slug */; var name: String; var summary: String; var wantsFloor: Bool; var terminals: [PartituraTerminal]; var panels: [PartituraPanel]; var cords: [[String]] /* pares de chaves: terminal–terminal ou terminal–painel */; var builtIn: Bool /* não serializado */ }`
  - `enum PartituraFormat { static let maxBytes = 256 * 1024; static let maxTerminals = 20; static let maxPanels = 20; static func decode(_ data: Data) throws(ProtocolError) -> Partitura; static func encode(_ p: Partitura) throws -> Data /* JSON ordenado, legível */; static func validate(_ p: Partitura) throws(ProtocolError); static let allowedState: [String: Set<String>] = ["browser": ["url", "storage"], "design": ["file", "storage"], "memory": [], "artifacts": [], "designsystems": [], "work": []] /* plug-in fora daqui (ex.: device) não entra em partitura */ }`
  - `static func memberName(apply: String, key: String) -> String` = `"\(slug(apply))-\(key)"`; `slug` = minúsculas, acentos removidos, não-`[a-z0-9]` → `-`, colapsado, aparado, ≤ 24.
- Validação (`.invalidArgs` com o motivo): `format != 1`; bytes > `maxBytes`; contagens; chaves inválidas ou repetidas (entre terminais **e** painéis); `command` sem `custom` ou `custom` sem `command`; cordas com chave desconhecida, painel–painel, ou repetidas; `pluginId` fora de `allowedState`; chave de estado fora da lista do plug-in; no máximo **um** terminal `isMaestro`; `url` do Navegador só `http`/`https`. Campos desconhecidos no JSON são ignorados (decodificação tolerante).
- Partituras de fábrica (`Partitura.factory: [Partitura]`, `builtIn: true`, textos originais):
  - **`feature-fullstack`** "Feature fullstack", `wantsFloor: true`: `maestro` (claude, Maestro, papel: "Você coordena esta feature. Quebre o trabalho em partes, delegue ao backend e à interface pelas cordas, peça revisão ao revisor antes de dar como pronto e mantenha `orq work` atualizado."), `backend` (claude, "Você implementa a parte de servidor e dados desta feature, com testes. Responda ao Maestro com o que mudou e o que falta."), `interface` (claude, "Você implementa a interface desta feature. Use o painel Design como referência e o Navegador para conferir o resultado. Responda ao Maestro com o que mudou."), `revisor` (claude, "Você revisa o que o Maestro pedir: procure bugs, casos não cobertos e testes faltando. Seja direto; não reescreva o código dos outros."); painéis `design` (design, canvas, `file` = "Feature") e `navegador` (browser, canvas); cordas maestro–backend, maestro–interface, maestro–revisor, interface–design, interface–navegador.
  - **`investigar-bug`** "Investigar bug", `wantsFloor: false`: `maestro` (claude, Maestro, "Você coordena a investigação de um bug. Peça ao investigador a causa com evidência e a quem testa um teste que falhe antes da correção."), `investigador` (claude, "Você encontra a causa raiz do bug com evidência (logs, reprodução, leitura do código). Não corrija antes de explicar a causa ao Maestro."), `testes` (claude, "Você escreve o teste que reproduz o bug e falha agora. Mostre a falha ao Maestro."); cordas maestro–investigador, maestro–testes.
  - Frames de fábrica: Maestro em (0,0), os outros numa linha à direita com 40 pt de folga; painéis abaixo de quem os usa. Tamanho dos terminais = o padrão do canvas da v1.
- [ ] **Step 1: Testes:** `roundTrip` (encode → decode igual, sem `builtIn`); `factoryIsValid` (as duas passam em `validate`); `validationRejects` (um caso por regra acima, cada um com o motivo esperado); `unknownFieldsIgnored` (JSON com `cwd`, `env`, `token` → decodifica sem eles); `memberNames` ("Feature X" + `backend` → `feature-x-backend`; "Ação ç" → `acao-c-…`; nome longo cortado em 24).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter PartituraFormatTests`). **Step 5:** Commit `feat(partituras): format, validation and factory scores`.

### Task 2: Biblioteca, salvar e importar/exportar

**Files:** Create `Sources/OrqDaemonKit/Partituras/PartituraStore.swift`, `Sources/OrqDaemonKit/PartituraCommands.swift`, `Tests/OrqDaemonKitTests/PartituraStoreTests.swift`; Modify `Sources/OrqDaemonKit/CommandRouter.swift`, `Sources/OrqProtocol/Commands.swift`

**Interfaces:**
- Produces: `actor PartituraStore { init(dir: URL /* <root>/partituras */); func list() -> [Partitura] /* fábrica + salvas, por nome */; func get(_ id: String) -> Partitura?; func put(_ p: Partitura) throws /* valida; id de fábrica → .invalidArgs "partitura de fábrica não pode ser substituída" */; func setAside(_ id: String) throws /* move para <dir>/.removed/<id>-<epochMs>.orqpartitura */ }` — um arquivo `<id>.orqpartitura` (0600, atômico, fora do pool) por partitura.
- Comandos:
  - `partitura.list` → `[{id, name, summary, wantsFloor, builtIn, terminals: n, panels: n}]` (app e qualquer Maestro).
  - `partitura.get {id}` → a partitura completa (app e Maestro).
  - `partitura.save {name, summary?, terminals: [nome], panels?: [nome], frames?: {nome: {x,y,w,h}}, roles?: {nome: texto}, wantsFloor?: Bool, replace?: Bool}` → `{id, warnings}`. App: quaisquer terminais/painéis; Maestro: só os que alcança por corda **mais ele mesmo** (fora do alcance → `.notConnected`). Monta a partitura a partir dos registros: `key` = nome do terminal/painel sem o prefixo comum `"<x>-"` quando todos o têm, slug; `preset`/`command`/`isMaestro` do registro; cordas = as conexões **entre** os selecionados; estado do painel filtrado por `allowedState` (Design: id do arquivo → **nome** do arquivo pelo registro de design; arquivo sumido → sem `file`, aviso); painéis de plug-in fora da lista ficam de fora com aviso `"painel ‹nome› (‹plugin›) não entra em partituras"`. `frames` relativos ao menor x/y; sem `frames` (Maestro), nenhum frame. `id` = slug do nome; já existe e `replace` não veio → `.invalidArgs` "já existe uma partitura ‹nome›".
  - `partitura.remove {id}` (só app) → `setAside`.
  - `partitura.import {json: String}` (só app) → `{id, preview}`, valida com `PartituraFormat.decode`, grava; `partitura.export {id}` (só app) → `{json}`. O app lê e grava os arquivos com os painéis do sistema (Task 4); o daemon nunca abre caminho vindo do usuário aqui.
  - `preview` (também usado pela Task 4): `{terminals: [{key, preset, isMaestro, command?, role?}], panels: [{key, pluginId, state}], cords, wantsFloor}`.
- [ ] **Step 1: Testes:** `factoryListedAndReadOnly`; `saveFromCanvas` (dois claude ligados + Navegador ligado a um → partitura com cordas certas, `url` do navegador, frames relativos); `saveKeepsOnlyAllowedState` (Design com `file` = id → nome; painel device → fora com aviso; chave extra no estado → fora); `maestroSavesOnlyReach` (Maestro com terminal fora do alcance → `.notConnected`; dentro → ok, sem frames); `importRejectsAndKeepsLibrary` (300 KiB, `format: 2`, corda inválida → erro, `list()` igual); `exportImportRoundTrip`; `removeSetsAside` (arquivo em `.removed/`, não apagado); `terminalsCannotImportOrRemove`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter PartituraStoreTests`). **Step 5:** Commit `feat(partituras): library, save from canvas, import and export`.

### Task 3: Aplicar tudo-ou-nada

**Files:** Create `Sources/OrqDaemonKit/Partituras/PartituraApplier.swift`, `Tests/OrqDaemonKitTests/PartituraApplyTests.swift`; Modify `Sources/OrqDaemonKit/{PartituraCommands,AskCoordinator,CommandRouter,FloorCommands,PanelCommands}.swift`, `Sources/OrqProtocol/Commands.swift`

**Interfaces:**
- Produces: `AskCoordinator.waitReady(_ id: UUID, timeout: Duration) async -> Bool` (o mesmo sinal de prontidão que segura o primeiro prompt do `recruit`; falso se o processo morreu ou o prazo passou).
- Produces: `partitura.apply {id, name: String, floor?: Bool /* inverte wantsFloor */, cwd?: String /* app: obrigatório; Maestro: o seu */}` → `{terminals: [{key, id, name}], panels: [{key, id, name}], floor?: {id, name}, frames: {id: {x,y,w,h}}, warnings}`; emite o evento de workspace `partitura.applied {by: UUID?, anchor: UUID? /* Maestro que aplicou */, frames: {id: rect}}` para o app posicionar.
- Quem aplica: app (tudo); Maestro (`maestroOnly` no MCP): o terminal `isMaestro` da partitura **não é criado** — o Maestro que aplicou ocupa esse papel (cordas para a chave do Maestro vão para ele; o `role` do Maestro não é injetado nele); todo terminal criado ganha corda com o Maestro que aplicou (como `recruit`), além das cordas da partitura; andar criado com `createdBy` = esse Maestro; painéis abertos com as regras de `panel.open` para Maestro.
- **Checagem prévia** (nada criado se falhar, `.invalidArgs` com o motivo): partitura válida; todos os nomes (`memberName` para terminais e painéis; andar = `slug(name)`) livres entre terminais, painéis e andares, e reservados (`reserve`) durante toda a aplicação; `cwd` existe; com andar, `cwd` está num repositório git (`FloorManager.repoRoot`); plug-ins registrados; presets `claude`/`codex` com o executável no `PATH` do daemon (senão "‹preset› não encontrado").
- Ordem e diário (cada passo bem-sucedido entra no diário): 1) andar (`FloorManager.create` + gravar, como `floor.create`); 2) terminais (`launch` + `ensureFloor`, no andar se houver, senão no `cwd`); 3) `waitReady` de cada um com prazo **60 s** (em paralelo); 4) cordas (terminal–terminal e terminal–painel depois do passo 5 para os painéis); 5) painéis (o mesmo caminho interno do `panel.open`, no andar se for canvas); 6) prompts: `role` de cada terminal criado via `asks.inject` (falha de injeção aqui → desfaz também).
- Desfazer (qualquer falha, também cancelamento da requisição): de trás para frente — fecha painéis criados, desfaz cordas criadas, mata e remove terminais criados (`remove`), apaga o andar criado **só** se `git rev-list --count <base>..<branch>` == 0 (senão mantém e acrescenta o aviso "andar ‹nome› mantido: tem commits"). Erros do próprio desfazer viram avisos; o erro devolvido é o da falha original, com o passo ("terminal ‹nome› não ficou pronto em 60 s", "painel ‹nome›: ‹erro›", …). Uma aplicação por vez por workspace (a segunda espera).
- [ ] **Step 1: Testes** (daemon em processo; `claude` falso no `PATH` como nos testes de recruit da v1, um script que imprime um prompt e lê linhas; repositório temporário para andares): `appliesFactoryBugScore` (3 terminais com os nomes `x-maestro`, `x-investigador`, `x-testes`, 2 cordas, prompts injetados, sem andar); `appliesWithFloor` (fullstack com `claude` falso + painéis Navegador/Design falsos → andar `x` criado, terminais nele, 5 cordas); `preflightCreatesNothing` (nome em uso; andar existente; `cwd` sem git com andar; preset ausente → erro e o snapshot do workspace idêntico ao de antes); `rollbackOnAgentTimeout` (`claude` falso que nunca fica pronto para uma chave → erro com o nome; nenhum terminal/corda/painel/andar novo; terminais pré-existentes intactos); `rollbackOnPanelFailure`; `rollbackKeepsFloorWithCommits` (falso que commita no andar antes de travar → andar mantido + aviso); `maestroApplyCordsToApplier` (Maestro aplica a de bug → 2 terminais novos, nenhum Maestro novo, cordas com o aplicador; Maestro não pode aplicar com `cwd` de outro); `terminalsCannotApply` (terminal comum → `.notMaestro`); `appliedEventCarriesFrames`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter PartituraApplyTests`). **Step 5:** Commit `feat(partituras): all-or-nothing apply with rollback`.

### Task 4: Partituras no app

**Files:** Create `Sources/OrqApp/PartiturasSheet.swift` (só a view), `Sources/OrqPlugins/PartiturasModel.swift`, `Tests/OrqPluginsTests/PartiturasModelTests.swift`; Modify `Sources/OrqCanvas/Layout.swift` (`placeFrames`, testado em `Tests/OrqCanvasTests/`), `Sources/OrqApp/{OrqApp,CanvasViewport}.swift`

**Interfaces:**
- Produces: `@MainActor final class PartiturasModel: ObservableObject { @Published var items: [PartituraListItem]; @Published var preview: PartituraPreview?; func refresh() async; func select(_ id: String) async; func apply(id: String, name: String, floor: Bool?, cwd: String, at anchor: CGPoint) async -> String? /* erro ou nil */; func save(name: String, terminals: [UUID], panels: [UUID], frames: [UUID: CGRect], roles: [UUID: String], wantsFloor: Bool) async -> [String] /* avisos */; func importFile(_ url: URL) async -> PartituraPreview?; func confirmImport() async; func export(id: String, to url: URL) async }` (usa `call` admin, como os painéis).
- Entradas na UI:
  - Menu **Canvas ▸ Partituras…** e clique direito no fundo do canvas **"Aplicar partitura aqui…"** → sheet com a lista (fábrica marcada "de fábrica"), a prévia da selecionada (terminais com preset/papel, painéis, cordas, "cria andar"), campo **Nome** (obrigatório), caixa **Criar andar** (começa em `wantsFloor`), **Pasta** (padrão: a pasta do terminal selecionado, senão a última usada; seletor do sistema), botão **Aplicar** (desabilita e mostra "Aplicando…" até a resposta; erro aparece na sheet, que continua aberta).
  - Clique direito com seleção de terminais/painéis **"Salvar como partitura…"** → sheet com nome, descrição, papel de cada terminal (texto opcional), **Pede andar**; mostra os avisos do daemon.
  - Na sheet: **Importar…** (`NSOpenPanel`, `.orqpartitura`, lê ≤ 256 KiB) → tela de confiança: "Esta partitura vai criar:" + lista; seção destacada **"Comandos que serão executados"** (cada `command` em monoespaçado) e **"Prompts que serão enviados"** (cada `role`); botões **Importar** / **Cancelar**. **Exportar…** (`NSSavePanel`) e **Remover** (só salvas; "fica guardada em partituras/.removed").
- Posição: ao receber `partitura.applied`, o canvas coloca os frames relativos a partir do ponto clicado (aplicação pelo app) ou à direita do frame do Maestro `anchor` com 80 pt de folga (aplicação por Maestro); itens sem frame entram numa grade a partir desse ponto. Grava no `layout.json` como qualquer movimento.
- [ ] **Step 1: Testes** (modelo com `call` falso): `applySendsNameFloorCwd`; `applyErrorKeepsSheet`; `importShowsCommandsAndPrompts` (arquivo com `custom` + `role` → a prévia lista ambos; sem confirmar, `partitura.import` não é chamado); `importTooBigRefusedLocally` (300 KiB → erro sem chamar o daemon); `saveSendsRelativeFrames`; `placementFromEvent` (função pura `placeFrames(_ rel: [UUID: CGRect], anchor: CGPoint) -> [UUID: CGRect]` e o caso Maestro).
- [ ] **Step 2–4:** FAIL → implementar → PASS. **Step 5:** Commit `feat(partituras): apply, save, import and export from the app`.

### Task 5: Maestro, docs e verificação

**Files:** Modify `Sources/OrqDaemonKit/MemoryCommands.swift` (texto de orientação), `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`; Create (scratchpad) `plan3d-checklist-visual.md`

- [ ] **Step 1:** Orientação ao Maestro: o texto de início de sessão de Maestros (`memory.hookContext`, ramo do Maestro) ganha: "Partituras: `orq partitura list`; aplique com `orq partitura apply <id> --name <nome> [--floor]` (o que criar fica ligado a você); salve uma equipe com `orq partitura save <nome> --terminals a,b,c`." Teste: `maestroContextMentionsPartituras` (e terminal comum **não** recebe).
- [ ] **Step 2:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem).
- [ ] **Step 3:** README: seção "Partituras" (fábrica, salvar, aplicar tudo-ou-nada e o que o desfazer remove, arquivo e aviso de confiança, Maestro). Roteiro: 3D "em execução".
- [ ] **Step 4:** Checklist humana no scratchpad: aplicar "Investigar bug" no canvas; aplicar "Feature fullstack" com andar e ver os painéis ligados à interface; forçar falha (salvar uma partitura com um terminal custom `sh -c 'exit 1'` e aplicar) e ver tudo sumir; salvar uma seleção, exportar, importar em outro workspace e ver a tela de confiança; um Maestro aplicar pela CLI.
- [ ] **Step 5:** Commit `docs: partituras`.
