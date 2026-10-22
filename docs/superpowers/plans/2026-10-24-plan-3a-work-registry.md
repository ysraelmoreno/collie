# Plano 3A — Registro de trabalho — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O daemon mantém, por workspace, um registro de **trabalhos** (com tarefas, subagentes e shells em segundo plano), alimentado pelos hooks do Claude Code e por comandos `orq work …`, que sobrevive a compactação e reinício, fecha por merge/agente/usuário e arquiva o que fecha — a base que o chat (3B) e o resumo (3C) leem.

**Architecture:** Um `WorkStore` (actor, JSON por workspace na pasta de dados do Orq, escrita atômica fora do pool) guarda trabalhos e histórico. Um parser puro (`WorkHookParser`) transforma o JSON de stdin dos hooks do Claude Code em eventos (`WorkEvent`); o `orq hook claude-tool` / `claude-subagent-stop` / `claude-precompact` manda o JSON bruto ao daemon (`work.hook`, credencial de terminal), que aplica os eventos. Comandos `work.*` (núcleo, como `memory.*`) seguem as regras de corda. O fechamento por merge usa o `GitRunner` da v1.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing; nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-24-phase3-design.md` §4 (Registro de trabalho), §3, §8; v1 `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §5 (cordas), §8 (memória). Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`. Base: `main` depois do merge do 2E e do 2F.

## Global Constraints

- **Corda é a única permissão:** um terminal mexe no **próprio** trabalho; um Maestro também nos trabalhos dos terminais que alcança por corda; o app (admin) em tudo (spec §4.6).
- O registro **não inventa estado**: `sumiu` só quando o daemon confirma (terminal/processo do agente morto); sem confirmação, `desconhecido` depois de um tempo sem sinal (spec §4.3).
- **Nada é apagado sem o usuário:** fechar arquiva; "reabrir" desfaz; só "limpar histórico" (admin) apaga.
- Hooks **por terminal, por flag**, no arquivo `<hooksDir>/<id>.claude.json` que `AgentLaunch.launchSpec` já grava; nada de configuração global. `orq hook …` **nunca falha nem imprime** (erros em `hooks.log`), e nunca atrasa o agente: timeout de hook ≤ 5 s, envio ao daemon com timeout curto.
- Nenhum token gasto: nada aqui chama modelos.
- Protocolo `v: 1`, só comandos/campos **novos**; nada de I/O bloqueante no pool cooperativo; payload de hook limitado (64 KiB por evento; o resto é descartado com log).

## Review Focus

1. **Lista de tarefas reescrita inteira a cada chamada** (o agente manda a lista toda de novo, reordenada, com uma tarefa a menos) → diff correto: só a mudança vira evento; tarefa que saiu sem estar feita vira `abandonada` sem motivo. Teste: Task 2 `todoListDiff`.
2. **Hook com JSON inesperado** (campo novo, ferramenta desconhecida, payload gigante, stdin vazio) → ignorado com log, nenhum erro para o agente, registro intacto. Teste: Task 2 `unknownPayloadsIgnored`.
3. **Terminal morre com subagentes/shells "rodando"** → todos viram `sumiu`; trabalho continua ativo. Teste: Task 3 `terminalDeathMarksJobsGone`.
4. **Merge de branch que não é de nenhum trabalho / trabalho no térreo** → nada fecha sozinho. Teste: Task 4 `groundWorkNeverAutoCloses`.
5. **Muitos eventos rápidos** (agente com 600 tarefas, centenas de trabalhos fechados) → limites fixos: 500 tarefas e 200 jobs por trabalho, 200 trabalhos fechados no `work.json`; o excedente mais antigo vai para `work-archive.jsonl` (só acréscimo, nada é apagado). Teste: Task 1 `limitsHold`.

---

## File Structure

```
Sources/OrqCore/Work.swift                      modelos (Work, WorkTask, WorkJob, estados) — compartilhados com o app no 3B
Sources/OrqDaemonKit/Work/WorkStore.swift       actor: persistência, transições, histórico, limites
Sources/OrqDaemonKit/Work/WorkHookParser.swift  stdin dos hooks do Claude Code → [WorkEvent] (puro)
Sources/OrqDaemonKit/WorkCommands.swift         work.* + work.hook + liveness + fechamento por merge
Sources/OrqDaemonKit/{CommandRouter,AgentLaunch,FloorManager,Daemon}.swift
Sources/OrqProtocol/Commands.swift              (+ work.*, admin.data.*)
Sources/OrqDaemonKit/DataBackup.swift           exportar/importar dados do Orq (.orqbackup)
Sources/orq/HookCommands.swift                  (+ claude-tool, claude-subagent-stop, claude-precompact)
Tests/Fixtures/claude-hooks/*.json              payloads de exemplo (escritos à mão a partir do formato documentado)
Tests/OrqDaemonKitTests/{WorkStoreTests,WorkHookParserTests,WorkCommandTests}.swift
README.md
```

---

### Task 1: Modelos e `WorkStore`

**Files:** Create `Sources/OrqCore/Work.swift`, `Sources/OrqDaemonKit/Work/WorkStore.swift`, `Tests/OrqDaemonKitTests/WorkStoreTests.swift`

**Interfaces:**
- Produces (OrqCore, `Codable, Sendable, Equatable`):
  - `enum TaskState: String { case open, inProgress, done, deferred, abandoned }`
  - `struct WorkTask { var id: String /* do agente, ou gerado */; var title: String; var state: TaskState; var reason: String?; var updatedAt: Date }`
  - `enum JobKind: String { case subagent, shell }`; `enum JobState: String { case running, finished, gone, unknown }`
  - `struct WorkJob { var id: String /* tool_use_id */; var kind: JobKind; var label: String; var state: JobState; var startedAt: Date; var endedAt: Date?; var result: String? /* ≤ 280 chars */; var pid: Int32? }`
  - `struct WorkNote { var at: Date; var text: String; var decision: Bool }`
  - `struct Work { var id: UUID; var title: String; var terminalId: UUID; var floorId: UUID?; var branch: String?; var openedAt: Date; var closedAt: Date?; var closedBy: String? /* "merge" | "agent:<nome>" | "app" */; var tasks: [WorkTask]; var jobs: [WorkJob]; var notes: [WorkNote]; var commits: [String] /* sha curto + assunto, ≤ 200 */ }`
- Produces (OrqDaemonKit): `actor WorkStore { init(dir: URL); func active(terminal: UUID) -> Work?; func list(includeClosed: Bool) -> [Work]; func get(_ id: UUID) -> Work?; func start(title: String, terminal: UUID, floorId: UUID?, branch: String?) throws -> Work; func update(_ id: UUID, _ change: (inout Work) -> Void) throws; func close(_ id: UUID, by: String) throws; func reopen(_ id: UUID) throws; func clearHistory() throws }`
- Regras: um terminal tem no máximo um trabalho ativo (`start` com um ativo → `.invalidArgs` "work already open: <título>"); `close` marca `closedAt/closedBy`, tarefas `open|inProgress` ficam como estão (o resumo do 3C as lê como "não feito"); `reopen` limpa `closedAt/closedBy`. Persistência: `<dir>/work.json` (0600, atômico, fora do pool, mutações serializadas como no `ArtifactStore` do 2C) com ativos + 200 fechados mais recentes; os mais antigos vão para `work-archive.jsonl` (só acréscimo). Limites: 500 tarefas por trabalho (excedente: o mais antigo `done` sai para `work-archive.jsonl`), 200 jobs por trabalho (idem), 200 notas.
- [ ] **Step 1: Testes:** `startCloseReopen`, `oneActivePerTerminal`, `persistsAcrossReload` (novo `WorkStore` no mesmo dir lê o mesmo), `limitsHold` (600 tarefas → 500 no trabalho, 100 no arquivo morto; 250 fechados → 200 no `work.json`, 50 no arquivo morto), `clearHistory` (fechados somem, ativos ficam).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkStoreTests`). **Step 5:** Commit `feat(work): work registry store`.

### Task 2: Parser dos hooks do Claude Code

**Files:** Create `Sources/OrqDaemonKit/Work/WorkHookParser.swift`, `Tests/OrqDaemonKitTests/WorkHookParserTests.swift`, `Tests/Fixtures/claude-hooks/*.json`

**Interfaces:**
- Produces: `enum WorkEvent: Equatable, Sendable { case tasks([WorkTask]) /* lista completa vista agora */; case taskChanged(WorkTask); case jobStarted(WorkJob); case jobEnded(id: String, result: String?); case compacted; case sessionEnded }`; `enum WorkHookParser { static let maxBytes = 64 * 1024; static func events(hook: String /* "tool" | "subagent-stop" | "precompact" | "session-end" */, json: Data, now: Date) -> [WorkEvent]; static func diff(old: [WorkTask], new: [WorkTask], now: Date) -> [WorkTask] /* resultado para gravar */ }`.
- Mapeamento (`hook == "tool"`, JSON `PostToolUse`: `tool_name`, `tool_input`, `tool_response`, `tool_use_id`):
  - `TodoWrite` (`tool_input.todos: [{content, status: pending|in_progress|completed, activeForm?, id?}]`) → `.tasks` com `id` = `id` ou hash estável do `content`, estados `pending→open`, `in_progress→inProgress`, `completed→done`.
  - Ferramentas de tarefa que criam/atualizam uma por vez (nome contendo `Task` e com `subject`/`description`/`status`/`taskId` no input — ex.: `TaskCreate`, `TaskUpdate`) → `.taskChanged`. Aceitar os dois formatos; o builder confere na versão instalada (`claude --version`; **não** rodar o agente nem gastar tokens) e documenta o que viu.
  - `Task`/`Agent` (lança subagente: `description`/`prompt`/`subagent_type`) → `.jobStarted(kind: subagent, id: tool_use_id, label: description)`; o `tool_response` do mesmo `PostToolUse` (síncrono) já traz o fim → também `.jobEnded` com o texto curto; se o input tem `run_in_background: true`, só `.jobStarted`.
  - `Bash` com `run_in_background: true` → `.jobStarted(kind: shell, label: command ≤ 80 chars, id: o id de shell no `tool_response` se houver, senão tool_use_id)`; `BashOutput`/`KillShell`/ferramentas de saída de shell com status terminado/morto no response → `.jobEnded`.
  - Qualquer outra ferramenta → `[]`.
  - `subagent-stop` → `.jobEnded` do subagente em segundo plano mais antigo ainda `running` desse terminal (o payload não diz qual) — documentar a heurística com `// ponytail:`.
  - `precompact` → `.compacted`; `session-end` → `.sessionEnded`.
  - JSON inválido, vazio, acima de `maxBytes` ou sem os campos → `[]`.
- `diff`: tarefas novas entram; mudou o estado → atualiza `updatedAt`; tarefa que **sumiu** da lista nova sem estar `done` → `abandoned` (motivo nil); tarefas `deferred`/`abandoned` com motivo (vindas de comando) não são reabertas pela lista do agente a menos que reapareçam com outro estado.
- Fixtures em `Tests/Fixtures/claude-hooks/`: `todowrite-1.json`, `todowrite-2.json` (mesma lista reordenada, uma concluída, uma removida), `taskcreate.json`, `taskupdate.json`, `agent.json`, `agent-background.json`, `bash-background.json`, `bashoutput-done.json`, `unknown-tool.json`, `subagent-stop.json`, `precompact.json` — escritas à mão com o formato documentado dos hooks (sem dados reais).
- [ ] **Step 1: Testes:** `todoListDiff` (todowrite-1 → todowrite-2: uma `done`, uma `abandoned`, ordem irrelevante, ids estáveis); `singleTaskTools`; `subagentSyncAndBackground`; `backgroundShellLifecycle`; `unknownPayloadsIgnored` (ferramenta desconhecida, `{}`, bytes aleatórios, 70 KiB → `[]`).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkHookParserTests`). **Step 5:** Commit `feat(work): parse claude code hook payloads`.

### Task 3: Hooks ligados, `work.hook` e vida dos jobs

**Files:** Create `Sources/OrqDaemonKit/WorkCommands.swift`, `Tests/OrqDaemonKitTests/WorkCommandTests.swift`; Modify `Sources/OrqDaemonKit/{AgentLaunch,CommandRouter,Daemon}.swift`, `Sources/orq/HookCommands.swift`, `Sources/OrqProtocol/Commands.swift`

**Interfaces:**
- `AgentLaunch.launchSpec` (claude): o arquivo de hooks ganha `PostToolUse` com `matcher` `TodoWrite|Task.*|Agent|Bash|BashOutput|KillShell` → `orq hook claude-tool` (timeout 5), `SubagentStop` → `claude-subagent-stop`, `PreCompact` → `claude-precompact`, `SessionEnd` → `claude-session-end` (os existentes continuam).
- `orq hook claude-tool|claude-subagent-stop|claude-precompact|claude-session-end`: lê stdin (≤ 64 KiB; maior → log e sai), manda `work.hook {hook, payload /* o JSON bruto como string */}` com a credencial do terminal (`ORQ_TERMINAL_ID`/`ORQ_TOKEN`), timeout 2 s, nunca imprime nem falha.
- `work.hook` (`exposedToMCP: false`, só terminal): `WorkHookParser.events` → aplica no trabalho **ativo** do terminal; sem trabalho ativo, **abre um implícito** com título provisório `"<nome do terminal> — <data>"` na primeira tarefa ou job (spec §4.1c); `.compacted`/`.sessionEnded` viram nota.
- Vida dos jobs: quando o processo de um terminal termina (o daemon já sabe — `TerminalRegistry`/PTY reap), todo job `running` dos trabalhos dele vira `gone`; um job `running` sem sinal por 30 min vira `unknown` (varredura a cada 60 s, só toca trabalhos com jobs `running`); shell com `pid` conhecido que não existe (`kill(pid, 0)` → ESRCH) vira `gone`.
- [ ] **Step 1: Testes** (daemon em processo, como os testes de memória): `hookFeedsActiveWork` (dois `work.hook` com os fixtures todowrite → trabalho implícito com as tarefas certas); `hookNeverFailsTheAgent` (payload inválido → `ok` com nada aplicado); `terminalDeathMarksJobsGone` (job `running` + kill do terminal → `gone`); `silentJobsBecomeUnknown` (relógio injetável: 31 min → `unknown`); `hooksFileListsNewEvents` (o JSON gerado por `launchSpec` tem as quatro entradas novas com o `matcher` exato).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkCommandTests`). **Step 5:** Commit `feat(work): feed the registry from claude code hooks`.

### Task 4: Comandos `orq work …` e fechamento por merge

**Files:** Modify `Sources/OrqDaemonKit/WorkCommands.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqDaemonKit/FloorManager.swift` (gancho pós-land), `Sources/OrqDaemonKit/MemoryCommands.swift` (texto de orientação); Test `WorkCommandTests.swift`

**Interfaces:**
- Comandos (terminal = o próprio trabalho; Maestro = também os dos terminais que alcança, com `--terminal <nome>`; app = qualquer, com `--terminal`):
  - `work.start <título> [--branch <b>]` → `{id}`; `--branch` registra o branch do trabalho (um terminal num andar usa o branch do andar por padrão).
  - `work.done [--reason]`, `work.reopen [--id]`.
  - `work.task.add <título>`, `work.task.done <id|título>`, `work.task.defer <id|título> <motivo>`, `work.task.drop <id|título> <motivo>` (motivo obrigatório em defer/drop).
  - `work.note <texto> [--decision]`.
  - `work.status [--terminal] [--all]` → o trabalho ativo (ou todos os visíveis) com tarefas por estado, jobs e notas recentes; `work.list [--closed]`; `work.get <id>`.
  - `work.clear-history` (só app).
- Fechamento por merge (spec §4.4): depois de um `floor.land` bem-sucedido, fecha (`closedBy: "merge"`) o trabalho ativo cujo `branch` é o do andar; além disso, quando um terminal sinaliza `Stop`, o daemon verifica (fora do pool, `GitRunner`) se o `branch` do trabalho ativo desse terminal já é ancestral do branch de destino (`git merge-base --is-ancestor <branch> <destino>`, destino = branch base do andar ou o branch atual do térreo) e fecha se for. Trabalho **sem** `branch` nunca fecha sozinho. Commits: no mesmo `Stop`, acrescenta `git log --format='%h %s' <último visto>..HEAD` do repositório do terminal (≤ 20 por vez).
- Orientação aos agentes: o texto do `memory.hookContext` (início de sessão) ganha um parágrafo curto: "Ao adiar uma tarefa use `orq work task defer <tarefa> \"<motivo>\"`; ao desistir, `orq work task drop …`; ao terminar o trabalho, `orq work done`."
- [ ] **Step 1: Testes:** `commandsFollowCords` (terminal sem corda não vê nem altera o trabalho de outro; Maestro com corda altera; app altera tudo); `deferAndDropNeedReason`; `landClosesFloorWork` (andar real num repositório temporário, como os testes de andar da v1 → trabalho com o branch do andar fecha com `closedBy: merge`); `ancestorCheckClosesOnStop` (branch mergeado à mão no térreo + `turn.completed` → fecha); `groundWorkNeverAutoCloses`; `commitsTracked`; `sessionContextMentionsWorkCommands`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "WorkCommandTests|FloorCommandTests|MemoryHookTests"`). **Step 5:** Commit `feat(work): orq work commands and merge-close`.

### Task 5: Exportar / importar os dados do Orq (backup)

Pedido do usuário em 2026-10-24: designs, design systems e artifacts só existem em `~/Library/Application Support/Orq/`; um arquivo único para backup ou para levar a outra máquina.

**Files:** Create `Sources/OrqDaemonKit/DataBackup.swift`, `Tests/OrqDaemonKitTests/DataBackupTests.swift`; Modify `Sources/OrqProtocol/Commands.swift`, `Sources/OrqDaemonKit/{CommandRouter,Design/FigcraftServer}.swift`, `Sources/OrqApp/OrqApp.swift` (menu), README

**Interfaces:**
- `admin.data.export {out: <caminho .orqbackup>}` e `admin.data.import {from: <caminho>}` — **só o app** (prefixo `admin.`: token de admin, recusado de terminais gerenciados). Menu do app: **Arquivo ▸ Exportar dados do Orq…** / **Importar dados do Orq…** (painéis de salvar/abrir do sistema).
- Conteúdo (formato: zip via `/usr/bin/ditto -c -k --norsrc --keepParent`; extensão `.orqbackup`; um `manifest.json` na raiz com `{format: 1, createdAt, orqVersion, parts: […]}`): `design/` inteiro (servidor do figcraft, registros, design systems, exports), `artifacts/` (incluindo `.removed/`), `memory/` (memória global), `workspaces/`, `work.json` + `work-archive.jsonl` do registro de trabalho. **Fora:** `run/`, `hooks/`, `cache/`, `usage/`, `admin.token`, `default-workspace` (máquina-específicos). A memória de cada repositório (`<repo>/.orq/memory`) fica no repo e não entra.
- Consistência: o export para o servidor do figcraft (`FigcraftServer.stop()`), copia, e o reinicia (os painéis Design reconectam como já fazem depois de queda); avisa o app antes ("Os painéis Design vão reconectar").
- O arquivo contém os **links secretos** dos arquivos de design: gravado 0600, e o diálogo avisa "guarde como guardaria uma senha". Nunca acessível a agentes.
- Import: valida `manifest.json` (`format == 1`) e que todo caminho do zip fica dentro das partes listadas (sem `..`, sem absolutos, sem symlinks — extrair para uma pasta temporária e conferir antes de mover). Para o servidor do figcraft, **move os dados atuais** para `<root>/.replaced-<epochMs>/` (nada é apagado), coloca os do backup, reinicia o servidor, recarrega registros (design, sistemas, artifacts, workspaces, trabalho). Confirmação no app com o resumo do que entra (n arquivos de design, n design systems, n artifacts).
- [ ] **Step 1: Testes:** `exportHasExpectedParts` (raiz temporária com cada parte + `admin.token` → zip com as partes e sem o token; `manifest.json` correto; 0600); `exportPausesServer` (fake server: parado durante a cópia, de pé depois); `importReplacesAndKeepsOld` (raiz com dados A, backup com B → raiz com B, A em `.replaced-*`); `importRefusesBadArchives` (manifesto ausente/formato 2, caminho `../x`, symlink → `.invalidArgs`, raiz intacta); `terminalsCannotBackup` (terminal → `.unauthorized`).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter DataBackupTests`). **Step 5:** Commit `feat(data): export and import Orq data`.

### Task 6: Docs e verificação

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`; Create (scratchpad) `plan3a-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde.
- [ ] **Step 2:** README: seções "Registro de trabalho" e "Backup dos dados" (o que entra, comandos, fechamento, limites, Codex/shell só por comando). Roteiro: 3A "em execução". Checklist humana (abrir um Claude no Orq, pedir uma tarefa com lista; `orq work status` mostra; matar o terminal → jobs `sumiu`; land de um andar fecha o trabalho; reabrir; exportar os dados, importar numa raiz limpa e ver designs/artifacts de volta).
- [ ] **Step 3:** Commit `docs: work registry`.
