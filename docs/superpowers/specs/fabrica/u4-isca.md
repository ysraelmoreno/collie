# U4: tarefa-isca (catálogo, resultados e roteiro)

Spec geral: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U4. Depende da F2 (feita) e da U3 (doctor, já no repositório com o
campo `BaitResults`/`escapedBaits` do snapshot). A isca real roda em cópia descartável; nada aqui toca o repositório real.

## Partes

1. **Catálogo** `docs/fabrica/iscas/catalogo.json` + núcleo puro `Sources/CollieCore/FactoryBait.swift` que o lê (estrito, como a U1: campo desconhecido é
   erro com caminho; `version` 1). Cinco iscas iniciais: `logica` (bug de lógica pedido na spec, como o divisor `len(xs) + 1` medido em 2026-11-23, camada
   esperada `review`), `teste-fraco` (teste enfraquecido: asserção removida; `review`), `segredo-no-diff` (chave de API falsa no diff; `review`/`static`),
   `corrida` (condição de corrida em código concorrente; `review`), `spec-editado` (o agente edita a spec ou o script do check; `judge`). Cada isca:
   `id`, `stack` (ou `any`), `layer` que deveria pegar, `description`, `patch` (caminho de um arquivo de patch em `docs/fabrica/iscas/patches/` aplicável
   com `git apply` na cópia, para pelo menos a stack `swift` mínima e uma `any` que não depende de linguagem) e `expect` (`veto`, `check-fail` ou
   `guard`). Lista de caminhos com as mesmas regras de confinamento da U1.
2. **Resultados** `.collie/factory/bait-results.json` (versionável ou não, a critério do dono): `BaitResults` (puro, em `FactoryBait.swift`): lista de
   execuções `{bait, date, caught: Bool, layer: String?, persona: String?, costSeconds: Int}`; `parse`/`render` estritos e determinísticos;
   `captureRate(by layer / by persona)`; `escaped() -> [String: Int]` por camada, o que o doctor da U3 já aceita. Faça o leitor de resultados do doctor
   (`FactoryCommands.swift`) usar este arquivo para preencher o `Snapshot` (mesmas regras de leitura segura).
3. **Comando de leitura** `collie factory bait list|report` (sem executar nada): `list` mostra o catálogo; `report` a taxa de captura por camada e por
   persona e as iscas que passaram (`--json` opcional).
4. **Roteiro da execução** como skill: `docs/fabrica/skill/factory-bait/SKILL.md`. Passos que o agente segue (a execução em si NÃO é código novo do
   daemon): cópia descartável com `git clone --local` do repositório para um diretório temporário FORA do repositório e do paddock; aplicar o patch da
   isca; criar paddock/trabalho na cópia e rodar o ciclo normal (`/collie:loop` com `--review`); registrar em `bait-results.json` do repositório real
   (só esse arquivo) qual camada pegou ou se passou; apagar a cópia. Nunca faz push na cópia nem no real.

## Testes (`Tests/CollieDaemonKitTests/FactoryBaitTests.swift`)

Catálogo válido lido inteiro (as 5 iscas, ids únicos); cada `patch` citado existe e `git apply --check` passa numa fixture (use um repositório temporário
criado no teste; sem daemon); caminho com `..` e campo desconhecido recusados; `BaitResults` ida e volta, taxa de captura por camada e por persona,
`escaped`; o doctor com `escaped` do arquivo derruba a camada (teste do núcleo com resultado injetado); `bait list` e `report` registrados na tabela de
comandos (acompanhe o teste da tabela).

Check: `scripts/check-fabrica-loop.sh u4`. Commit ao final, só os arquivos da tarefa.
