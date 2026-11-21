# M11.3 Build do agente com nome estável por laço e limpeza das pastas `.build` velhas

Leia `onda11.md` e P5 de `aval-suite-report.md`. Medida: a orientação de pasta compartilhada manda o agente compilar em `.build/<nome-do-terminal>` (`Sources/CollieDaemonKit/CollieOrientation.swift` ~166). O nome muda a cada tentativa (`…-t1`, `…-t2`), então **cada tentativa compila a frio** (~4 a 5 min) e `.build/` já tem ~95 pastas de 1,7 GB (98 GB).

## Fazer
1. Para um terminal **de tentativa de laço** (nome `<trabalho>-<tarefa>-t<n>`, veja `AgentNaming`), a orientação passa a indicar **um nome estável por laço**, sem o sufixo da tentativa nem o da tarefa (ex.: `.build/laco-<trabalho curto>`), para a tentativa 2 reaproveitar o build da 1. Terminal comum (não de laço) segue como hoje. Nome sanitizado do mesmo jeito (`maxName`), sem caracteres de caminho.
2. Seguro com lanes (`--parallel`): duas faixas vivas **não** compartilham a pasta (inclua o id curto da faixa/tarefa só quando houver mais de uma faixa viva; no serial, uma pasta por laço). Dois agentes na mesma pasta de build disputam o lock do SwiftPM.
3. `scripts/dev/prune-builds.sh` (novo, bash): lista as pastas `.build/*` (não a `.build/debug`, `release` nem `checkouts`, `repositories`, `artifacts`, `*.json`) com tamanho e idade; **por padrão só lista (dry-run)**; com `--apply --older-than <dias>` remove as com mtime mais velho; nunca remove a pasta de um terminal vivo (`collie list` quando disponível) nem fora de `.build/`; sai com erro em argumento estranho. Sem `rm -rf` de variável vazia (`set -u`, e confira que o caminho começa por `<repo>/.build/`).
4. A orientação continua curta (a versão `tight` não cresce).

## Testes
`Tests/CollieDaemonKitTests/StableBuildDirTests.swift` (novo): nomes de tentativa `t1` e `t2` da mesma tarefa dão **o mesmo** diretório; tarefas ou trabalhos diferentes dão diretórios diferentes; duas faixas vivas dão diretórios diferentes; terminal comum igual a hoje; sem `/`, `..` ou espaço. Os testes de orientação existentes seguem verdes. `scripts/dev/test-prune-builds.sh` (bash, em diretório temporário): dry-run não remove nada; `--apply --older-than` remove só o velho; recusa caminho fora de `.build/`.

## Check
`swift test --disable-sandbox --skip MemoryEventEmissionTests --filter StableBuildDirTests --filter OrientationTests` (use o nome real das suítes de orientação que existirem) `&& scripts/dev/test-prune-builds.sh`.
