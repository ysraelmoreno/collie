# M2b.2 Testes que dependiam do relógio

Leia `onda2b.md`. Código: `Tests/CollieDaemonKitTests/LoopNitsTests.swift` (`cancelLoopsWaitsForTheLoopToWriteCancelled`, em torno das linhas 46-51), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`loopCancelWait`, `cancelLoops`), `Tests/CollieDaemonKitTests/WorkLoopTests.swift` (`checkTimeoutFails`, que mede `< 20 s`), `Tests/CollieDaemonKitTests/AskSubmitRetryTests.swift` (os `Task.sleep` das linhas 72 e 94).

## Problema (achados 2 e 3 da revisão)

Sob carga (o `check-architecture.sh` disputando o build, ou outra sessão compilando), `cancelLoopsWaitsForTheLoopToWriteCancelled` afirma um prazo de parede de 2 s e falha, e `checkTimeoutFails` (antigo) mediu `22.0 s < 20 s`. Passam sozinhos. Num laço, um teste assim **queima tentativas** que não tinham defeito.

## Fazer

1. `cancelLoops` recebe o prazo como parâmetro (`loopCancelWait` injetável no `CommandRouter` ou como argumento, com 2 s de padrão em produção), e o teste passa a **esperar o valor da própria `Task`** do laço (que termina quando grava `cancelled`) em vez de afirmar que isso acontece em 2 s: um teste que segura o laço com uma continuação, cancela, solta e espera o resultado, sem relógio. Mantenha um teste separado de que o prazo existe (um laço que **não** termina é abandonado depois do prazo; use um prazo injetado de poucos milissegundos).
2. `checkTimeoutFails`: o que ele prova é que um check que passa do limite é **morto** e vira falha, não quão rápido. Troque o limite de parede por uma folga larga (por exemplo, o check dorme 600 s, o timeout é 1 s e o teste exige `< 120 s`), ou use o relógio injetável do host falso, se ele já tiver um. A semântica (timeout vira `check timed out`) não muda.
3. `AskSubmitRetryTests`: onde o teste prova **ausência** de um Enter dormindo 3 s ou 500 ms, injete o relógio no `AskCoordinator` (`submitConfirm`/`workingWindow` como parâmetros do init, que o código já parece permitir) e reduza para milissegundos; se não for possível sem mudar o código de produção além de expor parâmetros, deixe como está e **diga no commit por quê**.
4. Nenhum `sleep` novo em teste nem em produção (o lint do repo barra). Nenhuma mudança de comportamento em produção além de expor o prazo.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopCancelWaitTests.swift`

O prazo injetado: um laço que termina antes do prazo grava `cancelled` e `cancelLoops` volta sem esperar o prazo inteiro; um laço que não termina é abandonado depois do prazo injetado (milissegundos), e o desligamento **não** trava. `LoopNitsTests`, `WorkLoopTests` e `AskSubmitRetryTests` seguem verdes **sem mudar expectativa de comportamento**.
