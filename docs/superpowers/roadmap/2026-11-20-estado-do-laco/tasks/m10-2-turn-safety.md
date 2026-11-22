# M10.2 Rede de segurança do turno: regra no prompt e pré-check

Leia `onda10.md` e as propostas P2 e P5 de `aval-lacos-report.md`. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (~855 `prompt`), `Work/AttemptMachine.swift`, `Work/AttemptDecision.swift` (decisão pura), `nudgePrompt` (M2.1), `WorkLoopCommands.swift` (`work run`), `Sources/CollieCore/Work.swift` (campos do trabalho).

## Fazer
1. **Regra de turno (P5):** duas linhas fixas no prompt da tentativa: "Rode build e testes em primeiro plano; não encerre o turno com comando em segundo plano nem monitor pendente." e "`swift build` não compila os testes: use `swift build --build-tests` ou `swift test --filter`." (o prompt segue ≤1500 caracteres no total da orientação e a pergunta do laço).
2. **Pré-check (P2):** novo `--precheck "<comando>"` em `work run` (campo opcional do estado do laço). No fim do turno, **antes** do check e antes de contar a tentativa, o laço roda o pré-check (limite próprio de tempo = o menor entre 180 s e o resto do orçamento). Se falhar, **uma única vez por tentativa** envia ao mesmo agente o rabo da saída (últimas 40 linhas, cortadas a 3 KB; é a `evidenceTail`) como cutucada e espera o turno terminar de novo; se falhar de novo, segue para o check normalmente. O diário registra `precheckFailed`/`precheckPassed`. `AttemptMachine`/`AttemptDecision` ganham as linhas da tabela, **puras**, com teste de tabela.
3. Sem `--precheck` nada muda (comportamento idêntico ao de hoje).

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/TurnSafetyTests.swift`
Tabela pura da decisão: pré-check ok → segue para o check; falha na 1ª vez → cutuca e reavalia; falha na 2ª → segue ao check sem nova cutucada; sem pré-check → igual a hoje; estouro de tempo do pré-check = falha. Prompt contém as duas linhas e continua dentro do limite. Ponta a ponta com o host falso aplicando a regra real: o agente conserta após a cutucada e a tentativa **passa na 1ª** sem queimar tentativa. Sem `sleep`.
