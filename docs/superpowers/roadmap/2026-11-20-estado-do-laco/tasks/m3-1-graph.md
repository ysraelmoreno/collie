# M3.1 Grafo de tarefas e escalonador puro

Leia `onda3-paralelismo.md`. Código: `Sources/CollieCore/Work.swift` (`WorkTask`), `Sources/CollieDaemonKit/WorkCommands.swift` (`work task add`) e a declaração do comando em `Sources/CollieProtocol/Commands.swift`/`ArgvParser.swift`; novo `Sources/CollieDaemonKit/Work/TaskScheduler.swift`.

## Fazer

1. `WorkTask` ganha `needs: [String]?` (ids de tarefas) e `scope: [String]?` (globs relativos à raiz da worktree: `Sources/CollieApp/**`, `docs/x.md`). Opcionais, `decodeIfPresent`, **ignoram valores inválidos sem derrubar a tarefa**.
2. `collie work task add ... --needs a,b --scope 'glob1,glob2'` (e o esquema MCP `work_task_add`): valide na entrada: `needs` só com ids que existem no trabalho e que **não formam ciclo** (recuse com mensagem clara, em português), `scope` com no máximo 20 globs, sem `..` nem caminho absoluto, sem glob vazio. Atualize os testes que enumeram comandos/tools.
3. `TaskScheduler` (puro, sem host nem relógio): `ready(tasks:, running:, integrating:, parallel:) -> [WorkTask]` devolve, **na ordem das tarefas**, as `open` aprovadas cujo `needs` está todo `done` (e já integrado, via o conjunto `integrated` que recebe), até preencher `parallel` (máximo 4; valor maior é cortado) menos as que já correm. Uma tarefa **sem `scope` é exclusiva**: só entra quando nada mais corre e nada mais entra com ela. Duas tarefas cujos `scope` **se sobrepõem** nunca estão juntas. `scopesOverlap(a, b)` é puro e conservador: na dúvida (glob que não dá para comparar), sobrepõe. Uma tarefa `deferred`/`abandoned` em `needs` bloqueia as dependentes (elas aparecem como `blocked`, com o motivo), mas **não** tranca as independentes.
4. Nada no motor muda nesta tarefa: o escalonador ainda não é chamado.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/TaskSchedulerTests.swift`

Em tabela: sem `needs` nem `scope` com `parallel` 3 só uma sobe (exclusiva); dois escopos disjuntos sobem juntos; sobrepostos (`a/**` e `a/b/**`) não; `needs` satisfeito e não satisfeito; dependente de adiada fica `blocked` e a independente segue; `parallel` 0, 1, 4 e 9 (cortado a 4); ordem de tarefas preservada; ciclo recusado na entrada e id inexistente recusado; `scope` inválido recusado; decodificar tarefa antiga sem os campos. `scopesOverlap` com globs `**`, `*`, arquivo exato, prefixo de pasta e uma dúvida (deve sobrepor).
