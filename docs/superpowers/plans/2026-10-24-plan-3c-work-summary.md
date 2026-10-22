# Plano 3C — Resumo do trabalho — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cada trabalho (ativo ou fechado) tem um resumo **Feito / Para depois / Não feito**, montado do registro sempre (sem IA, instantâneo, sem tokens). No macOS 26 com Apple Intelligence, o modelo on-device reescreve o resumo em linguagem natural e responde perguntas livres no chat, consultando só o registro. Ao fechar um trabalho, o resumo vai para a Memória do repositório como decisão não revisada.

**Architecture:** `WorkSummary` (puro) lê um `Work` e gera seções e markdown; `work.summary` expõe o resumo com as regras de alcance do 3A. Um protocolo `LocalModel` esconde o FoundationModels (`#if canImport` + `@available(macOS 26, *)`), com um falso nos testes; a reescrita e as perguntas livres usam o modelo e caem para o determinístico em falha ou demora. O modelo roda **no daemon**, para o chat (e um celular, depois) ter a mesma resposta. Ao fechar, o `WorkStore.onChange` (3B) dispara a gravação na Memória pelo `saveMemory` da v1.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, FoundationModels (SDK 26, ligado de forma fraca; o pacote continua `.macOS(.v15)`). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-24-phase3-design.md` §7 (Resumo), §3 (modelo local: macOS 26 + Apple Intelligence; nada de rede), §5 (perguntas livres no chat), §2 (anti-metas: resumo falhando; inventar estado; gastar tokens). Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`. Base: `main` depois do merge do **3A** e do **3B** (`StatusQuestion`, `work.chat.send`, `WorkPanelModel`, `WorkStore.onChange`).

## Global Constraints

- **Resumo determinístico é a fonte:** sempre disponível, montado só do registro; o modelo nunca é necessário para ver um resumo (anti-meta "resumo falhando").
- **Nada de rede e nenhum token:** só o modelo on-device; nenhuma chamada a agentes ou serviços.
- O modelo **não inventa estado**: só recebe dados do registro (no prompt ou por ferramentas), e a interface mostra sempre o determinístico ao lado ("Ver dados").
- Prazos: reescrita **10 s**, pergunta livre **20 s**; estourou ou falhou → determinístico (reescrita) ou aviso (pergunta), com o motivo.
- macOS mínimo continua **15**: todo uso de FoundationModels atrás de `#if canImport(FoundationModels)` e `if #available(macOS 26, *)`; o binário roda no 15 sem o framework.
- Memória: entrada `decision`, `reviewed: false`, origem `"Orq (resumo)"`, no repositório do terminal do trabalho; nada sai da máquina.
- Corda é a única permissão: `work.summary` segue as regras de alcance de `work.status` (3A); perguntas livres são do chat (app).

## Review Focus

1. **Modelo indisponível** (macOS 15, Apple Intelligence desligada, modelo ainda baixando) → `work.summary --natural` devolve o determinístico com `natural: false` e o motivo; pergunta livre responde "Perguntas livres precisam do macOS 26 com Apple Intelligence ligada (‹motivo›)." Teste: Task 2 `unavailableFallsBack`, Task 3 `freeQuestionWithoutModel`.
2. **Modelo trava ou demora** → depois de 10 s, determinístico com `reason: "timeout"`; nenhuma fila crescendo (uma reescrita por trabalho de cada vez; pedido repetido espera a mesma). Teste: Task 2 `slowModelTimesOut`, `concurrentRewritesShareOne`.
3. **Trabalho grande** (500 tarefas, 200 jobs, 200 commits) → resumo limitado (≤ 6 000 caracteres, "… e mais ‹n›" por seção) e o prompt do modelo cabe no contexto (o texto entregue ao modelo ≤ 6 000 caracteres). Teste: Task 1 `summaryIsBounded`.
4. **Fechar, reabrir e fechar de novo** → uma única memória ativa por trabalho: a segunda substitui a primeira pela cadeia de `subject` da v1 (sem duplicar). Teste: Task 4 `reclosingSupersedes`.
5. **Trabalho implícito vazio** (aberto por engano, sem tarefas nem commits) fecha → nada vai para a Memória. Teste: Task 4 `emptyWorkNotSaved`.

---

## File Structure

```
Sources/OrqDaemonKit/Work/WorkSummary.swift      Work → seções + markdown (puro)
Sources/OrqDaemonKit/Work/LocalModel.swift       protocolo LocalModel, disponibilidade, FoundationLocalModel (macOS 26)
Sources/OrqDaemonKit/Work/WorkAssistant.swift    reescrita com prazo e fallback; perguntas livres com ferramentas
Sources/OrqDaemonKit/{WorkCommands,WorkChatCommands,MemoryCommands,Daemon}.swift
Sources/OrqCore/WorkChat.swift                   (+ StatusQuestion.summary)
Sources/OrqProtocol/Commands.swift               (+ work.summary, work.assistant.status)
Sources/OrqPlugins/WorkPanel.swift               (seção Resumo, botão "Resumo", "?" para perguntas livres)
Tests/OrqDaemonKitTests/{WorkSummaryTests,WorkAssistantTests,WorkMemoryTests}.swift
Tests/OrqPluginsTests/WorkPanelTests.swift
README.md
```

---

### Task 1: Resumo determinístico

**Files:** Create `Sources/OrqDaemonKit/Work/WorkSummary.swift`, `Tests/OrqDaemonKitTests/WorkSummaryTests.swift`; Modify `Sources/OrqDaemonKit/WorkCommands.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqCore/WorkChat.swift`, `Sources/OrqDaemonKit/WorkChatCommands.swift`, `Sources/OrqPlugins/WorkPanel.swift`; Test `Tests/OrqPluginsTests/WorkPanelTests.swift`

**Interfaces:**
- Consumes (3A): `Work`, `WorkTask`, `TaskState`, `WorkJob`, `JobState`, `WorkNote`; (3B): `StatusQuestion`, `WorkStatusText`, `WorkPanelModel`.
- Produces: `struct WorkSummary: Codable, Sendable, Equatable { var title: String; var active: Bool; var closedBy: String?; var done: [String]; var later: [String]; var notDone: [String]; var stoppedAt: String? }` com `static func make(_ w: Work, terminalAlive: Bool, now: Date) -> WorkSummary` e `func markdown() -> String`.
  - **Feito:** tarefas `done` (título), commits do trabalho (`<sha> <assunto>`), e "Mergeado" quando `closedBy == "merge"`.
  - **Para depois:** tarefas `deferred` ("‹título› — ‹motivo›") e notas `decision` ("Decisão: ‹texto›").
  - **Não feito:** tarefas `open`/`inProgress` (num trabalho ativo a seção se chama "Em aberto"), tarefas `abandoned` ("‹título› — abandonada[: motivo]"), jobs `gone` ("‹rótulo› — sumiu") e `unknown` ("‹rótulo› — sem sinal").
  - **Onde parou:** a tarefa `inProgress` mais recente; senão a última nota; senão nil.
  - `markdown()`: título em `##`, depois `**Feito**`, `**Para depois**`, `**Não feito**`/`**Em aberto**`, `**Onde parou**`, listas `- `; seções vazias saem; cada seção com no máximo 40 itens ("… e mais ‹n›"); total ≤ 6 000 caracteres.
- Produces: comando `work.summary {id?: UUID, terminal?: String, natural?: Bool}` → `{summary: WorkSummary, markdown: String, natural: Bool, text?: String, reason?: String}` (alcance igual a `work.status` do 3A; sem `id`/`terminal` = o trabalho ativo do chamador). `natural` só é usado na Task 2; aqui sempre `natural: false`. CLI `orq work summary [--id] [--terminal] [--natural]`.
- Produces: `StatusQuestion.summary` (← "resumo", "resume", "o que foi feito"); no chat, responde com o `markdown()` do trabalho selecionado (sem trabalho → "Escolha um trabalho para ver o resumo.").
- Painel: botão rápido "Resumo" (manda "resumo"); o trabalho selecionado ganha uma seção recolhível "Resumo" com o markdown (recarregada no refresh agrupado de `work.changed`).
- [ ] **Step 1: Testes:** `sectionsFromStates` (trabalho com done/deferred com motivo/abandoned/open/inProgress + nota decision + jobs gone/unknown/finished + 2 commits → cada item na seção certa; `finished` não aparece); `activeSaysEmAberto` / `closedSaysNaoFeito`; `mergeIsDone` (`closedBy: "merge"` → "Mergeado" em Feito); `stoppedAt` (inProgress mais recente; sem ela, última nota); `summaryIsBounded` (500 tarefas abertas, 200 jobs gone, 200 commits → ≤ 6 000 chars, "… e mais" em cada seção); `summaryCommandFollowsCords` (mesmos casos do `commandsFollowCords` do 3A); `chatSummaryQuestion` ("Resumo" com trabalho → markdown; sem → aviso). Painel: `summaryButtonSendsResumo`, `selectedWorkLoadsSummary`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "WorkSummaryTests|WorkChatCommandTests|WorkPanelTests"`). **Step 5:** Commit `feat(work): deterministic work summary`.

### Task 2: Modelo local e reescrita

**Files:** Create `Sources/OrqDaemonKit/Work/LocalModel.swift`, `Sources/OrqDaemonKit/Work/WorkAssistant.swift`, `Tests/OrqDaemonKitTests/WorkAssistantTests.swift`; Modify `Sources/OrqDaemonKit/{WorkCommands,Daemon}.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqPlugins/WorkPanel.swift`, `Package.swift` (só se o link fraco precisar de `linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])]`; preferir o link automático com `canImport` + `@available`, que já é fraco)

**Interfaces:**
- Produces:
  - `enum LocalModelAvailability: Equatable, Sendable { case available; case unavailable(String) /* motivo em português */ }`.
  - `protocol LocalModel: Sendable { func availability() async -> LocalModelAvailability; func respond(instructions: String, prompt: String, tools: [AssistantTool]) async throws -> String }`.
  - `struct AssistantTool: Sendable { let name: String; let description: String; let run: @Sendable (_ argument: String) async -> String }` (um argumento de texto; o adaptador do FoundationModels transforma cada uma num `Tool` com `@Generable struct Arguments { let query: String }`).
  - `FoundationLocalModel: LocalModel` (só com `#if canImport(FoundationModels)`; métodos internos `@available(macOS 26, *)`): `availability()` lê `SystemLanguageModel.default.availability` e mapeia: `.available` → `.available`; `deviceNotEligible` → "este Mac não suporta Apple Intelligence"; `appleIntelligenceNotEnabled` → "Apple Intelligence está desligada"; `modelNotReady` → "o modelo ainda está sendo baixado"; outro/macOS < 26 → "precisa do macOS 26". `respond` cria uma `LanguageModelSession(tools:instructions:)` **nova por chamada** (sem histórico entre perguntas).
  - `actor WorkAssistant { init(model: any LocalModel, clock: any Clock<Duration> = ContinuousClock()); func rewrite(_ s: WorkSummary, workId: UUID) async -> (text: String?, reason: String?); func status() async -> LocalModelAvailability }` — prazo **10 s**; pedidos simultâneos para o mesmo `workId` aguardam a mesma tarefa; resultado guardado em cache por `(workId, hash do markdown)` (só o último por trabalho).
  - Instruções da reescrita (texto fixo, português): "Reescreva o resumo de trabalho abaixo em português, em até 8 frases curtas, na ordem: o que foi feito, o que ficou para depois, o que não foi feito e onde parou. Use somente os fatos do texto. Não acrescente tarefas, nomes, números ou conclusões que não estejam nele. Se uma seção não existir, não a mencione."; o prompt é o `markdown()` (≤ 6 000 chars).
- `work.summary --natural`: modelo disponível → `{natural: true, text}`; indisponível/erro/prazo → `{natural: false, reason}` e o markdown como sempre.
- `work.assistant.status` (app ou terminal) → `{available: Bool, reason?: String}`.
- Painel: a seção "Resumo" pede `--natural`; com texto natural, mostra-o com o botão "Ver dados" (alterna para o markdown determinístico); sem, mostra o markdown e, se houver `reason`, uma linha cinza "Resumo sem reescrita: ‹motivo›". Teste do painel: `naturalSummaryHasDataToggle`.
- [ ] **Step 1: Testes** (modelo falso que responde, falha, demora ou se diz indisponível; relógio injetável): `rewriteUsesModel` (o prompt recebido é o markdown e as instruções são as fixas); `unavailableFallsBack`; `modelErrorFallsBack`; `slowModelTimesOut` (falso demora 30 s, relógio avança 10 s → `reason: "timeout"`); `concurrentRewritesShareOne` (5 chamadas juntas → 1 chamada ao modelo); `cacheInvalidatesOnChange` (markdown mudou → nova chamada). Teste do modelo real, `.enabled(if:)` só quando `FoundationLocalModel().availability() == .available` (pulado neste Mac, macOS 15.6): reescrita de um resumo fixo volta não vazia em ≤ 10 s.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter WorkAssistantTests`). Conferir que `swift build` continua produzindo binários que abrem no macOS 15 (`otool -L .build/debug/orqd` mostra FoundationModels como `weak` ou ausente). **Step 5:** Commit `feat(work): rewrite summaries with the on-device model`.

### Task 3: Perguntas livres no chat

**Files:** Modify `Sources/OrqDaemonKit/{WorkAssistant,WorkChatCommands}.swift`, `Sources/OrqPlugins/WorkPanel.swift`; Test `Tests/OrqDaemonKitTests/WorkAssistantTests.swift`, `Tests/OrqDaemonKitTests/WorkChatCommandTests.swift`, `Tests/OrqPluginsTests/WorkPanelTests.swift`

**Interfaces:**
- Roteamento no `work.chat.send` (3B), antes do `@nome`: texto que começa com **`?`** é pergunta ao assistente local (o resto, sem o `?`). Sem `?`, nada muda: status reconhecido → registro; o resto → agente. (Assim uma pergunta nunca vai ao agente sem o usuário querer, e uma mensagem ao agente nunca é engolida pelo modelo.)
- Produces: `WorkAssistant.answer(question: String, selected: UUID?) async -> (text: String?, reason: String?)` — prazo **20 s**, uma pergunta por vez (as outras esperam na fila do actor, no máximo 3 na fila; além disso, "O assistente está ocupado, tente de novo em instantes."). Ferramentas (todas leem só o `WorkStore`, saídas ≤ 2 000 chars):
  - `listarTrabalhos(filtro)` → ativos + 20 fechados mais recentes: `id · título · terminal · ativo/fechado em ‹data›`, filtrados por texto se `filtro` não estiver vazio.
  - `resumoDoTrabalho(id ou título)` → o `markdown()` desse trabalho.
  - `statusAgora(pergunta)` → o `WorkStatusText.answer` de `whereAreWe`, `whatIsStuck` e `whatIsRunning` juntos.
- Instruções da pergunta (fixas, português): "Você responde perguntas sobre o trabalho dos agentes no Orq. Use as ferramentas para consultar o registro; responda só com o que elas devolverem, em português, em poucas frases. Se o registro não tiver a resposta, diga que não sabe." O trabalho selecionado no painel (se houver) entra no prompt como "Trabalho selecionado: ‹id› ‹título›".
- Chat: grava a resposta como `orq` com prefixo "Assistente: "; sem modelo → `orq` "Perguntas livres precisam do macOS 26 com Apple Intelligence ligada (‹motivo›)."; prazo/erro → `orq` "O assistente não respondeu (‹motivo›)." `work.chat.send` volta antes da resposta (`queued: true`), como para agentes.
- Painel: placeholder do campo "Mensagem — @nome para um agente, ? para perguntar ao assistente"; quando `work.assistant.status` diz indisponível, o placeholder troca o fim por "(assistente indisponível: ‹motivo›)".
- [ ] **Step 1: Testes:** `questionMarkGoesToAssistant` (nenhum byte em PTY; falso recebe a pergunta sem o `?`); `toolsReadOnlyRegistry` (falso chama as três ferramentas → saídas batem com `WorkStore`/`WorkSummary`/`WorkStatusText`; ≤ 2 000 chars); `freeQuestionWithoutModel`; `freeQuestionTimesOut` (20 s); `assistantQueueBounded` (5 perguntas com o falso lento → 1 rodando, 3 na fila, a 5ª recebe "ocupado"); `plainTextStillGoesToAgent` (sem `?`, com modelo disponível → vai ao agente). Painel: `placeholderShowsAvailability`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "WorkAssistantTests|WorkChatCommandTests|WorkPanelTests"`). **Step 5:** Commit `feat(work): free questions to the on-device assistant`.

### Task 4: Resumo vai para a Memória ao fechar

**Files:** Modify `Sources/OrqDaemonKit/{WorkCommands,MemoryCommands,Daemon}.swift`; Create `Tests/OrqDaemonKitTests/WorkMemoryTests.swift`

**Interfaces:**
- Consumes: `WorkStore.onChange` (3B); `saveMemory(_:scope:subject:title:body:path:repo:floor:origin:)` da v1 (`MemoryCommands`).
- Quando um trabalho passa de ativo para fechado (qualquer `closedBy`), o daemon, fora do pool: monta `WorkSummary.make(...).markdown()` (determinístico — nunca espera o modelo) e chama `saveMemory(.decision, scope: floor != nil ? .floor : .project, subject: "trabalho \(work.id.uuidString.prefix(8).lowercased())", title: "Resumo: \(work.title)", body: markdown, path: nil, repo: <repo do cwd do terminal do trabalho>, floor: <nome do andar>, origin: "Orq (resumo)")`. O `subject` fixo por trabalho faz o fechar-de-novo substituir a anterior (cadeia de substituição da v1). Entra como **não revisada** (aparece no painel Memória para aprovar/descartar).
- Não grava quando o trabalho não tem tarefas, notas nem commits; nem quando o terminal não tem repositório (sem `.git` no cwd → log, nada mais). Falha ao gravar → log e aviso no chat (`orq` "Não consegui guardar o resumo de ‹título› na Memória."); o fechamento não é desfeito.
- [ ] **Step 1: Testes** (repositório temporário, como os testes de memória da v1): `closingSavesSummary` (fechar por `work.done` → `memory.list` do repo tem uma `decision` não revisada com título "Resumo: ‹título›", origem "Orq (resumo)" e o markdown); `mergeCloseSavesToo` (`floor.land` → escopo `floor`, nome do andar); `reclosingSupersedes` (fechar → reabrir → nova tarefa → fechar → uma ativa, a anterior `superseded`); `emptyWorkNotSaved`; `noRepoNoSave`; `saveFailureWarnsInChat`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "WorkMemoryTests|MemoryCommandTests"`). **Step 5:** Commit `feat(work): keep closed work summaries in memory`.

### Task 5: Docs e verificação

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`; Create (scratchpad) `plan3c-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem e que o teste do modelo real foi pulado por macOS 15.6).
- [ ] **Step 2:** README: seção "Resumo do trabalho" (seções, `orq work summary`, `--natural`, `?` no chat, requisitos do modelo local, o que vai para a Memória). Roteiro: 3C "em execução".
- [ ] **Step 3:** Checklist humana no scratchpad, em duas partes: **macOS 15** (resumo e botão "Resumo"; `?` mostra o aviso de indisponível; fechar um trabalho cria a memória não revisada; reabrir/fechar substitui) e **macOS 26 com Apple Intelligence** (reescrita aparece com "Ver dados"; `? o que ficou para depois no trabalho X` responde com dados do registro; desligar Apple Intelligence → volta o aviso, sem travar).
- [ ] **Step 4:** Commit `docs: work summary`.
