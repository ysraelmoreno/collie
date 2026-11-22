# M3d.3 O lixo do portão não bloqueia a integração seguinte

Leia `onda3d.md` e o **achado 4** de `rev-onda3c-report.md`. Código: `Work/LaneIntegrator.swift` (~89-97 conflito, ~140-145 `settle` sem `clean`, `loose`), `Tests/CollieDaemonKitTests/LaneIntegrationTests.swift` (~122-131).

## Problema
Desde a M3c.2 o integrador não faz `clean` dos não rastreados deixados pelo portão (certo: nunca apaga o que não é dele). Mas se uma faixa seguinte **adicionar** um caminho que o portão deixou não rastreado, o `git merge` recusa ("untracked working tree files would be overwritten"), cai no ramo de conflito e gasta tentativas até adiar, sem diagnóstico.

## Fazer
1. O integrador registra **exatamente** os arquivos não rastreados que o **portão criou** (a diferença entre a lista de não rastreados antes e depois do portão; os `loose` que já existiam **nunca** entram). Antes do **merge seguinte** (e ao fim do laço), remove **só esses** (e só se ainda são não rastreados e inalterados desde o portão; se o dono mexeu neles, deixa e anota).
2. Se mesmo assim o merge for recusado por "untracked … would be overwritten" num caminho que **não** é do portão (é do dono), o laço **para com nota clara** (`othersWorking`/`dirtyTree` conforme o código) em vez de refazer a tarefa às cegas.
3. O teste de `LaneIntegrationTests` do portão que edita `f.txt` passa a **mudar o conteúdo de verdade** (hoje reescreve igual), para provar o caso do formatter.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/GateLeftoversTests.swift`
Repositório temporário real: o portão deixa `report.txt`; a faixa seguinte adiciona `report.txt` ⇒ o integrador remove o do portão e o merge passa; `report.txt` do **dono** (já existia) ⇒ nunca removido e o laço para com nota; arquivo do portão que o dono editou depois ⇒ deixado e anotado; portão que edita `f.txt` com conteúdo diferente ⇒ comportamento da M3c.2 preservado. Suítes de integração verdes.
