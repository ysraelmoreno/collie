# M3b.2 O integrador não apaga o que o dono fez durante o gate

Leia `onda3b.md` e o **achado 2** de `rev-onda3-report.md`. Código: `Work/LaneIntegrator.swift` (`othersWorking` e sujeira medidos uma vez, `restore`, `loose`), `Work/AttemptMachine.swift` (`awaitOthers` antes de `settle`, como referência), `WorkLoopCommands.swift` (`loopReaching` exclui o starter).

## Problema
Depois do gate (até 30 min) o integrador faz `reset --hard` + `clean` sem medir de novo: uma edição ou arquivo novo do dono/Shepherd na worktree do cercado durante o gate é apagado em silêncio. No modo paralelo o starter está livre para editar.

## Fazer
1. Antes de **qualquer** `reset`/`clean` do `restore` (gate quebrado ou conflito): medir de novo quem trabalha no cercado (**incluindo o starter**) e a diferença da árvore em relação ao `merged` (rastreados modificados e não rastreados novos que não estavam em `loose`). Se há alguém ou há diferença: **não resetar**, deixar a árvore como está, devolver uma decisão nova (`.leftDirty`/`dirtyTree`, siga os nomes do código) e parar o laço com `Stop.Code.dirtyTree`/`othersWorking`, com nota dizendo o que foi preservado. A tarefa volta a `open` e `used` é devolvido.
2. Quando a árvore está como o integrador a deixou, o `restore` continua igual (sem regressão).
3. A mesma checagem vale para o caminho de sucesso se ele chegar a resetar algo.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneIntegratorRaceTests.swift`
Repositório temporário real: (a) o gate (host falso) edita um arquivo rastreado e cria um não rastreado **durante** o gate, e o gate falha: nada é resetado nem apagado, o laço para com o código certo e a nota cita o que ficou; (b) um terminal do dono (starter) ativo na worktree: não reseta; (c) sem interferência o `restore` reseta como antes (regressão); (d) os arquivos não rastreados que já existiam (`loose`) seguem preservados. `LaneIntegrationTests` segue verde.
