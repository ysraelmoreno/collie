# U2: `/collie:factory init` (skill, detector e modelos por stack)

Spec geral: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U2. Depende de U1, U3 e U5 (já no repositório quando esta tarefa
roda: `FactoryProfile`, `collie factory doctor`, `collie factory ratchet`). Sem código novo no daemon.

Onde as coisas moram (nada fora do repositório; instalar a skill em outro lugar é ação do dono):
- `docs/fabrica/skill/factory-init/SKILL.md`: a skill (frontmatter `name: factory-init`, `description`); o roteiro que o agente segue.
- `scripts/factory-detect.sh <dir>`: detector determinístico, sem rede, só lê. Imprime JSON com `stack` (`swift`, `node`, `python`, `kotlin`, `flutter`,
  `rust`, `go` ou `unknown`; vários possíveis em `stacks`), `testRunner`, `linter`, `formatter`, `ci` (arquivos) e `existing` (se já há `collie-work.json`,
  `scripts/check-*.sh`, `docs/fabrica/personas`). Sinais: `Package.swift`, `package.json` (e `devDependencies`: jest, vitest, eslint, tsc), `pyproject.toml`
  /`requirements*.txt` (pytest, ruff), `build.gradle*`, `pubspec.yaml`, `Cargo.toml`, `go.mod`, `.github/workflows`, `Makefile`.
- `docs/fabrica/modelos/<stack>/` para `swift`, `node`, `python`: cada um com `profile.json` (o trecho `factory` + gate/precheck/smoke/areas, válido
  pela U1), `scripts/check-<tarefa-tipo>.sh` (um check mede só a própria tarefa e nunca só compila), `ci.yml` (esqueleto) e um `README.md` com dono e
  data de versão do modelo. `docs/fabrica/personas/` com as personas padrão copiadas das personas do repositório (veja onde o `--review` as lê hoje).
- Teste `scripts/test-factory-detect.sh` com fixtures mínimas em `scripts/fixtures/factory-detect/<stack>/` (um diretório por stack, 3 a 4 arquivos).

## O roteiro da skill (texto, para o agente seguir)

1. Rodar o detector; mostrar o que achou e perguntar se está certo. 2. Entrevista curta, uma pergunta por vez: o que nunca pode quebrar, quanto o gate pode
levar, ações destrutivas, aparelho ou navegador, política de land. 3. Gerar a partir do modelo da stack, NUNCA sobrescrever arquivo existente (pergunta
antes, e mostra o diff); gravar `collie-work.json` (mesclando o `factory`), scripts, personas e CI só se não existe. 4. Baseline inicial da catraca com
`collie factory ratchet update`/o comando que a U5 definiu. 5. Rodar `collie factory doctor` e mostrar a nota; corrigir o que for FRACO com o dono. 6. Uma
TAREFA PILOTO pequena (mudança trivial com check) para calibrar e mostrar o ciclo, via `/collie:loop`. A skill nunca faz push nem release.

## Testes

`scripts/test-factory-detect.sh`: cada fixture detecta a stack certa; diretório vazio dá `unknown`; JSON válido (`python3 -c`/`plutil` ou `jq` se existir);
o detector não escreve nada (diff de árvore antes e depois). Teste Swift em `Tests/CollieDaemonKitTests/FactoryModelsTests.swift`: cada
`docs/fabrica/modelos/*/profile.json` passa em `ProjectWorkConfig.parse` com `factory` presente, e o doctor (núcleo puro, snapshot montado do modelo) dá
nota >= 2 na camada static de cada stack.

Check: `scripts/check-fabrica-loop.sh u2`. Commit ao final, só os arquivos da tarefa.
