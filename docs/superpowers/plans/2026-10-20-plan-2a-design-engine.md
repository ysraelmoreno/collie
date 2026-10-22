# Plano 2A — Motor de design (figcraft) + painel Design — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O design passa a morar num documento figcraft único, ao vivo: o painel Design do Orq mostra e edita esse documento, e os agentes editam o mesmo documento ao mesmo tempo por comandos `orq design …` (comandos e lotes do figcraft, inspeção, screenshot, exportação).

**Architecture:** Caminho (a) do spike. O daemon supervisiona um `figcraft-server` local (127.0.0.1) que guarda os arquivos de design. Cada chamador (terminal ou o app) que edita um arquivo ganha seu próprio cliente `figcraft-cli mcp` headless, já dentro da sessão (`collab.join`), falando MCP por stdio — assim o desfazer é por agente e o servidor ordena tudo. O painel Design (plug-in `design`, roda no daemon) carrega a UI WASM do figcraft num WKWebView via esquema próprio, entrando na mesma sessão pelo link de edição (que nunca é entregue a agentes). O figcraft é compilado da tag v0.7.0 com patches nossos (marca, servidor público, leitura atualizada) e fontes embutidas.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, WebKit (WKWebView, WKURLSchemeHandler); figcraft **v0.7.0** (Apache-2.0, Rust: `figcraft-server`, `figcraft-cli`, `figcraft-web` via trunk) como processos auxiliares; `python3` do sistema só nos testes (fake MCP).

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.1 (Design), §3 (restrições), §6 (plug-ins), §5 (cordas). Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`. Spike: `docs/superpowers/spikes/2026-10-20-figcraft/` (copiado para o repo no Task 1). Base: `main` em `f179375` (1A–1G).

## Global Constraints

- figcraft fixado na **v0.7.0** nos três binários (server, CLI, web) — mesma versão sempre; atualizar só deliberadamente.
- figcraft integra como **processo auxiliar**, nunca biblioteca linkada (spec §3). IPC: MCP JSON-RPC por stdio (uma mensagem JSON por linha), protocolo `2025-06-18`.
- **Remover a marca ArtCraft** de todo build distribuído (spec §3): About, links de ajuda, strings localizadas, `CompanyName`. Compilar com **`FIGCRAFT_DEFAULT_SERVER=`** vazio: nada de "Share > Online" para `wss://collab.craftapps.dev/` — **nada sai da máquina**.
- `figcraft-server` escuta só em **127.0.0.1**; dados em `<daemon root>/design/server`; o link de edição e a chave do servidor são segredos do daemon/app — **agentes nunca recebem link nem chave**.
- **Corda é a única permissão** (decisão do usuário): comandos `design.*` presos a painel seguem `ConnectionGraph.resolvePanel` (canvas: só com corda; doca: todos). `design.files` e `design.new` não têm painel.
- Um cliente headless por (chamador, arquivo); fechado após **5 min** sem uso e quando o painel/arquivo fecha; no máximo **8** clientes vivos (o mais antigo ocioso sai primeiro).
- Leitura nunca vem velha: todo `get_node`/`inspect_document`/`screenshot` é precedido de sincronização (patch upstream de 1 linha; enquanto não houver, `run_command collab.peers` antes).
- Lote de comandos = **um passo de desfazer**, tudo-ou-nada (`batch`).
- Nada de I/O bloqueante no pool cooperativo; processos via `LongProcess`/grupo próprio; `figcraft-server` reiniciado se cair (espera 1 s→30 s).
- Clean-room em relação ao Maestri. figcraft é Apache-2.0: patches nossos versionados em `patches/figcraft/`, `Resources/NOTICE-figcraft` no app.
- Instalações de sistema (rustup + alvo `wasm32-unknown-unknown`) **só com aprovação do usuário**; `trunk`/`wasm-bindgen-cli` em pasta local do build.

## Review Focus

1. **`figcraft-server` cai ou é morto** → o daemon reinicia na mesma porta e dados; comandos em andamento falham com erro claro (não travam); clientes headless são recriados na próxima chamada; o painel mostra "reconectando" e volta. Testes: Task 2 `serverRestartsAfterCrash`, Task 3 `clientRecreatedAfterServerRestart`.
2. **Lote malformado ou enorme de um agente** (comando inexistente no meio, JSON inválido, 5 MB) → erro com o índice do passo, documento intacto (tudo-ou-nada); entrada acima de **4 MiB** recusada antes de chegar ao figcraft. Teste: Task 3 `badBatchLeavesDocumentUnchanged`, `oversizedBatchRefused`.
3. **Dois agentes editando o mesmo arquivo ao mesmo tempo** → cada um com seu cliente; as duas edições aparecem; o desfazer de um não desfaz o do outro. Teste: Task 3 `twoCallersHaveSeparateUndo` (integração com o build real; pulado sem ele).
4. **Nome de arquivo ou caminho hostil** (`../x`, `/etc`, `a/b`, 300 caracteres, vazio) em `design.new`/`design.export` → recusado com `invalidArgs`; exportações só dentro de `<root>/design/exports/`. Teste: Task 3 `fileNamesAreValidated`.
5. **Vazamento para fora da máquina** → binários e web sem `collab.craftapps.dev` nem marca ArtCraft; servidor só em 127.0.0.1. Testes: Task 1 `scripts/check-figcraft.sh`, Task 2 `serverBindsLoopbackOnly`.

---

## File Structure

```
docs/superpowers/spikes/2026-10-20-figcraft/{REPORT.md,scripts/}   relatório e scripts do spike (sem o portfólio pessoal)
patches/figcraft/0001-orq-branding.patch      About/ajuda/locales/CompanyName sem ArtCraft
patches/figcraft/0002-headless-read-poll.patch  live_poll() no topo de Headless::call (crates/mcp/src/headless.rs)
scripts/build-figcraft.sh                     clona v0.7.0 em vendor/figcraft-src, aplica patches, compila server+cli+web → vendor/figcraft/
scripts/check-figcraft.sh                     confere versão, ausência de marca/servidor público, fonte Inter presente
scripts/bundle-app.sh                         (+ copia vendor/figcraft para Contents/Resources/figcraft)
Resources/NOTICE-figcraft
Sources/OrqDaemonKit/Design/MCPStdioClient.swift   cliente MCP por stdio sobre processo filho (initialize, tools/call, timeout, fim)
Sources/OrqDaemonKit/Design/FigcraftServer.swift   supervisão do figcraft-server (porta, chave, healthz, reinício)
Sources/OrqDaemonKit/Design/DesignService.swift    actor: registro de arquivos, clientes por (chamador, arquivo), comandos
Sources/OrqDaemonKit/DesignCommands.swift          design.* no router
Sources/OrqProtocol/Plugins.swift                  (+ PluginRegistry.design)
Sources/OrqProtocol/Commands.swift                 (panel.open --file)
Sources/OrqPlugins/DesignPanel.swift               painel: WKWebView + esquema orq-design://
Sources/OrqApp/{OrqApp,OpenPanelSheet}.swift       registro do painel, seletor/criação de arquivo
Tests/Fixtures/fake-figcraft-mcp.py, Tests/Fixtures/fake-figcraft-server.sh
Tests/OrqDaemonKitTests/{MCPStdioClientTests,FigcraftServerTests,DesignCommandTests}.swift
Tests/OrqPluginsTests/DesignPanelTests.swift
```

---

### Task 1: Build fixado do figcraft (patches, fontes, sem marca, sem servidor público)

**Files:** Create `scripts/build-figcraft.sh`, `scripts/check-figcraft.sh`, `patches/figcraft/0001-orq-branding.patch`, `patches/figcraft/0002-headless-read-poll.patch`, `Resources/NOTICE-figcraft`, `docs/superpowers/spikes/2026-10-20-figcraft/`; Modify `scripts/bundle-app.sh`, `.gitignore`

**Interfaces:**
- Produces: `vendor/figcraft/bin/figcraft-server`, `vendor/figcraft/bin/figcraft-cli`, `vendor/figcraft/web/` (index.html, .wasm, .js, assets) — git-ignored; `Contents/Resources/figcraft/{bin,web}` no app. `scripts/check-figcraft.sh` sai 0 só se: `figcraft-cli --version` contém `0.7.0`; `grep -ri -E "artcraft|getartcraft|collab\.craftapps\.dev"` vazio em `bin/` e `web/`; `figcraft-cli mcp` → `run_command text.fonts {"family":"Inter"}` não vazio.

Pré-requisito (usuário aprova antes de executar este task): `rustup` instalado (`brew install rustup` e `rustup-init -y --no-modify-path` ou o instalador oficial) e `rustup target add wasm32-unknown-unknown`. Se não estiver presente, o script para com mensagem dizendo exatamente isso.

- [ ] **Step 1:** Copiar `REPORT.md` e `scripts/{mcp.py,spike_a.py}` do spike para `docs/superpowers/spikes/2026-10-20-figcraft/` (não copiar `portfolio/`, `portfolio-profile.md`, `srvdata/` nem `figcraft/`).
- [ ] **Step 2:** `build-figcraft.sh`: `git clone --depth 1 --branch v0.7.0 https://github.com/storytold/figcraft vendor/figcraft-src` (se ausente; confere o commit `47438dd4…` do spike), clona `storytold/craft-fonts` num commit fixado (registrar o hash no script) como `CRAFT_FONTS_DIR`, aplica `patches/figcraft/*.patch` com `git apply --check` antes, instala `trunk` e `wasm-bindgen-cli` (versão do `Cargo.lock`) em `vendor/figcraft-tools` via `cargo install --root`, e compila com `FIGCRAFT_DEFAULT_SERVER=` e `CRAFT_FONTS_DIR`: `cargo build --release -p figcraft-server -p figcraft-cli` e `trunk build --release` em `apps/figcraft-web` (`--public-url ./`). Copia para `vendor/figcraft/`. Idempotente.
- [ ] **Step 3:** Patch 0001 (marca): pontos listados na seção 5 do REPORT (`crates/ui-egui/src/dialogs.rs:134-141`, `crates/ui-egui/src/lib.rs:964`, `crates/ui-egui/locales/*.toml`, `apps/figcraft/build.rs:14`) — About diz "figcraft (embutido no Orq)" com link para o repositório upstream e a licença; ajuda aponta para o repositório upstream. Patch 0002: `self.session.live_poll()` no início de `Headless::call` (`crates/mcp/src/headless.rs`).
- [ ] **Step 4:** Rodar `scripts/build-figcraft.sh && scripts/check-figcraft.sh` → saída 0. Se o texto Inter ainda não renderizar na UI web (verificação manual rápida: abrir `vendor/figcraft/web/index.html` servido localmente com `?webgl`, criar um texto), registrar no relatório e tentar a família embutida padrão das craft-fonts; anotar a escolha.
- [ ] **Step 5:** `bundle-app.sh` copia `vendor/figcraft/{bin,web}` + `NOTICE-figcraft` para `Contents/Resources/figcraft/` (aviso, não erro, se faltar). `.gitignore`: `vendor/figcraft-src/`, `vendor/figcraft-tools/`, `vendor/figcraft/`. Commit `build: pinned figcraft v0.7.0 build without branding or public server`.

### Task 2: Processos — cliente MCP por stdio e supervisão do `figcraft-server`

**Files:** Create `Sources/OrqDaemonKit/Design/{MCPStdioClient,FigcraftServer}.swift`, `Tests/Fixtures/fake-figcraft-mcp.py`, `Tests/Fixtures/fake-figcraft-server.sh`, `Tests/OrqDaemonKitTests/{MCPStdioClientTests,FigcraftServerTests}.swift`; Modify `Sources/OrqDaemonKit/Devices/LongProcess.swift` (se preciso: stdin por pipe), `Sources/OrqDaemonKit/Daemon.swift`

**Interfaces:**
- Produces: `final class MCPStdioClient: Sendable { init(executable: URL, args: [String], env: [String: String], runDir: URL, name: String) async throws(ProtocolError); func call(_ tool: String, _ args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> MCPResult; func command(_ id: String, _ params: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue; func close(); var isAlive: Bool }` — `initialize` (`protocolVersion "2025-06-18"`, `clientInfo.name = name`) + `notifications/initialized`; uma requisição por vez por cliente (fila); resposta casada por `id`; linhas que não são JSON ou sem `id` ignoradas; resposta > **16 MiB** → erro; `isError` → `ProtocolError(.internal, texto)`; processo morreu → `.unavailable` "design engine stopped". `struct MCPResult { var texts: [String]; var images: [Data]; var isError: Bool }`; `command` = tool `run_command {command, params}` com o texto decodificado como JSON.
- Produces: `actor FigcraftServer { init(binary: URL, dataDir: URL, runDir: URL, port: UInt16 = 47900); func ensureRunning() async throws(ProtocolError) -> (wsURL: String, key: String); func stop() async }` — porta: 47900 ou a próxima livre até 47999; chave via `figcraft-server key` (guardada em `dataDir/key`, 0600); sobe `figcraft-server --listen 127.0.0.1:<port> --data <dataDir>` como `LongProcess`, espera `GET http://127.0.0.1:<port>/healthz` (≤ 10 s); caiu → reinicia na próxima `ensureRunning` com espera crescente 1 s→30 s; `wsURL = "ws://127.0.0.1:<port>/?key=<key>"`. `DaemonConfig.figcraftDir: URL?` (padrão `<dir do orqd>/../Resources/figcraft`, override `ORQ_FIGCRAFT_DIR`); ausente → `unavailable` "Design engine not bundled (run scripts/build-figcraft.sh and rebuild)".
- `Daemon.stop` encerra o servidor e todos os clientes.

`fake-figcraft-mcp.py` (python3 `-I`): MCP mínimo — `initialize`; `tools/call` `run_command` (`collab.join`/`collab.publish`/`collab.peers`/`inspect.code`/`text.fonts`), `batch` (falha tudo se algum `command` começar com `bad.`), `get_node`, `inspect_document`, `screenshot` (PNG 4×8 base64); registra chamadas em `$ORQ_FAKE_FIG_LOG`; `ORQ_FAKE_FIG_SLEEP` atrasa respostas. `fake-figcraft-server.sh`: `key` imprime uma chave; senão serve `/healthz` (python3 http.server numa porta do `--listen`) e grava argumentos em log; `ORQ_FAKE_FIG_SERVER_DIE=1` sai após 1 s.

- [ ] **Step 1: Testes que falham:**
  - `initializeAndCall`: cliente com o fake → `command("collab.peers", [:])` devolve o JSON do fake; log mostra `initialize` antes.
  - `responsesMatchById`: fake responde notificações e linhas lixo antes da resposta → resultado certo.
  - `toolErrorBecomesProtocolError`; `timeoutKillsNothingButFails` (com `ORQ_FAKE_FIG_SLEEP`, `.timeout`, cliente segue vivo para a próxima); `processDeathIsUnavailable`; `oversizedResponseRejected`.
  - `serverBindsLoopbackOnly` (args do fake contêm `--listen 127.0.0.1:`), `keyPersistedWith0600`, `portFallsThroughWhenBusy`, `serverRestartsAfterCrash` (`DIE=1` → segunda `ensureRunning` após o atraso devolve URL e o processo é novo), `missingEngineIsUnavailable`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "MCPStdioClient|FigcraftServer"` → PASS.
- [ ] **Step 5:** Commit `feat(design): MCP stdio client and supervised figcraft-server`.

### Task 3: `DesignService` e comandos `design.*`

**Files:** Create `Sources/OrqDaemonKit/Design/DesignService.swift`, `Sources/OrqDaemonKit/DesignCommands.swift`, `Tests/OrqDaemonKitTests/DesignCommandTests.swift`; Modify `Sources/OrqProtocol/{Plugins,Commands}.swift`, `Sources/OrqDaemonKit/{CommandRouter,PanelCommands,Daemon}.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces: plug-in `design` (`runsInDaemon: true`, título `Design`, placements `[.canvas, .dockRight, .dockLeft, .dockBottom]`, padrão `.canvas`, eventos `["design.changed"]` — reservado, não emitido neste plano). Painel guarda `state["file"]` (id do arquivo). `panel.open design --file <nome>` (existente ou novo: cria).
- Registro: `<root>/design/files.json` = `[{id, name, editLink, createdAt}]` (0600; `editLink` nunca sai do daemon exceto para o app em `design.link`). Nome: 1–80 caracteres, `[A-Za-z0-9 ._-]`, sem `..`, único (sem caixa).
- Comandos (todos com `--panel` automático; nos presos a painel o arquivo vem do painel):
  - `design.files` → `[{name, panels}]` (sem painel)
  - `design.new <name>` → cria arquivo vazio: cliente "orq-bridge" faz `collab.publish {server: wsURL, name}`, espera `readOnly == false`, guarda o link de edição → `{name}` (sem painel)
  - `design.run <command> [--params <json>]` → `command(...)` no cliente do chamador; params ≤ 4 MiB
  - `design.batch --commands <json array> [--label <texto>]` (ou `--file <caminho .json>` relativo ao cwd) → tool `batch`; um passo de desfazer; erro traz o índice do passo
  - `design.inspect [--node <id>] [--depth n]` → `get_node`/`inspect_document`
  - `design.screenshot [--node <id>]` → PNG em `<root>/screens/<panelId>-<epochMs>.png` → `{path,width,height}`
  - `design.export --format html|css|react|figcraft [--node <id>]` → `inspect.code {language}` (ou `document.save` p/ figcraft) gravado em `<root>/design/exports/<file>/<epochMs>.<ext>` → `{path}`
  - `design.help [query]` → lista de ids de comando do figcraft (via o comando de listagem que o figcraft expõe; o implementador confere qual) filtrada por `query`
  - `design.link` (admin, `exposedToMCP: false`) → `{editLink}` para o app
- Clientes: chave (chamador = terminal id ou "app", arquivo); criados sob demanda (`MCPStdioClient` com `figcraft-cli mcp` + `collab.join {link}` + espera `status == live && !readOnly`); 5 min ocioso → fecha; máx. 8 vivos (fecha o ocioso mais antigo; todos ocupados → `unavailable` "design engine busy"); painel/arquivo fechado ou terminal removido → fecha os dele. Cliente morto ou servidor reiniciado → recriado uma vez na mesma chamada.

- [ ] **Step 1: Testes que falham** (`DesignCommandTests`, `.serialized`, com os fakes):
  - `newFileThenOpenPanel`: `design.new "Site"` → `design.files` lista; `panel.open design --file Site` → `state["file"]`; nomes duplicados (caixa diferente) recusados.
  - `fileNamesAreValidated`: `../x`, `a/b`, `""`, 81 chars, `con\u{0}` → `invalidArgs`.
  - `runAndBatchUseCallerClient`: dois terminais com corda ao painel → log do fake mostra dois `initialize` com nomes diferentes; `design.batch` com `bad.x` no passo 2 → erro contendo "step 2", log sem efeito aplicado (`badBatchLeavesDocumentUnchanged`).
  - `oversizedBatchRefused` (5 MiB → `invalidArgs` sem chamar o fake).
  - `readsSyncFirst`: `design.inspect` → log mostra sincronização antes de `get_node` (enquanto o patch 0002 não existir no fake, `collab.peers`).
  - `canvasDesignNeedsCord`; `linkIsAdminOnly` (terminal → `unauthorized`/não exposto); `agentsNeverSeeLink` (nenhum resultado de comando de terminal contém `figcraft://`/`token=`).
  - `screenshotAndExportWriteUnderRoot`; `idleClientCloses` (ocioso injetável 0,3 s); `maxEightClients`; `clientRecreatedAfterServerRestart`; `panelCloseClosesClients`.
  - Integração real (`.enabled(if: vendor figcraft presente)`): `realEngineRoundTrip` (new → batch de 3 comandos → inspect vê os nós → export html contém o texto) e `twoCallersHaveSeparateUndo`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter "DesignCommand|PanelCommand|Commands|MCP"` → PASS.
- [ ] **Step 5:** Commit `feat(design): design files and agent commands over figcraft`.

### Task 4: Painel Design no app

**Files:** Create `Sources/OrqPlugins/DesignPanel.swift`, `Tests/OrqPluginsTests/DesignPanelTests.swift`; Modify `Sources/OrqApp/{OrqApp,OpenPanelSheet}.swift`, `Sources/OrqClient/DaemonClient.swift`, `Resources/Info.plist` (se preciso), `README.md`, roteiro da Fase 2

**Interfaces:**
- Consumes: `design.link` (admin), `design.files`, `design.new`, `panel.open --file` (Task 3); `Contents/Resources/figcraft/web` (Task 1).
- Produces: `DesignPanel: PluginPanelView` registrado como `"design"`; `final class DesignSchemeHandler: NSObject, WKURLSchemeHandler` servindo `orq-design://app/<caminho>` a partir da pasta web (MIME: `.wasm` → `application/wasm`, `.js` → `text/javascript`, `.html`, `.css`, `.json`, `.png`, `.svg`, `.woff2`; caminho normalizado, fora da pasta → 404; nada além de GET). `func designURL(editLink: String) -> URL` = `orq-design://app/index.html?webgl#join=<editLink percent-encoded>`.
- Comportamento: ao montar (janela não nula) pede `design.link` e carrega a URL; WKWebView com `WKWebsiteDataStore.nonPersistent()`; navegação só `orq-design:`/`about:`; erro de carga ou do processo web → rótulo "Motor de design indisponível" + **Reconectar**; `close()` libera a webview. `handle` → `unavailable` (comandos rodam no daemon). Se `ws://127.0.0.1` a partir de `orq-design://` for bloqueado no WKWebView, o implementador troca para o daemon servir a pasta web em `http://127.0.0.1:<porta>` (só loopback) e registra a decisão — mesma `designURL` com o esquema http.
- `OpenPanelSheet`: plug-in `design` → seletor dos arquivos (`design.files`) + campo "Novo arquivo…" (chama `design.new`); sem URL/armazenamento/aparelho.

- [ ] **Step 1: Testes que falham** (`DesignPanelTests`): `schemeServesWasmWithMime`, `schemeRejectsTraversal` (`../../etc/passwd`, `%2e%2e/`), `schemeOnlyGet`, `designURLEncodesLink` (link com `&`, `=`, `#` preservado no fragmento), `panelRegistersAndRefusesCommands`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** `swift build`; suíte inteira `swift test` → PASS; `scripts/bundle-app.sh` ok.
- [ ] **Step 5:** README: seção "Design" (build do figcraft com `scripts/build-figcraft.sh`, pré-requisito rustup, abrir painel Design, comandos `orq design …`, limitações: export HTML ainda cru até o 2C, versão fixada v0.7.0). Roteiro: 2A aponta este plano. Commit `feat(app): Design panel with the live figcraft UI`.

---

## Limitações conhecidas (aceitas neste plano)

- Export HTML sai como o figcraft gera (só `div/p`, flexbox, `:root` só do modo atual, px fixos) — corrigido no 2C.
- Design systems (biblioteca, troca, histórico) e Artifacts ficam para 2B/2C; importar HTML para 2D.
- Protocolo de colaboração do figcraft é "draft"; server/CLI/web sempre na mesma versão.
- Arquivos de design vivem no armazenamento do servidor local (não no git); `design.export --format figcraft` gera o `.figcraft` para versionar quando quiser.
