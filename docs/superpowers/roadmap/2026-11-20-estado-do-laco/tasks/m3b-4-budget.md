# M3b.4 O `--budget` conta as faixas vivas

Leia `onda3b.md` e o **achado 4** de `rev-onda3-report.md`. Código: `Work/WorkLoopLanes.swift` (~136-139, ~207: o `spent` só cresce ao fim da faixa; timeout do gate do integrador), `Work/WorkLoop.swift` (`left`), `Tests/CollieDaemonKitTests/LoopParallelTests.swift` (~310-330, `theSharedBudgetSpentByOneLaneStopsTheOther`, que hoje **afirma o estouro**).

## Problema
Com `--budget 600 --parallel 4` cada faixa recebe 600 s: o laço gasta até 2400 s. A spec da M3.5 pede que o restante de cada faixa venha do mesmo `spent`.

## Fazer
1. O escalonador guarda o instante de início de cada faixa viva; o orçamento restante visto por uma faixa é `budget − spent − Σ(tempo já corrido de todas as faixas vivas)` (as outras mais a própria, sem contar duas vezes). Use o relógio injetável do host (`host.now()`), nunca relógio de parede nem `sleep`.
2. Quando `spent + Σ vivas ≥ budget`: o laço não inicia faixa nova e as vivas recebem o cancelamento por orçamento (`Stop.Code.budgetSpent`) como no caminho sequencial; o tempo gasto de cada uma é somado ao `spent` uma única vez.
3. Troque a asserção do teste `…StopsTheOther` para provar o contrário (o total não passa do orçamento além da folga de uma fase) **e diga no commit** que o teste antigo afirmava o estouro.
4. Documente em `docs/referencia.md` que o orçamento é a soma do tempo das faixas e que o tempo na fila do integrador conta.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopParallelBudgetTests.swift`
Relógio falso: 4 faixas começam com `spent=0` e `--budget 100`; o relógio avança; a soma dos tempos nunca passa do orçamento mais a folga declarada; uma faixa nova não começa com o orçamento esgotado; `--parallel 1` com `--budget` é idêntico ao de antes (regressão); o tempo da faixa é somado uma vez ao `spent`. `LoopParallelTests` segue verde.
