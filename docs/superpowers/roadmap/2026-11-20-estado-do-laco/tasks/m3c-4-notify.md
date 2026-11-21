# M3c.4 `work run --notify end`: menos turnos do Pastor

Leia `onda3c.md`. Motivo (medição de 2026-11-21): ~27% do gasto do Pastor vem dos avisos automáticos do laço (um `[collie] Laço, tarefa terminada` acorda um turno por tarefa). Código: onde o laço emite `taskEnded`/`loopEnded` (procure `taskEnded` em `Sources/CollieDaemonKit`), `WorkLoopCommands.swift` (`work.run`), `Sources/CollieProtocol/{Commands,ArgvParser}.swift`, MCP `work_run`, `Sources/CollieCore/Work.swift` (`WorkLoopState`), `WorkStatusText.swift`, `CollieOrientation.swift` (orientação do Pastor, limite de 1500 caracteres).

## Fazer
1. Flag nova `--notify <task|end>` (padrão **`task`**, comportamento de hoje, **idêntico**). Com `end`, o laço **não** envia o aviso por tarefa feita; **continua** enviando: o aviso de **fim do laço**, o de **tarefa adiada**, o de **parada** (qualquer `Stop.Code`) e o cartão/aviso de início. O `work status`/`work wait` não mudam.
2. Guardar a escolha em `WorkLoopState` (campo opcional, tolerante; ausente = `task`), mostrar no `work status` (`avisos: só no fim`) e no cartão/aviso de início do laço.
3. MCP e CLI coerentes (`Commands.swift`, `ArgvParser`, os testes que enumeram comandos); valor inválido é recusado.
4. Orientação do Pastor e `/collie:loop`: uma frase dizendo que `--notify end` existe e economiza turnos (sem passar de 1500 caracteres em nenhum nível de orientação).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopNotifyTests.swift`
Host falso: `task` (padrão) avisa a cada tarefa feita como antes; `end` não avisa tarefa feita mas avisa tarefa adiada, parada e fim; estado antigo sem o campo decodifica como `task`; valor inválido recusado; `status` mostra a escolha; o texto da orientação cabe no limite. Os testes existentes de aviso seguem verdes sem mudar expectativa.
