# M1.3 Decisão da tentativa pura

Leia primeiro o `README.md` desta pasta. Depende de M1.1 e M1.2. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift`, em especial o trecho de `attempt()` depois do turno do agente (de `var reason: String, output = ""` até o fim da função) e `verdict(...)`.

## Fazer

1. Novo `Sources/CollieDaemonKit/Work/AttemptDecision.swift`: um tipo `AttemptDecision` com `struct Facts` e uma função **pura** `decide(_ f: Facts) -> Outcome`, sem `host`, `store`, git nem relógio.
   - `Facts`: tudo o que a decisão lê hoje, já medido: `failure: String?` (summon/ask falhou antes do check), `broken: String?` (o check não pôde rodar), `checkStatus: Int32?` (nil = timeout), `gate: String?` (o resultado do portão: nil se passou, não rodou ou não há), `committed`, `dirty`, `moves: [String]` (o check ou o portão moveram o HEAD), `blockedBy: String?` (outro terminal trabalhando), `attempt n`, `tries`, `hasGate`.
   - `Outcome`: `.pass`; `.retry(reason:, discard: Bool)`; `.defer(reason:, discard: Bool)` (a última tentativa; nunca com `blockedBy`); `.stopLoop(Stop, reason:)` quando `blockedBy != nil` (carrega o `Stop.othersWorking`). `reason` é exatamente o texto que o laço grava hoje (`verdict` + `broken` + `moves` juntados por `; `), **sem mudar uma palavra**.
2. `attempt()` mede os fatos e **chama `decide`**; deixa de ter essas regras inline (`passed`, `last`, `blocked == nil` para decidir `discard`, o texto do motivo). O resto (git, reset, nota, evidência, `store.update`) continua no `attempt()`, agora guiado pelo `Outcome`. `verdict(...)` e `failure(...)` podem ser reaproveitados por `decide`.
3. **Nenhuma mudança de comportamento**: mesmas mensagens de motivo, mesmo `discard`, mesma última tentativa, mesma parada com outro terminal ativo. O diário (M1.2) e o `stopReason` (M1.1) continuam sendo gravados nos mesmos pontos.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/AttemptDecisionTests.swift`

Em tabela (`@Test(arguments:)`), cada linha um conjunto de fatos e o `Outcome` esperado: tudo ok é `.pass`; check falhou (exit 1) na 1ª de 3 é `.retry` com `discard`; check com timeout; check que não pôde rodar; sem commit novo; árvore suja; portão falhou; o check moveu o HEAD; o portão moveu o HEAD; várias razões juntas na ordem de hoje; na 3ª de 3 é `.defer`; `blockedBy` presente é `.stopLoop(othersWorking)` e nunca `.defer`, sem `discard`; `.pass` com `blockedBy` (a tarefa passa e o laço para depois: decida e **documente em um comentário** o que o código de hoje faz: `return blocked == nil`). Todos os testes de `WorkLoopTests` continuam passando **sem alteração de expectativa**.
