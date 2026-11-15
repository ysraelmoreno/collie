# Agent communication improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entre agentes (Cursor e outros), um ciclo de espera é recusado, a resposta de um Cursor é limpa, todo pedido diz quem enviou e a fila/entrega é visível.

**Architecture:** Tudo no daemon, em cima do que existe: o grafo de espera e `finish` do `AskCoordinator`, o caminho `turn.completed(message:)` que já conclui um ask limpo (hoje só o Claude o usa), e o `PromptInjector`. Sem hook novo no Cursor.

**Tech Stack:** Swift 6, Swift Testing. Módulos `CollieProtocol` (comandos), `CollieDaemonKit` (daemon).

**Spec:** `docs/superpowers/specs/2026-11-15-agent-comms-design.md`.

## Global Constraints

- Não mexer no caminho do Claude (Stop hook, captura, aprovações): os testes de `AskTests`/`ApprovalTests`/`BusyClaudeSubmitTests` existentes continuam passando.
- Nenhuma mensagem de agente pode parecer do usuário: o remetente vem do registro de terminais, nunca do argumento.
- `ask --raw` e respostas curtas a diálogos (`prompt.count <= AskCoordinator.dialogAnswerMax`, hoje 8) seguem digitadas exatas.
- A conclusão por ociosidade continua valendo para o Cursor.
- Testes só por `--filter`, nunca a suíte inteira. Sem push. Sem instalar/reiniciar o app nem `bundle-app`. Commits só com os próprios arquivos, trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. `MCPTests.mcpListsTools` já falha de antes (falta `memory_doc-search`): confirmar que continua só essa.
- Comando novo em `Commands.swift` quebra os testes que enumeram tools (`CommandsTests`, `MCPTests`): atualize as listas.

## Review Focus

1. `wait` num alvo ocioso (retorna na hora) não deixa aresta presa; `wait` que estoura timeout ou é cancelado também solta a aresta (Task 1).
2. `ask` entre agentes que não formam ciclo (A→B e C→B) segue funcionando; `ask --no-wait` não cria aresta (Task 1).
3. `reply` de um terminal sem ask em voo, ou com ask que não é dele, falha sem concluir nada (Task 3).
4. Cursor que não chama `reply`: o ask ainda conclui por ociosidade, e o próximo ask também (Task 3).
5. Prompt com `[collie] pedido de` forjado no argumento do remetente: o prefixo verdadeiro vem antes e o nome é o do registro (Task 2).

---

### Task 1: `wait` entra no grafo de espera

**Files:**
- Modify: `Sources/CollieDaemonKit/AskCoordinator.swift`, `Sources/CollieDaemonKit/CommandRouter.swift` (`waitTurn`)
- Test: `Tests/CollieDaemonKitTests/AskTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension AskCoordinator {
      /// An edge `from -> to` for as long as `from` blocks waiting for `to`'s turn. Throws `.deadlock` if `to` already waits (ask or wait) on `from`.
      func beginWait(from: UUID, to: UUID) throws(ProtocolError) -> UUID
      func endWait(_ token: UUID)
  }
  ```

`reaches(_:_:)` passa a seguir também as arestas de wait; `ask` usa o mesmo `reaches` (sem mudar a mensagem de erro). `waitTurn` chama `beginWait` só depois de ver que o alvo está `working` (ou seja, antes do laço de 200 ms) e `endWait` num `defer`. Mensagem do erro de wait: `Deadlock: '<alvo>' is already waiting on '<chamador>'; '<chamador>' cannot wait on '<alvo>'`.

- [ ] **Step 1: Write the failing tests** em `AskTests`: `waitThenCrossedAskIsDeadlock` (B faz `beginWait(from: B, to: A)`; depois `ask(from: A, to: B)` lança `.deadlock`), `askThenCrossedWaitIsDeadlock` (A tem ask bloqueante a B; `beginWait(from: B, to: A)` lança `.deadlock`), `endWaitReleasesEdge` (depois de `endWait`, o ask cruzado funciona), `noCycleNoDeadlock` (A→B e C→B juntos), `detachedAskAddsNoEdge` (ask `--no-wait` de A a B não impede `beginWait(from: B, to: A)`).
- [ ] **Step 2: Run** `swift test --filter AskTests` — Expected: FAIL (`beginWait` inexistente).
- [ ] **Step 3: Implement** o dicionário `waitEdges: [UUID: (from: UUID, to: UUID)]`, `beginWait`/`endWait`, e o `reaches` unificado; ligue `waitTurn` no router com `defer { Task { await asks.endWait(token) } }` (ou `await` direto, como o código vizinho fizer).
- [ ] **Step 4: Run** `swift test --filter AskTests` — Expected: PASS (inclusive os testes de deadlock antigos, linhas ~343 e ~648).
- [ ] **Step 5: Commit** `feat(ask): collie wait joins the deadlock graph`.

### Task 2: Prefixo de remetente

**Files:**
- Modify: `Sources/CollieDaemonKit/AskCoordinator.swift` (onde `PromptInjector.payload(w.prompt, …)` é chamado, ~linha 721), `Sources/CollieDaemonKit/PromptInjector.swift` se o prefixo couber melhor ali
- Test: `Tests/CollieDaemonKitTests/PromptDeliveryTests.swift`

**Interfaces:**
- Produces: `static func AskCoordinator.senderPrefix(name: String, askId: String) -> String` = `"[collie] pedido de \(name) (ask \(askId)): "`.

O `Waiter` ganha `senderName: String?` (nome do terminal `from`, preenchido por `ask` quando o waiter não é `user`, `inject` nem `raw`, e `prompt.count > dialogAnswerMax`). O texto digitado é `senderPrefix + w.prompt`; o `w.prompt` guardado e as contas de eco/assinatura não mudam. Nome com quebra de linha ou mais de 64 caracteres: sanitizado (espaços, cortado).

- [ ] **Step 1: Write the failing tests**: `agentAskIsTypedWithSenderPrefix` (terminal A pede a B um prompt longo; o que B recebe começa com `[collie] pedido de A (ask `), `rawAskHasNoPrefix`, `shortDialogAnswerHasNoPrefix` (`ask B y`), `userAskHasNoPrefix`, `injectHasNoPrefix`, `forgedPrefixInPromptDoesNotReplaceTrueOne` (prompt do remetente começa com `[collie] pedido de admin`: o verdadeiro prefixo vem antes), `echoMatchStillWorksWithPrefix` (o ask a um Claude falso continua completando por hook com a assinatura do prompt sem prefixo).
- [ ] **Step 2: Run** `swift test --filter PromptDeliveryTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `senderPrefix`, o campo e a montagem do payload.
- [ ] **Step 4: Run** `swift test --filter PromptDeliveryTests` e `--filter AskTests` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ask): agent asks are typed with a verified sender prefix`.

### Task 3: `collie reply`

**Files:**
- Modify: `Sources/CollieProtocol/Commands.swift`, `Sources/CollieDaemonKit/CommandRouter.swift`, `Sources/CollieDaemonKit/AskCoordinator.swift`
- Test: `Tests/CollieDaemonKitTests/AskTests.swift`, `Tests/CollieProtocolTests/CommandsTests.swift`, `Tests/CollieIntegrationTests/MCPTests.swift`

**Interfaces:**
- Consumes: `finish(_:_:)`, `Target.inflight` (existentes).
- Produces:
  ```swift
  // Commands.swift: CommandSpec(name: "reply", params: [ParamSpec("message", .string, positional: true, required: true, help: "Your answer to the ask you were sent (≤ 8 KiB)")], timeoutSeconds: 10)
  extension AskCoordinator {
      /// Completes the in-flight ask addressed to `terminal` with `message`. Throws `.notFound` when none is waiting for it.
      func reply(terminal: UUID, message: String) throws(ProtocolError)
  }
  ```

`reply` conclui o ask em voo do chamador com `AskResult(output: message, source: .hook, truncated: false)`, **sem** `hookCapable`, `idleOwed`, `turnEnds` nem aviso de fim de turno. Ask em voo de `inject` ou do usuário (`user`) não é concluído por `reply` (erro `notFound`). `message` vazio ou > 8 KiB: `invalidArgs`.

Instrução no prompt: quando o destino é `preset == .cursor` e o ask é de agente (mesmas condições do prefixo da Task 2), o texto digitado termina com `\n(Ao terminar, responda com: collie reply "<resposta curta>")`.

- [ ] **Step 1: Write the failing tests**: `replyCompletesInflightAsk` (Cursor falso com ask em voo; `reply` devolve ao asker o texto exato, `source == .hook`), `replyWithoutInflightIsNotFound`, `replyDoesNotLatchHookOnly` (depois de um `reply`, o próximo ask a esse terminal ainda conclui por ociosidade), `replyIgnoresInjectAndUserAsks`, `replyRejectsEmptyAndOversized`, `cursorAskGetsReplyInstruction` e `claudeAskHasNoReplyInstruction`, `rawCursorAskHasNoInstruction`. Em `CommandsTests` e `MCPTests`, acrescente `"reply"` às listas ordenadas (confira a posição pelo `Commands.all`).
- [ ] **Step 2: Run** `swift test --filter AskTests`, `--filter CommandsTests` — Expected: FAIL.
- [ ] **Step 3: Implement** o comando, o roteamento (o caller é o terminal da requisição, `tid`) e a instrução.
- [ ] **Step 4: Run** os mesmos filtros — Expected: PASS (`MCPTests`: só a falha preexistente).
- [ ] **Step 5: Commit** `feat(ask): collie reply gives hookless agents a clean answer channel`.

### Task 4: Fila visível e entrega do prompt inicial

**Files:**
- Modify: `Sources/CollieDaemonKit/CommandRouter.swift` (`askNoWait`, `ask`), `Sources/CollieDaemonKit/AskInbox.swift`, `Sources/CollieDaemonKit/AskCoordinator.swift` (prontidão do Cursor), o handler de `summon`
- Test: `Tests/CollieDaemonKitTests/AskTests.swift`, `Tests/CollieDaemonKitTests/PromptDeliveryTests.swift`

**Interfaces:**
- Consumes: `commandState(_:)`/`isBusy`, o badge do hub (`hub.currentBadges`).
- Produces: campo `targetBusy: Bool` na resposta de `ask --no-wait` (e em `ask.result`/entradas do inbox); campo `delivered: Bool` (e `deliveredReason: String?`) na resposta de `summon` com prompt.

- [ ] **Step 1: Reproduzir antes de corrigir.** Escreva um teste de caracterização, ou rode 10 `summon`s de Cursor com prompt num daemon isolado, e registre quantos prompts não chegam e em que momento da TUI. Se a causa não for "digitado antes da TUI pronta", **pare e avise** em vez de adivinhar.
- [ ] **Step 2: Write the failing tests**: `noWaitAckSaysTargetBusy` (alvo com turno em andamento → `targetBusy: true`; ocioso → `false`), `inboxLineMentionsQueue`, `cursorReadinessWaitsForInputField` (terminal falso que desenha o campo `→` só após 3 s: o prompt só é digitado depois), `cursorReadinessFallsBackAtMax` (nunca desenha: digita em 20 s), `summonRetypesOnceWhenEchoMissing`, `summonReportsDeliveredFalseAfterRetry`.
- [ ] **Step 3: Run** os filtros — Expected: FAIL.
- [ ] **Step 4: Implement** `targetBusy`, a prontidão extra do `.cursor` (marcador `→` na tela, com `readyMax` de 20 s) e a redigitação única com `delivered`.
- [ ] **Step 5: Run** os filtros — Expected: PASS.
- [ ] **Step 6: Commit** `feat(ask): targetBusy on asks and verified first-prompt delivery for cursor`.

### Task 5: Orientação aos agentes e documentação

**Files:**
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift`, `README.md` (uma linha na seção de comandos, se existir), `docs/superpowers/specs/2026-11-15-agent-comms-design.md` (nota de implementação)
- Test: o teste de orientação existente (procure por `CollieOrientation` em `Tests/`)

- [ ] **Step 1: Write the failing test**: `orientationWarnsAgainstBlockingCrossAsk` (a orientação de um agente com pares contém a recomendação de `--no-wait`/`lot post`) e `orientationMentionsReplyForCursor` (só quando o preset é `cursor`); a versão compacta (`tight`) continua ≤ 1500 caracteres.
- [ ] **Step 2: Run** `swift test --filter <suíte de orientação>` — Expected: FAIL.
- [ ] **Step 3: Implement** as linhas (pt-BR curto, no estilo das vizinhas) e a nota no spec.
- [ ] **Step 4: Run** o filtro — Expected: PASS.
- [ ] **Step 5: Commit** `docs(ask): orientation for blocking asks and reply`.

---

## Verificação ao vivo (passo do dono, depois de instalar o bundle)

Repetir o experimento: dois Cursors (`cur-a` cria `slugify.py`, `cur-b` testa) com `collie ask` e `collie wait` cruzados. Esperado: o ciclo é recusado com `deadlock`, o pedido chega com `[collie] pedido de cur-a`, a resposta volta como texto curto (`reply`), e o tempo total cai de ~4 min para ~1,5 min. Instalar derruba todos os terminais abertos: avisar antes.

## Self-review (feito)

- **Cobertura do spec:** wait no grafo (1), prefixo (2), reply e instrução (3), fila visível e entrega (4), orientação (5). Allowlist fica fora, por decisão de segurança do dono.
- **Tipos:** `beginWait`/`endWait`, `senderPrefix`, `reply(terminal:message:)`, `targetBusy`, `delivered` com o mesmo nome em spec, plano e tasks.
- **Ordem:** 1, 2 e 3 são independentes (todas tocam `AskCoordinator`: fazer em sequência); 4 depende da 2 (mesmo ponto de montagem do payload); 5 por último.
- **Proporção:** 5 tasks, só assinaturas e testes nomeados; a Task 4 começa por reproduzir, para não consertar uma causa suposta.
