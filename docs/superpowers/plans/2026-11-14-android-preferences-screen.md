# Tela Android nas Preferências (opção B) — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preferências ganha a barra lateral da opção B e uma página **Android** que instala o SDK, mostra as licenças e cria o `collie-lite`, falando só com os comandos `android.*` e `device.lite.*` que o daemon já tem.

**Architecture:** Um modelo puro (`AndroidSetupModel`) lê as respostas do daemon e decide o estado da tela; a view `AndroidPreferences` só desenha esse estado e chama o daemon (mesmo padrão de `CelularPreferences`: `adminCall`, leitura ao mostrar e polling enquanto visível). A moldura nova (`PreferencePage` + `PreferencesSidebar`) reorganiza as seções que já existem em `PreferencesView.swift` sem mudar o que elas fazem.

**Tech Stack:** SwiftUI/AppKit, `DaemonClient.adminCall`, swift-testing (`@Test`), módulos `CollieApp`, `CollieProtocol`, `CollieClient`.

**Spec:** `docs/superpowers/specs/2026-11-14-android-setup-design.md` (seções "Decisão do dono" e "Resultado do E2E").
**Prévia aprovada (referência visual):** `docs/pages/preferencias-b/index.html` (painel `preview-13`, 9 estados do Android em claro e escuro).

## Global Constraints

- Daemon fora do escopo: nenhum arquivo em `Sources/CollieDaemonKit/` ou `Sources/CollieDevice/` muda. Se o contrato não bastar, pare e reporte.
- Os comandos `android.*` são admin (app): chamar só por `client.adminCall`, nunca por terminal/MCP.
- Nunca enviar `accept` com id que o usuário não marcou. Instalar sem licenças pendentes manda `accept` vazio.
- Aviso fixo ao lado de **Instalar**: "Ao instalar, você aceita os termos do Android SDK" com link `https://developer.android.com/studio/terms` (decisão do dono, Task 7).
- Tamanhos estimados sempre com "~"; total e "2× de espaço livre" como na Prévia.
- Uma instalação por vez; a tela nunca inicia a segunda (o daemon recusa com `busy:`).
- Português do Brasil em todo texto visível; fontes e cores só por `Font.collieUI/collieMono` e `Color.collie*` (como em `CelularPreferences.swift`).
- Janela de Preferências ~820×600 pt (Prévia); nada de largura fixa que quebre abaixo de 700 pt.
- Testes só por `swift test --filter <Suite>` em worktree isolada; nunca a suíte inteira. Sem push, sem instalar o app, sem `bundle-app`.
- Commits só com os arquivos da task; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Contrato do daemon (já implementado, não mudar)

- `android.status` → `{sdk:{path,source}, items:[{id,state,detail}], needs, job?, lite}`. `items.id`: `java`, `cmdline-tools`, `platform-tools`, `emulator`, `image`; `state`: `ok|missing|installing`. `needs`: `needsPrepare|needsLicense|ready`. `job`: `{phase: prepare|install|done|failed|cancelled, item?, percent?, bytes?, total?, error?}` (fica após o fim). `lite`: Bool.
- `android.licenses` → `[{id,title,text,accepted}]` (lento: até 300 s; não aceita nada). Lista vazia = nada a aceitar (clássico já aceito, ou 23.0 sem lista).
- `android.install` (`accept`: array de ids) → `{job}` na hora; o resto vem de `android.status`. Erro `busy: …` quando outro processo usa o SDK.
- `android.cancel` → `{}`. `device.lite.create` → `{…}` strings; `device.lite.remove` → `{}`.

## Review Focus

- Usuário clica **Recusar** nas licenças: nada é enviado, a tela mostra "Licenças recusadas" e oferece rever; `accept` nunca sai preenchido. (Task 1 e 2)
- `android.install` volta `busy:` (Android Studio ou outro `sdkmanager` no mesmo SDK): estado "ocupado" com texto do daemon e botão "Tentar de novo", sem travar. (Task 1 e 2)
- Daemon cai ou a conexão some no meio do job: o polling para, controles ficam desabilitados e voltam sozinhos ao reconectar, sem mostrar progresso velho como atual. (Task 2)
- `job.phase == failed` com `error`: mostra o erro do daemon (inclui "sem espaço", "Apple Silicon só") e permite tentar de novo; `cancelled` volta ao estado anterior sem erro. (Task 1)
- Sair da página ou fechar Preferências durante o job: o polling para (a `Task` é cancelada); o job continua no daemon e a tela retoma ao voltar. (Task 2)

### Task 1: Modelo puro do estado

**Files:**
- Create: `Sources/CollieApp/AndroidSetupModel.swift`
- Test: `Tests/CollieAppTests/AndroidSetupModelTests.swift`

**Interfaces:**
- Produces:
  - `struct AndroidSetupStatus: Equatable { struct Sdk { path: String; source: String }; struct Item { id, state, detail: String }; struct Job { phase: String; item: String?; percent: Int?; bytes: Int64?; total: Int64?; error: String? }; var sdk: Sdk; var items: [Item]; var needs: String; var job: Job?; var lite: Bool; static func from(_ v: JSONValue) -> AndroidSetupStatus? }`
  - `struct AndroidLicense: Equatable, Identifiable { id, title, text: String; accepted: Bool; static func list(_ v: JSONValue) -> [AndroidLicense] }`
  - `enum AndroidScreenState: Equatable { case nada, parcial, preparando, licenca, instalando, pronto, erro(String), recusou, ocupado(String) }`
  - `static func AndroidScreenState.derive(status: AndroidSetupStatus, licenses: [AndroidLicense]?, refused: Bool, busy: String?) -> AndroidScreenState`
  - `enum AndroidCopy { static func bytes(_ n: Int64) -> String; static let estimates: [String: Int64]; static func totalPending(_ s: AndroidSetupStatus) -> Int64; static func needsFree(_ s: AndroidSetupStatus) -> Int64; static let termsURL: URL }`

- [ ] **Step 1: Write the failing tests** (`AndroidSetupModelTests.swift`), with `JSONValue` literals copiados do contrato acima:
  - `statusDecodesTheDaemonReply`: um `android.status` completo vira `AndroidSetupStatus`; resposta sem `sdk` ou `items` → `nil`.
  - `licensesListDecodesAndEmptyIsEmpty`: dois objetos → duas licenças; `.array([])` e valor não-array → `[]`.
  - `derive` com a matriz: tudo `missing` + `needsPrepare` → `.nada`; `cmdline-tools` ou `java` `missing` com algum item `ok` → `.parcial`; `job.phase == "prepare"` → `.preparando`; `needsLicense` com `licenses` não vazio e sem job → `.licenca`; `refused == true` e `needsLicense` → `.recusou`; `job.phase == "install"` → `.instalando`; `job.phase == "failed"` → `.erro(error)`; `job.phase == "cancelled"` sem erro → o estado de antes do job (`.nada` ou `.parcial`); `busy != nil` → `.ocupado(busy)` (vence todos, menos `.instalando`); todos `ok` e `needs == "ready"` → `.pronto`.
  - `derive` com 23.0 sem lista: `needsLicense`/`ready` e `licenses == []` → nunca `.licenca` (vai a `.nada`/`.parcial`/`.pronto`, nunca pede aceite que não existe).
  - `copyFormatsSizesWithTilde`: `bytes(15 << 20)` → "~15 MB", `bytes(6 << 30)` → "~6 GB"; `needsFree` = 2 × `totalPending`; `totalPending` soma só itens `missing` (`estimates`: platform-tools 15 MB, emulator 400 MB, image 6 GB, os mesmos de `AndroidInstaller.estimates`, que o app não importa).
- [ ] **Step 2: Run** `swift test --filter AndroidSetupModelTests` → FAIL (tipos não existem).
- [ ] **Step 3: Implement** os tipos acima em `AndroidSetupModel.swift`. Decodificação como `RemoteStatus.from` (`Sources/CollieClient/RemoteClient.swift:14`): tolerante, `nil` se faltar campo obrigatório. `derive` é função pura, ordem de decisão fixa (busy → job → licenças → itens), sem I/O.
- [ ] **Step 4: Run** `swift test --filter AndroidSetupModelTests` → PASS.
- [ ] **Step 5: Commit** `feat(app): Android setup model for the preferences screen`.

### Task 2: A view `AndroidPreferences`

**Files:**
- Create: `Sources/CollieApp/AndroidPreferences.swift`
- Test: `Tests/CollieAppTests/AndroidSetupModelTests.swift` (acrescenta o que for puro: texto do aviso, rótulos por estado)

**Interfaces:**
- Consumes: Task 1 (`AndroidSetupStatus`, `AndroidLicense`, `AndroidScreenState`, `AndroidCopy`); `DaemonClient.adminCall(_:_:timeout:)`; `ProtocolError.message`.
- Produces: `struct AndroidPreferences: View { init(client: DaemonClient, status: AndroidSetupStatus? = nil, licenses: [AndroidLicense]? = nil) }` (os dois últimos para previews e snapshots, como `CelularPreferences.init`).

- [ ] **Step 1: Write the failing tests** (puros, no modelo): `AndroidCopy.label(for: AndroidScreenState)` devolve o título e o texto do botão primário de cada um dos 9 estados, copiados de `docs/pages/preferencias-b/index.html` (Instalar / "Instalar o que falta" / Cancelar / "Li e aceito…" / "Ver o erro" / "Tentar de novo"). `AndroidCopy.acceptIds(licenses: [AndroidLicense], checked: Bool) -> [String]`: `[]` se não marcou; todos os ids se marcou; `[]` se a lista é vazia.
- [ ] **Step 2: Run** `swift test --filter AndroidSetupModelTests` → FAIL nos dois novos.
- [ ] **Step 3: Implement** `label(for:)` e `acceptIds` em `AndroidSetupModel.swift`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Implement `AndroidPreferences`** seguindo `CelularPreferences.swift` (`section`, `note`, `.task(id: connected)` com laço e `Task.sleep`):
  - Polling de `android.status` a cada 1 s com job rodando, 3 s parado; o laço para ao cancelar a `Task` (sair da página) e quando `connected == false`.
  - Blocos da Prévia: "SDK em uso" (path, fonte, selo), lista por itens (Fase 1 Preparar: java, cmdline-tools; Fase 2 Instalar: platform-tools, emulator, image) com estado e `percent`/bytes, total e espaço livre exigido (`~`), aviso fixo com o link ao lado de **Instalar**, bloco de licenças (cartões `title` + `id` + `text` rolável, caixa "Li e aceito as licenças do Google", **Recusar** / **Aceitar e instalar**), banners de erro e de ocupado, bloco `collie-lite` (Criar / Remover, estado `status.lite`).
  - Licenças: `android.licenses` só é chamado ao entrar em `needsLicense` (timeout 300 s; mostra "Lendo licenças…" enquanto isso); **Aceitar e instalar** chama `android.install` com `AndroidCopy.acceptIds`; **Recusar** só marca `refused = true`, não chama o daemon.
  - `busy:` na resposta do `install` vira `busy = message`; "Tentar de novo" limpa `busy` e chama `install` outra vez.
  - Todo botão desabilitado se `client.state != .connected`; erro de qualquer chamada vira texto `collieDanger` na seção (como `error` em `CelularPreferences`).
- [ ] **Step 6: Run** `swift build --product CollieApp` em worktree isolada (`git worktree add --detach <tmp> HEAD`, `--scratch-path <tmp>/.build`) → compila.
- [ ] **Step 7: Commit** `feat(app): Android page for Preferences (setup, licenses, collie-lite)`.

### Task 3: Moldura com barra lateral (opção B)

**Files:**
- Create: `Sources/CollieApp/PreferencePage.swift`
- Modify: `Sources/CollieApp/PreferencesView.swift` (corpo, `:46-85`; as seções de `:87-172` viram páginas)
- Test: `Tests/CollieAppTests/PreferencePageTests.swift`

**Interfaces:**
- Produces: `enum PreferencePage: String, CaseIterable { case aparencia, terminal, desenho, memoria, plugins, celular, android; var title: String; var group: String; var keywords: String; static func matching(_ query: String) -> [PreferencePage] }`. Grupos e ordem da Prévia: **Interface** (Aparência, Terminal e fontes), **Agentes** (Desenho e sandbox, Memória, Plug-ins), **Dispositivos** (Celular, Android).

- [ ] **Step 1: Write the failing tests**: `matching("")` devolve as 7 na ordem acima; `matching("licença")` e `matching("java")` contêm `.android`; `matching("fonte")` contém `.terminal`; `matching("zzz")` é vazio; a busca ignora maiúsculas e acentos.
- [ ] **Step 2: Run** `swift test --filter PreferencePageTests` → FAIL.
- [ ] **Step 3: Implement** `PreferencePage` (palavras-chave da Prévia, `docs/pages/preferencias-b/index.html:384-387`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Reorganize `PreferencesView`**: barra lateral com busca e os três grupos; `switch page` mostra a seção certa. Quebrar `appearance` (`:87`) por páginas: Aparência = Tema + Estrutura; Terminal e fontes = Terminal + Fontes; Desenho e sandbox = "Onde desenhar" + "Modo do sandbox"; Memória = "Memória"; Plug-ins e Celular como hoje; Android = `AndroidPreferences(client:)`. Não mudar `@AppStorage`, os `load…/set…` nem o texto das seções. Janela 820×600; badge `!`/`↓` no item Android quando há erro ou job.
- [ ] **Step 6: Run** `swift build --product CollieApp` e `swift test --filter PreferencePageTests` + `--filter CelularPreferencesTests` (regressão) → PASS.
- [ ] **Step 7: Commit** `feat(app): Preferences sidebar (option B) with Android page`.

### Task 4: Conferência e documentação

**Files:**
- Modify: `README.md` (seção do Android/emulador leve: onde instalar o SDK na tela), `docs/superpowers/specs/2026-11-14-android-setup-design.md` (acrescenta "Tela: feita", sem mudar decisões)

- [ ] **Step 1: Verificação visual**: gerar a tela com dados de exemplo para os 9 estados em claro e escuro (previews/snapshots do padrão de `CelularPreferences`, em `docs/`), e comparar um a um com `preview-13`. Anotar no spec as diferenças e os estados que não deu para exercitar (daemon real só no bundle).
- [ ] **Step 2: README**: um parágrafo curto "Preferências → Android" (Instalar, aviso de termos, licenças, `collie-lite`).
- [ ] **Step 3: Run** `swift build --product CollieApp`, `swift build --product collie` e as suítes `AndroidSetupModelTests`, `PreferencePageTests`, `CelularPreferencesTests` → PASS.
- [ ] **Step 4: Commit** `docs(android): Preferences Android page`.

## Self-review

- Spec coberto: aviso/aceite (Task 2), licenças só quando existem (Task 1/2), uma instalação por vez e `busy` (Task 2), tamanhos com "~" e 2× de espaço (Task 1), `collie-lite` criar/remover (Task 2), reaproveitar o SDK do Studio (mostrado em "SDK em uso", Task 2), moldura B e janela 820×600 (Task 3).
- Fora deste plano: UI do seletor de versão do `cmdline-tools` (o daemon escolhe sozinho), progresso do JDK em percentual, plug-in de nova página para terceiros.
- Tipos conferidos: `AndroidScreenState` e `AndroidSetupStatus` definidos na Task 1 e usados nas Tasks 2–3 com os mesmos nomes.
- Limite aberto: o estado real com o daemon só se confirma no bundle instalado (instalar derruba terminais; o dono decide quando).
