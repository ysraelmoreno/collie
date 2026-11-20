# M3.4 Integrador serial

Leia `onda3-paralelismo.md`. Depende de M3.2. Código: novo `Sources/CollieDaemonKit/Work/LaneIntegrator.swift` e `LaneIntegration.swift` (a decisão pura). O git roda pelo `LoopHost.git`, como no motor.

## Fazer

1. `LaneIntegration.decide(_ f: Facts) -> Outcome` **puro**: `Facts` (já medidos): `mergeResult` (`clean`/`conflict`/`noop`), `gateAfterMerge` (passou/falhou/não rodou), `treeClean`, `othersWorking: String?`, `attempt`, `tries`. `Outcome`: `.integrated`, `.retryFromNewBase(reason)` (conflito ou gate quebrado depois do merge e ainda há tentativa), `.defer(reason)` (sem tentativas), `.wait(reason)` (outro terminal trabalhando na worktree do cercado, ou árvore suja: **não** desfaz nada, espera/para como o motor faz hoje), `.noop`.
2. `LaneIntegrator` (actor, **um único** por laço, que serializa as integrações: duas faixas que terminam juntas entram uma de cada vez, na ordem em que passaram). Para uma faixa que passou no check e no gate: na worktree do cercado, com a árvore limpa e nada trabalhando nela, `git merge --no-ff --no-edit <branch da faixa>` (mensagem de merge fixa e em português: `merge: <título da tarefa>`); **roda o gate de novo na árvore integrada** (mesmas condições do motor: timeout, orçamento); se o merge conflita ou o gate quebra, `git merge --abort`/`reset --hard <HEAD de antes>` e devolve o `Outcome`; se passa, o HEAD novo é o que os próximos `ready` e as próximas faixas usam como base.
3. O integrador **nunca** faz push, nunca mexe em branch que não seja o do cercado, nunca deixa a worktree do cercado em estado intermediário (um conflito é sempre desfeito antes de devolver).
4. A mensagem do merge e os motivos passam pelo mesmo tratamento de texto das notas (`LotBoards.scrub`, ANSI).
5. Nada no motor muda nesta tarefa (o integrador ainda não é chamado).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneIntegrationTests.swift`

`decide` em tabela: limpo+gate ok = `.integrated`; conflito com tentativas = `.retryFromNewBase`; conflito na última = `.defer`; gate quebrado depois do merge idem; árvore suja ou outro trabalhando = `.wait` e nunca `.defer`. Repositório temporário de verdade: duas faixas que mexem em arquivos diferentes integram as duas, na ordem; duas que mexem na mesma linha: a segunda conflita, o merge é desfeito e a árvore volta ao HEAD anterior **exatamente** (comparar `git status` e HEAD); gate pós-merge que falha desfaz; duas integrações pedidas ao mesmo tempo são **serializadas** (nunca dois merges simultâneos: um teste com duas `Task`s e um host que registra a ordem).
