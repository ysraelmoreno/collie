# M3c.1 Criar e remover faixas em série; esperas dos testes canceláveis

Leia `onda3c.md` e o **achado 1** de `rev-onda3b-report.md`. Código: `Work/WorkLoopLanes.swift` (~86-93, `cut`, `noLane` ~172-185), `Work/LaneWorktree.swift` (`create`, `remove`, `prune`, `sweep`), `Tests/CollieDaemonKitTests/LoopParallelBudgetTests.swift` (~7-19, `Arrivals`) e o mesmo padrão em `LoopParallelTests.swift`.

## Problema
As faixas de uma rodada são criadas em `Task`s paralelas; `git worktree add -b` concorrente falha (`failed to read …/commondir`) e a tarefa é adiada sem culpa. Nos testes, as esperas (`Arrivals.wait`, `Once`) ignoram o cancelamento: uma faixa que nunca chega trava o teste (o `.timeLimit` não o mata). Foi a causa do travamento de 39 min e dos testes instáveis.

## Fazer
1. **Serializar** `LaneWorktree.create`/`remove`/`prune` **por repositório** (um actor ou uma fila interna do laço; chamadas curtas). Complemento: se `create` falhar com `failed to read` + `commondir`, repete **uma vez** e só então devolve o erro.
2. **Testes:** troque as esperas por continuação que **volta no cancelamento** (`withTaskCancellationHandler`, como `Forever` já faz), para o `.timeLimit` virar falha em vez de travamento. Sem `sleep`, sem relógio de parede.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneCreateSerialTests.swift`
Repositório temporário real: 4 `create` disparados juntos nascem **todos** (repita o disparo várias vezes no teste, em laço de 20 rodadas); `create` e `remove` simultâneos não se atropelam; a repetição única acontece com o erro de `commondir` (git falso que falha uma vez); uma espera cancelável volta ao cancelar. `LoopParallelBudgetTests` e `LoopParallelTests` seguem verdes **e** terminam se uma faixa nunca chega (teste que prova que o travamento virou falha).
