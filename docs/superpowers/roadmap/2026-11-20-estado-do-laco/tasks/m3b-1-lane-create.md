# M3b.1 A faixa nasce e morre sob o perfil real

Leia `onda3b.md` e o **achado 1** de `rev-onda3-report.md`. **Bloqueia a instalação.** Código: `Work/WorkLoopLanes.swift` (`cut`, `removeLanes`, `dropLane`), `Work/LaneWorktree.swift` (`create`, `remove`, `orphans`), `GitRunner.swift`, `Sandbox/SandboxProfile.swift`, e como o `PaddockManager` cria worktrees de cercados fora do perfil do laço.

## Problema
`cut` roda `git worktree add` com o `host` do cercado, e todo git do laço roda sob o perfil estrito do cercado, que não deixa escrever `<repo>/.collie/paddocks/lane-*` nem `<common>/worktrees/lane-*`. Sob o sandbox (o único modo que aceita `--parallel`) nenhuma faixa nasce, nem é removida pelo `remove`/`prune`.

## Fazer
1. Criar, remover e podar faixas com o **git do próprio daemon, fora do perfil do laço**, como o `PaddockManager` faz com cercados (`GitRunner` já desliga hooks e fsmonitor). Só caminhos que o daemon mesmo gera e valida (`LaneWorktree.validate`, ficam sob `<repo>/.collie/paddocks/lane-*` e `<common>/worktrees/lane-*`); nunca aceitar caminho vindo do agente ou da tarefa sem a validação. O git que roda **dentro** da faixa (agente, check, gate) continua sob o perfil da faixa.
2. Uma abstração pequena e injetável (por exemplo `LaneGit` / um closure no host) para os testes continuarem com host falso, mas com um ponto onde o teste prova **qual perfil** cada operação usa.
3. O varredor de início e o `removeLanes` usam o mesmo caminho (fora do perfil do laço).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneProfileIntentTests.swift`
Uma tabela de **intenção** (`ProfileRules`, o mesmo modelo de `LaneHostTests`): para cada operação (criar faixa, remover faixa, podar, `merge`/commit do integrador, `git` do agente na faixa), quais caminhos ela escreve e **em qual perfil** roda; o perfil estrito do cercado **não** permite criar/remover a faixa (prova de que o caminho antigo falhava) e a operação nova **não passa por ele**; criar/remover usam o git do daemon. Teste de regressão: sandbox ligado no host falso, `cut` cria a faixa (com um `LaneGit` falso que registra o perfil usado). Um teste com git real num repositório temporário (sem `sandbox-exec`) de criar e remover a faixa pelo caminho novo. Os testes de `LaneHostTests`, `LoopParallelTests`, `LoopLaneLifecycleTests` seguem verdes.
