# Modelo de fábrica: node

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh`): roda o runner direto e falha se um arquivo de config que o governa força sucesso (`passWithNoTests`, `exitstatus = 0`); o juiz protege este script porque o texto do gate o cita, não os arquivos de config |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e falha se a pasta medida não existe: troque a pasta pela do projeto, senão a catraca recusa em vez de medir nada.
- `destructive`, `budgetSeconds`, `maxTries` e `land` vêm da entrevista; os valores daqui são o ponto de partida.
