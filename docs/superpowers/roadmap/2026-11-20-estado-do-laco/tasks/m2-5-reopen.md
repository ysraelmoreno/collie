# M2.5 `collie work task reopen`

Leia `onda2.md` e `README.md`. Código: `Sources/CollieDaemonKit/WorkCommands.swift` (`work task done/defer/drop/add`), `Sources/CollieProtocol/Commands.swift` e `ArgvParser.swift` (declaração e esquema MCP), `Sources/CollieCore/Work.swift` (`TaskState`, `WorkTask`), `WorkStatusText`.

## Problema

Uma tarefa adiada (`deferred`) ou abandonada não tem como voltar à fila: hoje se faz `drop` e `add`, perdendo a ordem, o `spec`, o `check` e as tentativas anteriores. Foi a dor da T1 do Trilho (adiada por um gate quebrado por commit alheio).

## Fazer

1. `collie work task reopen <id> [--keep-tries]`: a tarefa (do trabalho ativo do terminal) em `deferred` ou `abandoned` volta a `open`, **na mesma posição**, com `spec`, `check` e `evidenceGlob` intactos; `reason` e `lastFailure` são limpos; `tries` volta a zero **a menos que** `--keep-tries`. Para `done`: recusar ("a tarefa já está feita; use `work task defer` antes se quer refazê-la") e para `open`/`inProgress`: recusar com mensagem clara. `inProgress` durante um laço rodando nunca se reabre.
2. Uma nota no trabalho (`[reopen] <título>: <de qual estado>`), porque muda o que o próximo `work run` fará. O laço só pega tarefas aprovadas no seu cartão/execução (`loop.tasks`): uma tarefa reaberta **depois** de um `work run` esperará o próximo (como uma adicionada depois); deixe isso dito na resposta.
3. Esquema: comando de agente (como `defer`/`drop`), tool MCP `work_task_reopen`; atualize os testes que enumeram comandos e tools. Texto de resposta em português.
4. Sem mudança no motor.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/WorkTaskReopenTests.swift`

`deferred` e `abandoned` reabrem para `open` na mesma posição; `check`/`spec` preservados; `tries` zera e com `--keep-tries` mantém; `reason`/`lastFailure` limpos; recusa para `done`, `open`, `inProgress`; id inexistente; durante um laço rodando; a nota é gravada; esquema MCP lista `work_task_reopen`.
