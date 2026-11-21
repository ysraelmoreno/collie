# M13.2 `--area` em `work task add` e padrões de `--gate`/`--precheck` vindos do arquivo

Leia `onda13.md` e a `ProjectWorkConfig` da M13.1 (já commitada). Código: `WorkCommands.swift` (`work.task.add`), `WorkLoopCommands.swift` (`work.run`), `Commands.swift` (`ParamSpec`).

## Fazer
1. `collie work task add … --area a,b`: o `check` da tarefa passa a ser `ProjectWorkConfig.composeCheck(areas)` lido do `collie-work.json` da raiz do cercado (mesmas regras de leitura segura da M13.1). `--area` junto com `--check` = erro claro; `--area` sem arquivo, com área inexistente ou arquivo inválido = erro que diz qual. O check montado aparece na resposta e fica gravado na tarefa (o laço continua rodando `task.check` como hoje: **nada no motor muda para uma tarefa com check pronto**).
2. `collie work run`: sem `--gate`, usa o `gate` do arquivo; sem `--precheck`, o `precheck` do arquivo (a flag sempre vence; arquivo ausente ou inválido = os padrões de hoje, com um aviso de uma linha só no retorno de `work run`, nunca falha por causa do arquivo). O aviso de início do laço (`[collie] Laço iniciado…`) diz de onde veio o portão ("portão (collie-work.json)").
3. O limite de 1500 caracteres do cartão de aprovação passa a contar o check **montado** (não o nome da área): não mude esse limite.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/WorkAreaTests.swift`
`--area` monta o check esperado com e sem `smoke`; `--area` + `--check` recusado; área inexistente lista as válidas; sem arquivo, `--area` recusado e `work run` igual a antes; `work run` sem `--gate` usa o do arquivo; com `--gate` a flag vence; arquivo inválido não impede o `work run` (aviso, padrões de hoje); a tarefa guarda o check montado; `WorkCommandTests` e `WorkLoopTests` sem adaptação. O fake aplica a regra real.

## Check
`scripts/check-onda13.sh m13-2`.
