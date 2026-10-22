# Plano 2F — Ambiente dos agentes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolver dois problemas vistos no app em 2026-10-21. (1) Agentes lançados pelo Orq rodam com o ambiente do usuário como um terminal interativo teria: o `node` do nvm, que vem do `.zshrc`, passa a ser achado pelos hooks globais do próprio usuário. (2) O agente sabe que está no Orq: o servidor MCP `orq` vem ligado por terminal, e o início de sessão diz, em poucas linhas, quais ferramentas do Orq ele alcança. Exemplo: `orq design` para o painel Design ligado a ele, em vez de editores ou artifacts externos.

**Architecture:** (1) Um `UserEnvironment` (actor no daemon) captura uma vez `$SHELL -ilc` → `env -0` (com marcador, prazo de 5 s, fora do pool, cache de 10 min). O `launchSpec` do `CommandRouter` passa a montar o ambiente dos presets de comando a partir dele; as chaves do Orq e o `orq` à frente do `PATH` continuam prevalecendo. (2) O `AgentLaunch` grava um `<hooksDir>/<id>.mcp.json` (Claude, `--mcp-config`) e passa `-c mcp_servers.orq.*` (Codex). Nenhum dos dois carrega segredo, porque o `orq mcp` herda a credencial do ambiente do terminal. A lista de ferramentas do `orq mcp` passa a ser filtrada pelo alcance real (painéis ao alcance). Um `OrqOrientation` (puro) gera o texto de orientação, que o `memory.hookContext` põe antes da memória.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing; nenhuma dependência nova.

**Spec:** diagnóstico com causa raiz confirmada (controlador, 2026-10-21; resumo no Contexto abaixo). v1 `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §5 (cordas, presets, MCP), §6 (plug-ins ao alcance), §8 (injeção no início de sessão). Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md` (linha 2F). Base: `main` depois do merge do 2E. **Roda antes do 3A.**

**Contexto (diagnóstico):** `orqd` sobe pelo launchd com `PATH` mínimo e lança agentes com `zsh -lc "<comando>"` (`AgentLaunch.swift`, `spec(["-lc", …])`). Shell de login não interativo lê `.zprofile` e **não** `.zshrc`. Nesta máquina o `node` vem do nvm no `.zshrc`, então `env -i HOME=$HOME /bin/zsh -lc 'command -v node'` não acha nada; o `claude` é achado porque `~/.local/bin` está no `.zprofile`. O preset Shell (`zsh -l`, interativo) não tem o problema. À parte disso, o agente usou a ferramenta Artifact do claude.ai em vez de `orq design …`: o Orq não passa `--mcp-config`, e o `memory.hookContext` só injeta memória.

## Global Constraints

- **Nada de configuração global do usuário:** nada em `~/.claude/`, `~/.codex/`, `.zshrc`/`.zprofile` nem nos repositórios; MCP e orientação só por flag/arquivo por terminal em `<root>/hooks/` (como o `--settings` da v1).
- **Corda é a única permissão:** o MCP e o texto de orientação **só listam o que o terminal alcança** (comandos de núcleo, comandos de Maestro só para Maestro, comandos de plug-in só quando há painel daquele plug-in ao alcance — o mesmo critério do `panel.list` do terminal). O daemon continua checando tudo na chamada; a lista é só o que o agente vê.
- **Segredos nunca em env/arquivos legíveis por outros, nem em argv:** o token do terminal continua só no env do processo do agente (como hoje); arquivos gerados são 0600 em `hooks/` (0700) e **não** contêm token; nada de token em linha de comando (visível no `ps`). Valores do ambiente capturado nunca vão para log (só contagem de chaves e o motivo de falha).
- **Nada de I/O bloqueante no pool cooperativo:** a captura do ambiente roda num processo com prazo (o `BoundedProcess` da v1), fora do pool; o primeiro lançamento espera no máximo o prazo, os seguintes usam o cache.
- Falhas nunca impedem lançar: captura falhou ou estourou o prazo → ambiente atual do daemon (o de hoje) + aviso em log; MCP/orientação indisponíveis → o agente sobe igual.
- Protocolo `v: 1`, nada muda no fio; textos ao agente em **inglês** (curtos); textos ao usuário em português.

## Review Focus

1. **`.zshrc` barulhento ou que trava** (imprime banner, `tmux` auto-attach, `read`, `nvm` lento) → a captura usa marcador e lê só depois dele; prazo de 5 s mata o processo (e o grupo) e cai no ambiente atual; nada aparece no terminal do agente. Teste: Task 1 `noisyRcParsedAfterMarker`, `hangingRcTimesOut`.
2. **Variáveis de sessão do terminal do usuário** (`TMUX`, `TERM_SESSION_ID`, `SHLVL`, `PWD`, `OLDPWD`, `_`, `ITERM_*`, `TERM`, `COLORTERM`) não vazam para o agente; `ORQ_*`, `TERM=xterm-256color`, `TERM_PROGRAM=Orq`, `SHELL` e o `orq` à frente do `PATH` vêm do Orq e prevalecem. Teste: Task 1 `orqKeysWin`, `sessionVarsDropped`.
3. **Usuário instala o nvm/muda o `.zshrc` com o Orq aberto** → o cache expira em 10 min (ou ao mudar o mtime de `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`) e o próximo lançamento captura de novo. Teste: Task 1 `cacheInvalidatesOnRcChange`.
4. **Terminal sem painel Design ao alcance** → nem o MCP nem a orientação mencionam `design`; ganha uma corda para um Design → o `orq mcp` avisa `tools/list_changed` e a lista passa a ter `design_*`. Teste: Task 2 `toolsFollowReach`, Task 3 `orientationFollowsReach`.
5. **Usuário já tem um MCP chamado `orq`** no próprio `~/.claude.json`, ou usa outros MCPs → o Orq não usa `--strict-mcp-config` (os MCPs do usuário continuam); conflito de nome: o do Orq se chama `orq` e o arquivo por terminal tem precedência de flag; documentar no README. Teste: Task 2 `mcpConfigIsAdditive` (sem `--strict-mcp-config` no comando).

---

## File Structure

```
Sources/OrqDaemonKit/UserEnvironment.swift      captura, parsing, filtro, cache do ambiente do usuário
Sources/OrqDaemonKit/{CommandRouter,AgentLaunch,Daemon}.swift
Sources/OrqProtocol/MCPSchema.swift             tools(reach:) filtrado por plug-ins ao alcance
Sources/orq/MCPServer.swift                     consulta o alcance; tools/list_changed
Sources/OrqDaemonKit/OrqOrientation.swift       texto "you are in Orq" por alcance (puro)
Sources/OrqDaemonKit/MemoryCommands.swift       hookContext = orientação + memória
Tests/OrqDaemonKitTests/{UserEnvironmentTests,AgentLaunchTests,OrqOrientationTests,MemoryHookTests}.swift
Tests/OrqProtocolTests/MCPTests.swift
README.md
```

---

### Task 1: Ambiente do usuário como num terminal interativo

**Files:** Create `Sources/OrqDaemonKit/UserEnvironment.swift`, `Tests/OrqDaemonKitTests/UserEnvironmentTests.swift`; Modify `Sources/OrqDaemonKit/{CommandRouter,Daemon}.swift`

**Interfaces:**
- Produces: `actor UserEnvironment { init(shell: String, home: URL, ttl: Duration = .seconds(600), timeout: Duration = .seconds(5), run: Runner = .live); func current() async -> [String: String] /* capturado e filtrado, ou [:] se falhou */; func warm() /* dispara a captura em segundo plano */; static func parse(_ output: Data, marker: String) -> [String: String]?; static func filtered(_ env: [String: String]) -> [String: String]; static func merge(user: [String: String], orq: [String: String], orqBin: String) -> [String: String] }`.
  - `typealias Runner` = função `@Sendable (_ shell: String, _ args: [String], _ env: [String: String], _ timeout: Duration) async -> Data?` (live = `BoundedProcess` com stdin `/dev/null`, sem TTY, matando o grupo do processo no prazo; injetável nos testes).
  - Comando: `shell -ilc 'printf "\n__ORQ_ENV_BEGIN__\0"; env -0'` com env mínimo `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `TERM=dumb`, `ORQ_ENV_CAPTURE=1` (o usuário pode testar isso no `.zshrc` para pular coisas). Para `bash`, os mesmos flags; outro shell (`fish` etc.) → `shell -lc` sem `-i`.
  - `parse`: procura o **último** `__ORQ_ENV_BEGIN__\0`; depois dele, pares `K=V` separados por `\0`; sem marcador → nil.
  - `filtered`: remove `TMUX`, `TMUX_PANE`, `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERM_SESSION_ID`, `COLORTERM`, `SHLVL`, `PWD`, `OLDPWD`, `_`, `ORQ_ENV_CAPTURE`, chaves com prefixo `ITERM_`, `ORQ_`, `__CF`, `XPC_`. `SSH_AUTH_SOCK` **fica** (git por ssh).
  - `merge`: começa do usuário filtrado; sobrescreve com as chaves do Orq (`ORQ_*`, `TERM`, `TERM_PROGRAM`, `SHELL`, `HOME`, `USER`, `LANG` quando o usuário não tem); `PATH` = `orqBin` + `:` + (`PATH` do usuário ou o do daemon), sem duplicar `orqBin`.
  - Cache: válido por `ttl` e enquanto o mtime de `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`, `~/.profile` não mudar; captura em andamento é compartilhada (chamadas simultâneas esperam a mesma). Falha → `[:]` com log `orqd: env: capture failed (<motivo>)`, e nova tentativa só depois de 60 s.
- `CommandRouter.launchSpec`: para presets `claude`, `codex`, `custom` (e `cursor` quando o 3E existir), `e = UserEnvironment.merge(user: await userEnv.current(), orq: <as chaves que já monta hoje>, orqBin: …)`; preset `shell` fica como hoje (o shell interativo lê o `.zshrc` sozinho). `launchSpec` passa a ser `async`. `Daemon` cria o `UserEnvironment` e chama `warm()` ao subir.
- [ ] **Step 1: Testes** (runner falso, e um teste com shell real gated por `/bin/zsh` existir): `parsesAfterMarker`; `noisyRcParsedAfterMarker` (saída com banner e códigos ANSI antes do marcador → só as variáveis); `hangingRcTimesOut` (runner que nunca volta + relógio → `[:]` em ≤ prazo, log com o motivo e sem valores); `sessionVarsDropped`; `orqKeysWin` (usuário com `ORQ_TOKEN=x`, `TERM=screen`, `PATH=/a:/b` → token do Orq, `xterm-256color`, `PATH` = `<orqBin>:/a:/b`); `cacheReusedAndShared` (3 chamadas → 1 captura); `cacheInvalidatesOnRcChange` (tocar o `.zshrc` de um HOME temporário → nova captura); `realZshReadsZshrc` (HOME temporário com `.zshrc` exportando `ORQ_TEST_FROM_ZSHRC=1` → aparece; com `echo oi` e `printf '\e]0;x\a'` no `.zshrc` → ainda parseia); `shellPresetUnchanged`; `claudeLaunchUsesUserPath` (o `LaunchSpec.environment` do claude tem o `PATH` do usuário capturado).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "UserEnvironmentTests|AgentLaunchTests"`). **Step 5:** Commit `fix(agents): launch agents with the user's interactive environment`.

### Task 2: MCP do Orq ligado por terminal, filtrado pelo alcance

**Files:** Modify `Sources/OrqDaemonKit/AgentLaunch.swift`, `Sources/OrqProtocol/MCPSchema.swift`, `Sources/orq/MCPServer.swift`; Test `Tests/OrqDaemonKitTests/AgentLaunchTests.swift`, `Tests/OrqProtocolTests/MCPTests.swift`

**Interfaces:**
- `AgentLaunch` (claude): grava `<hooksDir>/<id>.mcp.json` (0600) = `{"mcpServers": {"orq": {"type": "stdio", "command": "<caminho absoluto do orq>", "args": ["mcp"]}}}` — **sem `env`** (o processo do MCP herda `ORQ_SOCKET`/`ORQ_TERMINAL_ID`/`ORQ_TOKEN` do agente, como os hooks). Comando passa a `<base> --settings <hooks> --mcp-config <mcp>`; **sem** `--strict-mcp-config`. `removeHooks` apaga também o `.mcp.json`. Comando próprio começando por `claude` recebe as mesmas flags (como hoje com `--settings`).
- `AgentLaunch` (codex): acrescenta `-c 'mcp_servers.orq.command="<orq>"' -c 'mcp_servers.orq.args=["mcp"]'` e repassa as variáveis com o mecanismo de passagem de env do Codex instalado (`mcp_servers.orq.env_vars=["ORQ_SOCKET","ORQ_TERMINAL_ID","ORQ_TOKEN","ORQ_TERMINAL_NAME","ORQ_WORKSPACE_ID","ORQ_MAESTRO"]` ou o nome equivalente). O builder confere em `codex --help`/`codex mcp --help` e na doc instalada **sem rodar o agente nem gastar tokens**, e anota o que viu. Se o Codex só aceitar `env` com **valores** (o token ficaria no argv) → não liga o MCP no Codex nesta task, anota no README como limitação e segue.
- `MCPSchema.tools(maestro: Bool, plugins: Set<String>?) -> [JSONValue]`: `plugins == nil` = todos (compatível); senão, comandos de plug-in só dos ids no conjunto. Núcleo, `floor.*`, `memory.*` e `panel.*` sempre (conforme `maestroOnly`).
- `MCPServer`: no `tools/list`, chama `panel.list` com a credencial do terminal (o alcance que o daemon já aplica) e passa `plugins = Set(painéis.map(\.pluginId))`; erro → `plugins = []` (só núcleo). `initialize` anuncia `capabilities.tools.listChanged: true`; enquanto a sessão MCP vive, repete `panel.list` a cada 10 s e manda `notifications/tools/list_changed` quando o conjunto muda (`// ponytail: poll 10 s; trocar por stream de eventos se custar`).
- Descrição de ferramenta: o `summary` dos comandos `design.*` passa a começar por "Orq Design panel corded to you: …" (só texto; o resto igual).
- [ ] **Step 1: Testes:** `mcpConfigWritten` (arquivo 0600, `command` absoluto, `args == ["mcp"]`, nenhum `ORQ_TOKEN`/token no conteúdo); `mcpConfigIsAdditive` (comando tem `--mcp-config` e não tem `--strict-mcp-config`); `customClaudeCommandGetsMcp`; `removeHooksRemovesMcp`; `codexGetsMcpWithoutSecretsInArgv` (o comando gerado não contém o valor do token; se a task cair no caminho "não liga", o teste afirma que não há `mcp_servers` no comando); `toolsFollowReach` (MCPTests com daemon falso: sem painel `design` ao alcance → nenhum `design_*`; com → presentes; Maestro vê `recruit`, terminal comum não); `listChangedOnReachChange` (o falso muda o `panel.list` → uma `notifications/tools/list_changed`).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "AgentLaunchTests|MCPTests"`). **Step 5:** Commit `feat(agents): wire the orq MCP server per terminal`.

### Task 3: Orientação "você está no Orq" no início de sessão

**Files:** Create `Sources/OrqDaemonKit/OrqOrientation.swift`, `Tests/OrqDaemonKitTests/OrqOrientationTests.swift`; Modify `Sources/OrqDaemonKit/MemoryCommands.swift`; Test `Tests/OrqDaemonKitTests/MemoryHookTests.swift`

**Interfaces:**
- Produces: `enum OrqOrientation { static func text(terminal: String, isMaestro: Bool, floor: String?, peers: [String] /* terminais ao alcance */, panels: [(name: String, pluginId: String)] /* painéis ao alcance */) -> String }` — inglês, ≤ 1 200 caracteres, sem nomes de arquivos/links/tokens. Forma:
  ```
  You are running inside Orq, terminal "<nome>"<, on floor "<andar>">. Use Orq's tools (the `orq` MCP server, or the `orq` CLI) for this workspace:
  - Talk to agents corded to you: orq list / orq ask <name> "<prompt>" / orq check <name> (<peers ou "none yet">).
  - Project memory: orq memory search|save — check it before re-reading code.
  - Design panel "<nome>": orq design … builds screens there. Do not use other design editors or external artifact tools for this workspace's screens.   ← só se houver painel design ao alcance
  - Browser panel "<nome>": orq browser … to open and check pages.            ← só se houver browser
  - Artifacts: orq artifact … keeps exported/handed-in pages.                  ← só se houver artifacts
  - Device "<nome>": orq device … (screenshot, tap, logs).                     ← só se houver device
  - As Maestro you can open panels: orq panel open design --file <name> | browser --url <url> | device [--serial <id>] (it lands corded to you; your floor if you are on one).
    Give one to an agent with orq connect <agent> <panel>; close or move with orq panel close|move. Team: orq recruit|dismiss|connect, orq floor …   ← só Maestro (plug-ins listados = os que aceitam canvas no PluginRegistry)
  Run `orq <group> --help` for details.
  ```
  Linhas de plug-in só para os presentes, nomes dos painéis entre aspas (cortados em 40 chars cada; no máximo 3 por plug-in, "+n more").
- `panel.open` (`Commands.swift`): o `help` do parâmetro `plugin` passa a ser gerado do `PluginRegistry` (ids que aceitam `.canvas` ou doca), em vez do texto fixo "browser|device|design". Pedido do usuário em 2026-10-21: Maestro deve saber que pode abrir e gerenciar painéis (o poder já existe desde o 1D: `panel.open|close|move` são `maestroOnly`, o painel aberto nasce com corda para ele, e `connect <agente> <painel>` entrega a um recrutado).
- `memory.hookContext` devolve `OrqOrientation.text(...) + "\n\n" + <memória de hoje>` (memória vazia → só a orientação). Alcance pelo `ConnectionGraph` (`reachable` / `reachablePanels`) do terminal chamador — o mesmo critério do `panel.list`. O `SessionStart` da v1 já roda também após compactação (`source: compact`), então a orientação volta depois de compactar.
- Codex: sem hook de início de sessão na v1 → a orientação não é injetada; o MCP da Task 2 (se ligado) traz as descrições. Anotar no README.
- [ ] **Step 1: Testes:** `orientationFollowsReach` (sem painéis → sem linhas de design/browser; com Design "Home" → linha com `"Home"` e "Do not use other design editors"; Maestro → linha de Maestro com `orq panel open` e os plug-ins de canvas (design, browser, device), mesmo sem nenhum painel aberto; terminal comum → sem linha de Maestro nem `panel open`); `orientationIsBounded` (20 painéis de cada tipo → ≤ 1 200 chars, "+n more"); `orientationHasNoSecrets` (nenhum token, link `orq-design://`/`#join=` ou caminho do `root`); `hookContextStartsWithOrientation` (MemoryHookTests: `memory.hookContext` de um terminal com Design ao alcance começa com "You are running inside Orq" e menciona `orq design`; sem Design não menciona); `hookContextWithoutMemory`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "OrqOrientationTests|MemoryHookTests"`). **Step 5:** Commit `feat(agents): tell agents they are in Orq and what they can reach`.

### Task 4: Docs e verificação

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`; Create (scratchpad) `plan2f-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem).
- [ ] **Step 2:** README: "Ambiente dos agentes" (o Orq captura o ambiente do shell interativo — `$SHELL -ilc` — e usa o `PATH` dele; `ORQ_ENV_CAPTURE=1` para pular trechos lentos do `.zshrc`; cache de 10 min; Shell não muda) e "Ferramentas do Orq no agente" (MCP `orq` por terminal, sem mexer nos MCPs do usuário; orientação no início de sessão; limitação do Codex conforme a Task 2/3). Roteiro: 2F "em execução".
- [ ] **Step 3:** Checklist humana no scratchpad: no app, abrir um Claude, mandar um prompt e ver que **não** aparecem `UserPromptSubmit hook error … "node"` nem `PostToolBatch hook error`; `/mcp` no Claude lista `orq`; ligar um painel Design por corda e pedir "Cria uma tela simples de um Hello World na tela de design conectada" → o agente usa `orq design …` (não Artifact externo) e a tela aparece no painel; um terminal sem Design ao alcance não lista `design_*` no `/mcp`.
- [ ] **Step 4:** Commit `docs: agent environment`.
