# M3c.2 O Shepherd esperando não conta como trabalhando; o portão que deixa arquivo não para o laço

Leia `onda3c.md` e os **achados 2 e 3** de `rev-onda3b-report.md`. Código: `Work/LaneIntegrator.swift` (~85-86, ~116-123, `restore`, `loose`, `who`), `WorkLoopCommands.swift` (`anyoneWorking`, ~536, `starter: nil`), `CommandRouter.swift` (~559-562, `targetBusy`), `Tests/CollieDaemonKitTests/LaneIntegrationTests.swift` (~122 e ~136, testes relaxados na 3b), `docs/referencia.md` (~831).

## Problema
1. O fluxo recomendado deixa o Shepherd (o starter) bloqueado em `collie work wait`, com o selo `working`. Como o integrador conta o starter, `who != nil` em quase toda integração: todo portão quebrado deixa o merge ruim no branch e o laço para com `othersWorking`; um conflito também para o laço.
2. Um portão que passa e deixa um arquivo não rastreado (relatório, cobertura) ou edita um rastreado (formatter) agora para o laço com `dirtyTree` **depois de toda integração**, e o portão quebrado com qualquer arquivo novo deixa o merge no branch. Os testes antigos da limpeza foram relaxados na 3b em vez de substituídos.

## Fazer
1. O starter **não conta** como "trabalhando" quando o único pedido aberto dele no daemon é `work.wait`/`work.status` **deste trabalho** (o daemon sabe qual comando o terminal está servindo); qualquer outro trabalho do starter (editando, outro `ask`) continua contando. Os outros terminais do cercado continuam contando.
2. Decisão de limpeza do integrador: o **diff dos arquivos rastreados** (em relação ao que o integrador deixou: `merged`) e o `who` decidem o `reset`; **arquivos não rastreados novos não bloqueiam**: o `restore` não faz `clean` deles, apenas deixa e anota; depois de um portão que **passou**, o laço só para se um arquivo **rastreado** mudou. O `reset --hard before` continua só quando a árvore está como o integrador a deixou (rastreados) e ninguém trabalha.
3. **Restaure a cobertura** que a 3b relaxou: um portão quebrado que escreve `junk.txt` e edita `f.txt` tem o mesmo desfecho do desenho original (volta limpo, merge desfeito, tarefa refeita do HEAD novo) quando o arquivo rastreado ficou como o integrador deixou; o que o dono editou durante o gate continua **intocado** (a regra da M3b.2 não regride).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneIntegratorWaitTests.swift`
Repositório temporário real: starter só em `work.wait` não bloqueia o reset (portão quebrado ⇒ volta limpo, tarefa refeita); starter editando (outro comando) bloqueia como antes; outro terminal do cercado bloqueia; conflito com o starter esperando volta limpo; arquivo não rastreado novo deixado pelo portão que passou **não** para o laço; arquivo rastreado editado pelo portão que passou para o laço com nota; a edição do dono durante o gate continua preservada (regressão da M3b.2); `LaneIntegrationTests` e `LaneIntegratorRaceTests` seguem verdes (com a asserção original de limpeza restaurada).
