# M2.2b Cancelamento de ponta a ponta (parte 2 de 2 da M2.2 original)

Leia `onda2.md` e `README.md`. Depende da M2.2a (o campo `resumeFrom`). Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` e `AttemptMachine.swift` (o interpretador de efeitos: `runCheck`, `runGate`, `awaitOthers`), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`cancelLoops`).

## Problema (achado 4 da revisão da Onda 1, 2026-11-20)

Hoje `Task.isCancelled` só é olhado depois do turno do agente. Se o daemon para (`cancelLoops`) **durante o check, o portão ou a espera por outros terminais**, o erro do `host.check` vira veredito: a tentativa é contada, descartada e, na última, a tarefa é **adiada** por causa de um desligamento.

## Fazer

1. O interpretador checa o cancelamento **antes** de devolver `checkDone`, `gateDone` ou `blocked`, e devolve o evento `.cancelled`, que a máquina já trata em qualquer fase: **sem veredito, sem `discard`**, a tarefa volta a `open` com a tentativa **não contada** (`used` volta), o job `gone`, o `stopReason` `cancelled`. A tarefa mantém `resumeFrom` (M2.2a) para ser julgada na próxima execução.
2. Nenhum outro caminho muda: um check que falha de verdade continua sendo veredito.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopCancelTests.swift`

Host falso (como `WorkLoopTests`): cancelar a `Task` do `run` **durante o check**, **durante o portão** e **durante `awaitOthers`**: cada um deixa a tarefa `open`, `used` não incrementado, nada descartado, nenhuma tarefa adiada, **mesmo na última tentativa**, e o `stopReason` é `cancelled`. Um check que falha sem cancelamento continua sendo veredito (regressão). Use continuações do host falso para segurar o check no meio, **sem `sleep`**.
