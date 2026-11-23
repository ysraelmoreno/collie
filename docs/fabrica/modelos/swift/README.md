# Modelo de fábrica: swift

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh # Package.swift`): roda `swift test`; o texto do gate cita `Package.swift`, então o juiz recusa a tentativa que mexe no manifesto. O juiz protege por substring todo arquivo que o texto do gate cita: este script e as configs da raiz depois do `#` |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e falha se a pasta medida não existe: troque a pasta pela do projeto, senão a catraca recusa em vez de medir nada.
- O texto do `gate` cita depois do `#` os arquivos de config da raiz que governam o runner: deixe só os que existem no projeto (o doutor avisa de um citado que não existe) e copie o texto inteiro para a linha `run:` do CI (em YAML o `#` é comentário).
- Limite: o gate não enxerga binários em pastas ignoradas como node_modules/.bin ou .venv (nem .build; o `git diff` não os lista); um runner trocado ali passa. Quem pega é o revisor ou o CI, que instala do zero.
- `destructive`, `budgetSeconds`, `maxTries` e `land` vêm da entrevista; os valores daqui são o ponto de partida.
