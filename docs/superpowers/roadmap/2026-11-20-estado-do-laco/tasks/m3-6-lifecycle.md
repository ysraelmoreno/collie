# M3.6 Ciclo de vida, status e cartão

Leia `onda3-paralelismo.md`. Depende de M3.5. Código: `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`stopLoopsLeftRunning`, `loopEnded`, `loopCardText`, `cancelLoops`), `Sources/CollieDaemonKit/Work/WorkStatusText.swift`, `LaneWorktree.swift`, `Sources/CollieDaemonKit/WorkCommands.swift` (`work status`, `work wait`), `Sources/ColliePlugins/WorkPanel.swift` (só ler campos novos).

## Fazer

1. **Varredura de início do daemon:** `stopLoopsLeftRunning` também remove as faixas dos laços que ficaram `running` (`LaneWorktree.sweep`), reabre as tarefas que corriam em faixas e **limpa** `lanes`; uma faixa órfã nunca fica para trás. A varredura não apaga o que não é faixa (testado em M3.2).
2. `loopEnded` e `cancelLoops` removem as faixas restantes (idempotente).
3. **`work status`:** com faixas ativas, uma linha por faixa (`faixa T3 · agente trabalhando · desde 14:03 (4 min)`) e a contagem `N de M em paralelo`; sem faixas, a saída é a de hoje. `work wait` (Onda 2) acorda com mudança de qualquer faixa (a versão do store já sobe a cada `update`; teste). `--events` mostra o id da faixa.
4. **Cartão de aprovação** (`loopCardText`): mostra `--parallel N` quando maior que 1 e, para cada tarefa, o `scope` e o `needs` entre «…» como já faz com `check`; cabe no limite do cartão (1500 caracteres): se não couber, `nil` como hoje (a regra do cartão não muda). O texto do aviso de início do laço também diz `--parallel`.
5. O painel Trabalho só decodifica os campos novos (opcionais), sem mudar o visual.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopLaneLifecycleTests.swift`

Varredura remove faixas órfãs de um laço `running` deixado por um daemon anterior e reabre as tarefas; `loopEnded` e `cancelLoops` removem as faixas e são idempotentes; `WorkStatusText` com 0, 1 e 2 faixas (formato); o cartão com `--parallel 2`, `scope` e `needs`, e o caso que não cabe; `work wait` acorda por mudança de faixa; `WorkPanelTests` (em `ColliePluginsTests`) decodifica um `loop` com `lanes` e sem.
