# M3b.5 O varredor só remove faixa que o próprio daemon criou

Leia `onda3b.md` e o **achado 5** de `rev-onda3-report.md`. Código: `WorkLoopCommands.swift` (`removeLanes`, `loopEnded`, a varredura de início), `Work/LaneWorktree.swift` (~113-135: `orphans`, `remove` com `worktree remove --force` e `branch -D`), `Work/WorkLoopLanes.swift`.

## Problema
No fim de qualquer laço paralelo e no início do daemon, é removida (com `--force`) toda faixa cujo trabalho não está no registro **deste** daemon. Um daemon de desenvolvimento e o instalado no mesmo repositório têm registros diferentes: um apaga as faixas vivas do outro. Um branch do dono chamado `collie/lane/…` também seria apagado.

## Fazer
1. `loopEnded` remove só as faixas **do próprio trabalho** (`work8 == w`).
2. Toda faixa criada recebe um **marcador** gravado pelo daemon dono dentro do gitdir da faixa (por exemplo `<common>/worktrees/lane-…/collie-lane` com o id da instalação/raiz do Collie e o id do trabalho; o id de instalação já existe no projeto: procure como outros pontos o identificam). A varredura de **órfãs** (sem trabalho vivo no registro) só remove uma faixa se o marcador existe **e** é do daemon corrente; sem marcador ou de outro daemon: **não toca**, só registra uma nota de aviso. Nunca `--force` nem `branch -D` em worktree sem marcador.
3. O marcador é escrito pelo daemon (fora do perfil da faixa, junto com a criação da M3b.1), e a faixa não consegue escrevê-lo (o gitdir da faixa já está fechado para o agente nos arquivos de controle: confirme e feche se faltar).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneSweepScopeTests.swift`
Repositório temporário real: (a) fim de um laço não remove a faixa de **outro** trabalho nem a de outro daemon (marcador diferente); (b) uma worktree/branch do dono `collie/lane/x` sem marcador sobrevive à varredura, com nota; (c) a órfã com marcador do daemon corrente e trabalho desconhecido é removida; (d) as faixas do próprio trabalho são removidas no fim; (e) o `branch -D` só ocorre com marcador. `LaneWorktreeTests` e `LoopLaneLifecycleTests` seguem verdes (ajuste só o que cria faixa sem marcador, e diga no commit).
