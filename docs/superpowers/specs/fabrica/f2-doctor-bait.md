# F2: núcleo do doctor e da isca (major 1 do revisor 1, minors 1 a 5 e nits baratos)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-1.md`. Arquivos: `Sources/CollieCore/FactoryBait.swift`, `FactoryDoctor.swift`, `Sources/CollieDaemonKit/FactoryCommands.swift`.

1. `costSeconds`: teto no parse (`<= 86400 * 7`, erro `outOfRange` com o caminho) e toda soma com saturação (`addingReportingOverflow`); sem trap possível. Teste com dois runs de 9e18.
2. Run com `caught: false` exige `layer` (erro `.escapedWithoutLayer(path:)` ou equivalente); ajuste o teste de `FactoryBaitTests` que aceitava `layer: null` com `caught: false`.
3. Taxa por persona: denominador = runs da camada `review`. Teste (o caso 1 de 3 do relatório).
4. `runsTests` reconhece `test:` e `test-` como prefixo de palavra (`npm run test:ci`, `yarn test:unit`), `rspec`, `mocha`, `unittest`, `phpunit`, `ctest`, `make check`. `onlyLooksForFiles` ignora `exit`, `echo`, `true`, `{`, `}`.
5. judge: script citado que não existe em `s.paths` não conta como "lido do commit base" e avisa; **e o judge NÃO passa de 2 quando o gate/precheck/smoke não cita nenhum arquivo versionado** (gate nu, como
   `npm test`): evidência diz que um agente pode neutralizar o runner pela config. Testes.
6. `bait-results.json` inválido não derruba o doctor inteiro: a camada afetada ganha uma evidência de erro e a nota cai 1; o resto do relatório sai. Teste.
7. O log do `raise` do `FactoryRatchet` (comentários de razão no baseline) não pode crescer a ponto de a leitura (limite 1 MB) travar a catraca: mantenha as últimas 100 linhas de log ao gravar. Teste.

Check: `scripts/check-fabrica-loop.sh f2`. Commit ao final, só os arquivos da tarefa.
