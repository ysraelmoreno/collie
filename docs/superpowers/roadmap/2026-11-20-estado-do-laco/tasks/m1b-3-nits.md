# M1b.3 Pontas da revisão

Leia `onda1b.md` e `README.md`. Quatro pequenas correções independentes. Código: `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`cancelLoops`), `Sources/CollieDaemonKit/Work/AttemptMachine.swift` e `WorkLoop.swift` (`discard`, o evento `discarded`), `Sources/CollieDaemonKit/WorkCommands.swift` (o argumento `events` de `work status`), `Tests/CollieDaemonKitTests/WorkLoopTests.swift` (a asserção em torno da linha 294, `notes.contains { $0.text.contains("dirty") }`).

## Fazer

1. **`cancelled` chega ao disco.** `cancelLoops()` cancela as `Task`s dos laços e hoje não espera: no desligamento a gravação final costuma não acontecer e o varredor rotula depois como `daemonRestart`. Faça `cancelLoops` ser `async` e **esperar** as tasks por um tempo curto e limitado (no máximo 2 s no total para todas, **sem `sleep`**: espere o valor das próprias tasks com um limite por `withTaskGroup` ou por uma corrida entre a conclusão e um timeout por `Task.sleep` **dentro** de um tipo de espera que o lint já aceite; se o lint barrar, use `ContinuousClock` com `clock.sleep` e acrescente à baseline só se for **inevitável**, com um comentário de uma linha dizendo por quê, e avise no relatório). Ajuste os chamadores (o desligamento do daemon) e o teste: um laço rodando, `cancelLoops`, e o trabalho no disco tem `stopReason == cancelled`.
2. **`discarded` só com patch.** O evento `discarded <task>-<n>.patch` é emitido mesmo sem patch gravado (`git diff` falhou ou ficou vazio). Faça `discard` devolver se gravou o patch e emita o evento só então (sem patch: `discarded` com detail `sem alterações`). A decisão e o que é descartado não mudam.
3. **`events: false` não é erro.** Em `work status` via MCP/JSON, `events: false` (booleano) equivale a **ausente** (sem diário); `events: true` equivale ao padrão (20); número fora de 1 a 100 continua erro. O esquema não muda.
4. **A asserção enfraquecida volta a provar a ordem.** Em `WorkLoopTests` (a asserção de `dirty`), troque o `notes.contains { … }` por uma que prove que a nota de `dirty` vem **antes** da nota-resumo (`notes.suffix(2)` na ordem certa e a última começando com `[loop] laço parado:`). Sem outra mudança em `WorkLoopTests`.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopNitsTests.swift`

(1) o cancelamento chega ao disco como `cancelled`; (2) sem patch o evento diz `sem alterações`, com patch cita o arquivo; (3) `events: false` e `events: true` em `work status`; número 0 e 101 continuam recusados; (4) a asserção reforçada (ela mesma é o teste, em `WorkLoopTests`; aqui, só os três primeiros).
