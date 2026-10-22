# Plano 3B — Painel Trabalho + chat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um painel de doca **"Trabalho"** por workspace mostra os trabalhos do registro (3A) com tarefas, subagentes e shells; tem uma conversa que responde perguntas de status **pelo registro, sem tokens**, manda mensagens a agentes (`@terminal` ou o Maestro do trabalho), mostra pedidos de permissão com aprovar/negar (só envia se o mesmo pedido ainda está na tela) e oferece **"Recolocar no trilho"**.

**Architecture:** Toda a lógica fica no daemon, em comandos `work.chat.*`, `work.approval*`, `work.rerail` — o painel é só um cliente, como um celular será depois (spec §2, não-metas). Perguntas de status: casador puro (`StatusQuestion`) + texto montado do `WorkStore` (`WorkStatusText`). Mensagens a agentes: `AskCoordinator` com um "ask do usuário" que não entra no grafo de impasse, rodando em segundo plano; a resposta entra no histórico do chat (`ChatLog`, JSONL por workspace). Aprovações: o `StreamHub` guarda o texto do pedido quando o detector de atenção dispara; aprovar confere o texto de novo antes de escrever no PTY. Eventos chegam ao painel pelo caminho de eventos de plug-in que o 2E liga.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI (NSHostingView, como `MemoryPanel`/`ArtifactsPanel`); nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-24-phase3-design.md` §5 (Chat de status), §4.5 (Recolocar no trilho), §4.6 (quem pode o quê), §2 (celular depois: mesmo protocolo), §8. Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`. Base: `main` depois do merge do **3A** (usa `WorkStore`, `Work`, `work.*`) e do **2E** (usa `DaemonClient.pluginEventHandler`, `PluginPanelView.receive(event:payload:)`, refresh agrupado de 500 ms).

## Global Constraints

- **Corda é a única permissão:** chat, aprovações e histórico são do **app** (admin); `work.rerail` também do Maestro para os terminais que alcança por corda (spec §4.5/§4.6). Nada novo para terminais comuns.
- **Nenhum token gasto** pelo Orq: perguntas de status reconhecidas são respondidas pelo registro; só texto que vai a um agente gasta o plano dele, e só porque o usuário mandou.
- **Injeção só por ação** do usuário (ou do Maestro, no `work.rerail`), nunca automática.
- **Aprovação nunca às cegas:** só escreve no terminal se o pedido capturado ainda está na tela; senão nada é enviado e o chat diz "pedido não está mais pendente" (spec §5).
- **Nada é apagado sem o usuário:** o chat rola para `work-chat-archive.jsonl` (só acréscimo); "limpar conversa" é ação do app.
- Protocolo `v: 1`, só comandos/eventos **novos**; nada de I/O bloqueante no pool cooperativo; UI na main thread só para desenhar; textos de UI e do chat em **português**.
- Preparar o celular: o painel não tem lógica que um cliente remoto não teria — ele só chama `work.*` e escuta eventos.

## Review Focus

1. **Aprovar depois que o usuário já respondeu no terminal** (ou o agente trocou de pedido) → nada é escrito no PTY; resposta `{sent: false, reason: "pedido não está mais pendente"}`. Teste: Task 3 `approveStaleSendsNothing`.
2. **Mensagem normal com palavra de status** ("onde estamos com o cache? troca o TTL para 5 min") → vai ao agente, não vira resposta de status. Teste: Task 1 `longMessagesAreNotStatus`.
3. **Agente demora ou não está rodando** → `work.chat.send` volta na hora (`{queued: true}`), a resposta chega depois como mensagem; terminal parado → mensagem de sistema "‹nome› não está rodando", sem fila. Teste: Task 2 `sendReturnsBeforeReply`, `stoppedTargetIsSystemMessage`.
4. **`@nome` inexistente, ou sem `@` e sem trabalho selecionado** → mensagem de sistema explicando, nada enviado. Teste: Task 2 `routingRules`.
5. **Conversa longa** (5 000 mensagens) → `work-chat.jsonl` fica com as 1 000 mais recentes, o resto no arquivo morto; `work.chat.history` pagina. Teste: Task 2 `chatLogCapped`.

---

## File Structure

```
Sources/OrqCore/WorkChat.swift                    ChatMessage, Approval, StatusQuestion (puro; compartilhado com o app/celular)
Sources/OrqDaemonKit/Work/WorkStatusText.swift    [Work] + badges → texto de status em português (puro)
Sources/OrqDaemonKit/Work/ChatLog.swift           actor: JSONL por workspace, limite, arquivo morto
Sources/OrqDaemonKit/WorkChatCommands.swift       work.chat.*, work.approval*, work.rerail
Sources/OrqDaemonKit/{AskCoordinator,StreamHub,AttentionDetector,CommandRouter}.swift
Sources/OrqProtocol/{Commands,Plugins}.swift      (+ comandos, + PluginSpec "work")
Sources/OrqPlugins/WorkPanel.swift                WorkPanelModel + views SwiftUI
Sources/OrqApp/OrqApp.swift                       PluginViews.register("work", WorkPanel.self)
Tests/OrqDaemonKitTests/{WorkStatusTextTests,ChatLogTests,WorkChatCommandTests,ApprovalTests}.swift
Tests/OrqPluginsTests/WorkPanelTests.swift
README.md
```

---

### Task 1: Perguntas de status sem tokens

**Files:** Create `Sources/OrqCore/WorkChat.swift`, `Sources/OrqDaemonKit/Work/WorkStatusText.swift`, `Tests/OrqDaemonKitTests/WorkStatusTextTests.swift`

**Interfaces:**
- Consumes (3A): `Work`, `WorkTask`, `TaskState`, `WorkJob`, `JobState`.
- Produces (OrqCore, `Codable, Sendable, Equatable`):
  - `enum StatusQuestion: String { case whereAreWe, whatIsStuck, whatIsRunning }` com `static func match(_ text: String) -> StatusQuestion?`.
  - Regra do `match`: normaliza (minúsculas, sem acentos, sem pontuação final, espaços colapsados); só casa se o texto normalizado tem **≤ 40 caracteres** e **começa** com uma das frases: `whereAreWe` ← "onde estamos", "status", "como esta", "como estamos"; `whatIsStuck` ← "o que travou", "o que esta travado", "travou", "o que falta"; `whatIsRunning` ← "o que esta rodando", "o que roda", "rodando". (Os botões do painel mandam exatamente a primeira frase de cada.)
- Produces (OrqDaemonKit): `enum WorkStatusText { static func answer(_ q: StatusQuestion, works: [Work], names: [UUID: String], badges: [UUID: StatusBadge], now: Date) -> String }`.
  - `whereAreWe`: por trabalho ativo (`works` já filtrado pelo chamador): `**<título>** — <terminal> (<andar ou "térreo">)`, contagem por estado (`3 feitas · 1 em andamento · 2 abertas · 1 para depois`), a tarefa em andamento, jobs rodando (n). Sem trabalhos: "Nenhum trabalho ativo."
  - `whatIsStuck`: terminais com badge `attention` ("esperando você: <motivo>"), jobs `gone` ("sumiu") e `unknown` ("sem sinal há <n> min"), tarefas `inProgress` sem mudança há ≥ 30 min. Nada: "Nada travado."
  - `whatIsRunning`: jobs `running` com tipo, rótulo, terminal e há quanto tempo; terminais com badge `working`. Nada: "Nada rodando agora."
  - Saída em markdown simples (negrito e listas `- `), ≤ 4 000 caracteres (corta com "… e mais <n>").
- [ ] **Step 1: Testes:** `matchesShortQuestions` ("Onde estamos?", "o que travou", "O QUE ESTÁ RODANDO?" → os três casos); `longMessagesAreNotStatus` ("onde estamos com o cache? troca o TTL para 5 min" → nil; "rodar os testes" → nil); `whereAreWeCountsStates` (trabalho com 3 done, 1 inProgress, 2 open, 1 deferred → as contagens e o título da tarefa em andamento no texto); `stuckListsGoneUnknownAttention` (um job `gone`, um `unknown` com 45 min, um terminal em `attention` → três linhas); `emptyAnswers` (sem trabalhos → as três frases de "nada"); `answerIsBounded` (300 jobs → ≤ 4 000 chars e termina com "… e mais").
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkStatusTextTests`). **Step 5:** Commit `feat(work): answer status questions from the registry`.

### Task 2: Conversa — histórico, roteamento e mensagens a agentes

**Files:** Create `Sources/OrqDaemonKit/Work/ChatLog.swift`, `Sources/OrqDaemonKit/WorkChatCommands.swift`, `Tests/OrqDaemonKitTests/{ChatLogTests,WorkChatCommandTests}.swift`; Modify `Sources/OrqCore/WorkChat.swift`, `Sources/OrqDaemonKit/{AskCoordinator,CommandRouter,Daemon}.swift`, `Sources/OrqDaemonKit/Work/WorkStore.swift` (`onChange`), `Sources/OrqProtocol/Commands.swift`

**Interfaces:**
- Produces (OrqCore): `enum ChatRole: String { case user, agent, orq /* respostas de status e avisos */ }`; `struct ChatMessage { var id: UUID; var at: Date; var role: ChatRole; var workId: UUID?; var terminal: String? /* nome do agente, para user→agente e agente→user */; var text: String /* ≤ 8 000 chars */; var truncated: Bool; var replyTo: UUID? }`.
- Produces (OrqDaemonKit): `actor ChatLog { init(dir: URL); func append(_ m: ChatMessage) throws; func page(before: UUID?, limit: Int) -> [ChatMessage] /* mais recentes primeiro */; func clear() throws }` — `<dir>/work-chat.jsonl` (0600, mesmo dir do `work.json`, escrita fora do pool), mantém as **1 000** mais recentes; ao passar de 1 200, as mais antigas vão para `work-chat-archive.jsonl` (só acréscimo). `clear()` move o arquivo atual inteiro para o arquivo morto.
- Produces: `AskCoordinator.askAsUser(to: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult` — mesma fila/portão de prontidão que `ask`, sem aresta no grafo de impasse (como `inject`, `from == to`), resposta pelo hook/ociosidade como hoje.
- Comandos novos (todos `exposedToMCP: false`, **só app** — token de admin; terminal → `.unauthorized`):
  - `work.chat.send {text, work?: UUID}` → `{messageId, queued: Bool}`. Grava a mensagem `user` e decide, nesta ordem:
    1. `StatusQuestion.match(text)` → mensagem `orq` com `WorkStatusText.answer` (trabalho dado → só ele; sem trabalho → todos os ativos). `queued: false`.
    2. Começa com `@<nome>` (nome de terminal, sem diferenciar maiúsculas) → o resto do texto vai a esse terminal. Nome desconhecido → mensagem `orq` "Não conheço ‹nome›." e nada enviado.
    3. Sem `@`, com `work` → destino = terminal do trabalho se ele for Maestro; senão o primeiro Maestro (ordem alfabética de nome) ligado por corda a ele; senão o próprio terminal do trabalho.
    4. Sem `@` e sem `work` → mensagem `orq` "Escolha um trabalho ou comece com @nome." e nada enviado.
    - Destino parado → mensagem `orq` "‹nome› não está rodando." (`queued: false`). Destino rodando → `queued: true`, responde **antes** da resposta do agente; uma `Task` faz `askAsUser` (timeout 1 800 s) e grava a resposta como `agent` (`replyTo` = a mensagem do usuário, `terminal` = nome, texto cortado em 8 000 com `truncated`); falha/timeout → mensagem `orq` "‹nome› não respondeu (‹motivo›)."
  - `work.chat.history {before?: UUID, limit?: Int /* 1–200, padrão 50 */}` → `[ChatMessage]`.
  - `work.chat.clear` → `{}`.
- Eventos de plug-in aos painéis `work` (mesmo caminho do `designsystem.changed` do 2E): `work.chat {message}` a cada mensagem gravada; `work.changed {workId}` a cada mudança no `WorkStore` (o 3A ganha um `onChange: (@Sendable (UUID) -> Void)?` no `WorkStore`, chamado depois de persistir).
- [ ] **Step 1: Testes:** `ChatLogTests`: `appendAndPage` (ordem, `before`, `limit`), `chatLogCapped` (5 000 mensagens → 1 000 em `work-chat.jsonl`, 4 000 no arquivo morto; nenhuma perdida), `clearArchives`. `WorkChatCommandTests` (daemon em processo, terminais `sh` fazendo eco de resposta + `turn.completed`, como os testes de ask da v1): `statusQuestionAnsweredWithoutAgent` (nenhum byte escrito em PTY algum); `routingRules` (`@Dev` → Dev; sem `@` com trabalho de terminal comum ligado a um Maestro → o Maestro; sem `@` e sem trabalho → aviso; `@ninguem` → aviso; nada escrito nos casos de aviso); `sendReturnsBeforeReply` (agente que responde em 2 s → `send` volta em < 500 ms com `queued: true`; depois chega `agent` com `replyTo` certo e evento `work.chat`); `stoppedTargetIsSystemMessage`; `terminalsCannotChat` (credencial de terminal → `.unauthorized` nos três comandos); `storeChangeEmitsEvent`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "ChatLogTests|WorkChatCommandTests"`). **Step 5:** Commit `feat(work): chat with status answers and agent routing`.

### Task 3: Aprovações com checagem de pendência

**Files:** Create `Tests/OrqDaemonKitTests/ApprovalTests.swift`; Modify `Sources/OrqCore/WorkChat.swift`, `Sources/OrqDaemonKit/{AttentionDetector,StreamHub,WorkChatCommands}.swift`, `Sources/OrqProtocol/Commands.swift`

**Interfaces:**
- `AttentionDetector`: padrões do Claude ganham os pedidos de permissão do Claude Code: `"do you want to proceed?"`, `"do you want to make this edit"`, `"do you want to create"`. O builder confere os textos na versão instalada sem rodar o agente (`strings "$(which claude)"`/o bundle JS do pacote, procurando essas frases) e anota no relatório o que encontrou; o que não existir sai da lista.
- Produces (OrqCore): `enum ApprovalKind: String { case yesNo /* (y/n), [y/n] */, menu /* pedidos do Claude Code */, enter /* press enter */ }`; `struct Approval { var id: UUID; var terminalId: UUID; var terminal: String; var kind: ApprovalKind; var reason: String; var prompt: String /* texto capturado */; var at: Date }`.
- `StreamHub`: quando `attention(id, why)` emite, guarda `pending[id] = Approval` com `prompt` = últimas **15 linhas não vazias** do scrollback sem ANSI (o `ScrollbackBuffer` + `ANSI` da v1), e o `kind` pelo motivo; `inputReceived(id)` e saída do terminal apagam o pendente. Também grava no chat uma mensagem `orq` "‹terminal› pede permissão: ‹última linha do prompt›" e emite `work.approval {approval}` aos painéis `work`.
- Comandos (só app): `work.approvals` → `[Approval]` pendentes; `work.approve {id: UUID, allow: Bool}` → `{sent: Bool, reason?: String}`.
  - Envia só se: o `Approval` com esse `id` ainda é o pendente do terminal **e** as 15 linhas capturadas aparecem, como bloco contíguo, nas últimas 40 linhas não vazias do scrollback atual. Senão `{sent: false, reason: "pedido não está mais pendente"}`, nada escrito, pendente descartado.
  - Teclas: `yesNo` → `"y\r"` / `"n\r"`; `menu` → `"\r"` (primeira opção, "Yes", é a padrão) / `"\u{1B}"` (Esc = "No"); `enter` → `"\r"` / nada (`allow: false` só descarta). Escrita direta no PTY (como a entrada do `ui.attach`), depois apaga o pendente e grava no chat "Aprovado"/"Negado" (`orq`).
- [ ] **Step 1: Testes** (terminal `sh` que imprime um prompt e lê uma linha): `attentionCapturesPrompt` (`printf 'Apagar tudo? (y/n) '` → `work.approvals` tem 1 com `kind: yesNo` e o texto); `approveWritesKeys` (`allow: true` → o script recebe `y`; `false` → `n`); `approveStaleSendsNothing` (usuário digita no terminal antes → `sent: false`; e: o script imprime outro prompt diferente depois da captura → `sent: false`, nada escrito); `menuKeys` (fake com `Do you want to proceed?` → `\r` e `\u{1B}`); `approvalPostsToChat` (mensagem `orq` + evento `work.approval`); `terminalsCannotApprove`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter ApprovalTests`). **Step 5:** Commit `feat(work): approve agent prompts from the chat`.

### Task 4: "Recolocar no trilho"

**Files:** Modify `Sources/OrqDaemonKit/WorkChatCommands.swift`, `Sources/OrqProtocol/Commands.swift`; Test `Tests/OrqDaemonKitTests/WorkChatCommandTests.swift`

**Interfaces:**
- Produces: `enum RerailText { static func block(_ w: Work, now: Date) -> String }` (puro) e o comando `work.rerail {terminal?: String}` → `{injected: Bool, chars: Int}`: app (qualquer terminal, `terminal` obrigatório) ou Maestro (`terminal` alcançado por corda; sem `terminal` = ele mesmo); terminal comum → `.unauthorized`. CLI: `orq work rerail [--terminal <nome>]` (exposto ao MCP só para Maestros, `maestroOnly: true`).
- Texto (≤ 2 000 caracteres, português, sem quebra de linha final extra):
  ```
  [Orq] Estado atual do trabalho "<título>" — considere encerrado tudo o que não está aqui.
  Em andamento: <tarefas inProgress, uma por linha "- ">
  Abertas: <tarefas open>
  Rodando: <jobs running: "- <subagente|shell> <rótulo>">
  Decisões recentes: <até 5 notas decision mais recentes>
  Continue a partir daqui. Ao adiar use `orq work task defer`, ao desistir `orq work task drop`.
  ```
  Seções vazias saem. Sem trabalho ativo no terminal → `.invalidArgs` "no active work".
- Injeção: `AskCoordinator.inject(to:prompt:)` (mesma fila e portão de prontidão; nunca no meio de um ask). Grava no chat `orq` "Recoloquei ‹terminal› no trilho." com o bloco.
- [ ] **Step 1: Testes:** `rerailBlockHasOnlyLiveState` (trabalho com done/open/inProgress/abandoned/deferred + jobs running/finished/gone → só open, inProgress e running aparecem; done/abandoned/finished não); `rerailBlockIsBounded` (500 tarefas abertas → ≤ 2 000 chars); `rerailFollowsCords` (Maestro com corda → injeta; Maestro sem corda → `.unauthorized`; terminal comum → `.unauthorized`; app → injeta); `rerailInjectsIntoPTY` (o `sh` recebe a primeira linha do bloco); `rerailWithoutWork`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkChatCommandTests`). **Step 5:** Commit `feat(work): put an agent back on track`.

### Task 5: Painel "Trabalho"

**Files:** Create `Sources/OrqPlugins/WorkPanel.swift`, `Tests/OrqPluginsTests/WorkPanelTests.swift`; Modify `Sources/OrqProtocol/Plugins.swift`, `Sources/OrqApp/OrqApp.swift`

**Interfaces:**
- Produces: `PluginRegistry.work = PluginSpec(id: "work", title: "Trabalho", placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight, commands: [], events: ["work.changed", "work.chat", "work.approval"])` (incluído em `PluginRegistry.all`); agentes usam `orq work …`, o painel chama `work.*` direto (como `memory`). Um painel por workspace: abrir um segundo `work` no mesmo workspace foca o existente (o app confere antes de `panel.open`).
- Produces: `@MainActor final class WorkPanelModel: ObservableObject { @Published var works: [Work]; @Published var selected: UUID?; @Published var messages: [ChatMessage]; @Published var approvals: [Approval]; func refresh() async; func send(_ text: String) async; func approve(_ id: UUID, allow: Bool) async; func rerail(_ terminal: String) async; func loadOlder() async; func closeWork(_ id: UUID) async; func reopenWork(_ id: UUID) async }` (fechar = `work.done --terminal <terminal do trabalho>`, reabrir = `work.reopen --id`, do 3A) e `final class WorkPanel: PluginPanelView` com `receive(event:payload:)`: `work.changed` → refresh agrupado (o mesmo agrupador de 500 ms do 2E); `work.chat` → acrescenta a mensagem (sem refresh); `work.approval` → recarrega `work.approvals`.
- O resumo (feito / para depois / não feito) e o botão "Resumo" entram no 3C; aqui não há resumo.
- Layout (SwiftUI): em cima, lista de trabalhos ativos (título, terminal/andar, contagens por estado, ícone de alerta se há job `gone`/`unknown` ou terminal em atenção) — clicar seleciona; selecionado expande tarefas por estado e jobs (rodando/sumiu/desconhecido com cor). Menu do trabalho: "Recolocar no trilho", "Fechar", "Reabrir" (fechados num grupo "Fechados" recolhido). Aprovações pendentes como cartões com o texto capturado (monoespaçado, rolável) e botões **Aprovar** / **Negar**. Embaixo, a conversa (mensagens `user` à direita, `agent` com o nome, `orq` em cinza; markdown simples via `AttributedString(markdown:)`), botões rápidos "Onde estamos", "O que travou", "O que está rodando", e o campo de texto (Enter envia; Shift+Enter quebra linha). Rolar para o topo chama `loadOlder()`.
- [ ] **Step 1: Testes** (modelo com `call` falso, como `ArtifactsPanelTests`): `refreshLoadsWorksChatApprovals` (chama `work.list`, `work.chat.history`, `work.approvals`); `chatEventAppendsWithoutRefresh`; `changedEventsCoalesce` (20 `work.changed` em 100 ms → no máximo 2 `work.list`); `quickButtonsSendExactPhrases` (os três botões mandam "onde estamos", "o que travou", "o que está rodando" com o `work` selecionado); `approveCallsDaemon` e mensagem do resultado `sent: false` aparece; `onePanelPerWorkspace`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkPanelTests`). **Step 5:** Commit `feat(work): work panel with chat and approvals`.

### Task 6: Docs e verificação

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`; Create (scratchpad) `plan3b-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem).
- [ ] **Step 2:** README: seção "Painel Trabalho" (o que mostra, perguntas reconhecidas, `@nome`/Maestro, aprovações e a checagem de pendência, "Recolocar no trilho", onde fica o histórico). Roteiro: 3B "em execução".
- [ ] **Step 3:** Checklist humana no scratchpad: abrir o painel; "Onde estamos" com um Claude trabalhando; `@nome` com uma pergunta curta e ver a resposta chegar; um Claude pedindo permissão para um `Bash` → aprovar pelo painel; o mesmo, mas responder no terminal antes e ver "pedido não está mais pendente"; "Recolocar no trilho" num Claude com lista velha; fechar/reabrir trabalho.
- [ ] **Step 4:** Commit `docs: work panel and chat`.
