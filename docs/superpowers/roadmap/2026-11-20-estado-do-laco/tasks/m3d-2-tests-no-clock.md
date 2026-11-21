# M3d.2 Testes sem relógio para os avisos e o ponta a ponta do Shepherd em `work wait`

Leia `onda3d.md` e os **achados 2 e 3** de `rev-onda3c-report.md`. Código: `Tests/CollieDaemonKitTests/LoopNotifyTests.swift` (~11-16 `notices` com `ContinuousClock`/`Task.sleep`; ~44-55), `Sources/CollieDaemonKit/Work/WorkLoop.swift` (~538-539, aviso num `Task` solto, `reportEnd`), `Tests/CollieDaemonKitTests/LaneIntegratorWaitTests.swift` (~111-250), `WorkLoopCommands.swift` (`RouterLoopHost.anyoneWorking`).

## Fazer
1. **`LoopNotifyTests`:** tirar `sleep`/relógio de parede. Extraia a decisão de avisar (`reportEnd`) para devolver a linha do aviso (ou nil) **antes** de disparar o `Task`, e afirme que é `nil` para tarefa feita com `--notify end` e não-nil para adiada, parada e fim; para o `task`, conte as chamadas de `taskEnded` do host falso de forma síncrona. A asserção negativa tem que **falhar** se a supressão regredir (prove com uma mutação: volte a supressão no teste e veja falhar).
2. **Ponta a ponta do Shepherd em `work wait`:** um teste com `withDaemon` que estaciona o `work.wait` do starter, força o selo `working` pelo `hub`, e chama `RouterLoopHost(...).anyoneWorking()` esperando `nil`; depois com um segundo pedido aberto do starter, esperando o nome dele; e outro terminal do cercado sempre conta. A chave do trabalho do `RouterLoopHost` é a mesma que o `work.wait` usa.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/ShepherdWaitIntegrationTests.swift`
Os dois ponta a ponta acima; os de `LoopNotifyTests` ficam sem `sleep` (o lint de testes do repo não deve achar um novo). Suítes anteriores verdes.
