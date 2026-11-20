# M3.7 Ponta a ponta e documentação

Leia `onda3-paralelismo.md`. Depende de M3.1 a M3.6. Código: testes novos; `docs/referencia.md` (a referência de comandos), o texto de `/collie:loop` (`Sources/CollieDaemonKit/Work/LoopCommand.swift`), `docs/feature-map.md` se citar o laço.

## Fazer

1. **Teste ponta a ponta** com o motor real e um repositório git temporário de verdade, host falso só para o agente (que escreve arquivos e faz commit na faixa): (a) duas tarefas de escopo disjunto, `--parallel 2`: as duas passam, são integradas, o histórico tem os dois commits e dois merges, o gate rodou depois de cada merge e as faixas sumiram; (b) escopos sobrepostos: rodam em série, mesmo com `--parallel 2`; (c) duas tarefas que alteram a mesma linha: a segunda conflita, o merge é desfeito, a tentativa é refeita a partir do HEAD novo e passa na 2ª; (d) `needs`: a dependente só começa depois da integração da primeira, e vê o código dela; (e) `work stop` no meio: nenhuma faixa sobra, nada integrado pela metade, `stopReason = requested`; (f) o `--parallel 1` do mesmo conjunto tem o resultado do laço antigo; (g) uma faixa cuja tentativa falha 3 vezes é adiada e a outra integra normalmente.
2. **Documentação:** em `docs/referencia.md`, `work run --parallel`, `work task add --needs --scope`, `work wait`, `work task reopen`, `work status --events`, com a regra de escopo exclusivo, o custo da compilação a frio e o limite 4. Em `/collie:loop` (o texto que o agente Pastor lê): quando usar `--parallel` (tarefas independentes e longas, **com `scope` declarado**), quando **não** (tudo o que mexe no mesmo arquivo ou em `Package.swift`), e que o padrão é 1. Uma seção curta em `docs/feature-map.md` se o laço já tem uma.
3. **Medida da compilação a frio:** um script `scripts/dev/lane-coldbuild.sh` (apenas lê e imprime; não roda no CI) que cria uma faixa descartável, mede o tempo de `swift build` a frio e a remove, para o dono decidir quando compensa. O resultado **não** é parte do check (leva minutos).
4. Atualize `CHANGELOG.md` na seção `[Não lançado]` com as Ondas 1 a 3 (uma linha por entrega visível ao usuário, no estilo do arquivo).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopParallelE2ETests.swift`

Os casos (a) a (g) acima como testes separados, cada um com repositório temporário próprio; sem `sleep` nem relógio: a ordem vem de continuações. Um teste de que o texto de `/collie:loop` menciona `--parallel`, `--scope` e a regra do escopo exclusivo. A documentação é conferida por um teste simples que procura os comandos novos em `docs/referencia.md`.
