# M2.3 `collie work wait` e o status com tempo

Leia `onda2.md` e `README.md`. Código: `Sources/CollieDaemonKit/Work/WorkStore.swift`, `Sources/CollieDaemonKit/WorkCommands.swift` (`work status`), `Sources/CollieProtocol/Commands.swift` e `ArgvParser.swift` (a declaração dos comandos e do esquema MCP; veja como `work status` e `wait` estão declarados), `Sources/CollieDaemonKit/Work/WorkStatusText.swift`, `Sources/CollieCore/Work.swift`. Como `collie wait <terminal>` espera no daemon (`AskCoordinator`/`wait`) é o modelo de uma espera longa.

## Problema

O Pastor sabe que o laço mudou de estado por um texto digitado no terminal dele. É frágil (espera o Pastor ficar ocioso, vira resposta de diálogo). O estado verdadeiro já está no daemon; falta o Pastor poder **esperar por ele** sem terminal, e o `status` dizer há quanto tempo o laço está na fase e quando ela vence.

## Fazer

1. **Versão do estado.** `WorkStore` ganha um contador monotônico por trabalho (`version`), incrementado em toda `update` que muda o trabalho, e uma forma de esperar até a versão passar de `since` (continuações, sem polling e **sem `sleep`**; o lint do repo barra `sleep` novo: use a continuação do próprio store ou um `AsyncStream`).
2. **`work.wait`** (comando do daemon, para o trabalho ativo do terminal que pergunta): argumentos `--since <versão>` (opcional) e `--timeout <s>` (padrão 600, máximo 3600). Responde quando algo mudou para além de `since` (tarefa muda de estado, `loop.phase`/`task`/`attempt`/`state`/`stopReason`, nota nova, evento novo) ou o laço terminou, ou o tempo acabou (`timedOut: true`). A resposta é a do `work status` (mesmo JSON) mais `version`. Sem `--since`, devolve de imediato o estado atual com a versão (para o Pastor começar a esperar a partir dela). Um laço que terminou responde de imediato e diz `ended: true`.
3. **CLI e MCP.** `collie work wait [--since N] [--timeout S]` imprime a linha de estado do `status` e a versão; a tool MCP `work_wait`. Declare no esquema (`Commands.swift`/`ArgvParser`) como o resto e atualize os testes que enumeram comandos e tools. Respeite o timeout de requisição do cliente: um `--timeout` longo não pode ser cortado pelo limite padrão do protocolo (veja como `wait` de terminal e `ask` lidam com isso).
4. **Status com tempo.** `WorkLoopState.phaseSince: Date?` (gravado quando `phase` muda; opcional) e o `work status` mostra `desde 14:03 (4 min)` na linha do laço em curso, e, durante `agent`, `próximo limite: turno vence em N min` (a partir do início da tentativa e de `timeout`). Sem `--events`, o restante da saída fica igual.
5. Sem mudança no motor além de gravar `phaseSince`; a espera lê o que o store já grava.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/WorkWaitTests.swift`

`WorkStore`: a versão sobe a cada `update` e não sobe quando nada muda; esperar com `since` atual bloqueia e **acorda** com a próxima `update` (sem timeout de relógio nos testes: acorde por uma `update`); esperar com `since` antigo volta na hora; vários esperando acordam todos; cancelar a espera não vaza continuação. `work.wait`: timeout devolve `timedOut`; laço terminado devolve `ended`; a resposta traz `version`. `WorkStatusText`: a linha com `desde` e `próximo limite` (formato e arredondamento); sem laço em curso a linha não muda. Esquema: `work_wait` aparece na lista de tools e os testes de enumeração seguem verdes.
